/// Linux presence reader over the session D-Bus, with detection and
/// degradation instead of assumptions about the desktop.
///
/// Probe order (first mechanism that responds wins):
///  1. `org.freedesktop.login1` — the logind session's `LockedHint`,
///     `IdleHint` (and `IdleSinceHintMonotonic` in the same `GetAll` reply)
///     plus `Lock`/`Unlock`, `PrepareForSleep` and `PropertiesChanged`
///     push signals. Works on any logind desktop (GNOME, KDE, ...).
///  2. `org.gnome.Mutter.IdleMonitor.GetIdletime` — idle on GNOME; lock is
///     detected through `org.freedesktop.ScreenSaver.GetActive` where
///     present, otherwise reported as degraded.
///  3. `org.freedesktop.ScreenSaver.GetSessionIdleTime` + `GetActive` —
///     KDE.
///
/// When NO mechanism responds the platform reports
/// [PresenceUnavailableEvent] — it never throws, never shells out to
/// `loginctl`, and never polls faster than every 2 s (push signals carry
/// the transitions in between).
///
/// Idle is measured with a local monotonic [Stopwatch] keyed on `IdleHint`
/// edges. D-Bus's `IdleSinceHintMonotonic` is monotonic-domain time and
/// Dart exposes no `CLOCK_MONOTONIC` without extra FFI; a `Stopwatch` IS
/// monotonic, so `IdleHint=true` from the first observation on yields the
/// same duration, quantised to the poll interval (±2 s, irrelevant at the
/// 5-minute threshold). Cold-start caveat: if the user was already idle
/// before the app started, idle counts from app start until the next
/// activity cycle.
library;

import 'dart:async';
import 'dart:io' show pid;

import 'package:dbus/dbus.dart';

import '../presence_platform.dart';
import '../presence_state.dart';

PresencePlatform createLinuxPresencePlatform() => _LinuxPresencePlatform();

class _LinuxPresencePlatform implements PresencePlatform {
  final StreamController<PresencePlatformEvent> _controller =
      StreamController<PresencePlatformEvent>.broadcast(sync: true);

  DBusClient? _client;
  _LinuxMechanism? _mechanism;
  Timer? _pollTimer;
  bool _started = false;

  @override
  bool get supported => true;

  @override
  String? get unsupportedReason => null;

  @override
  String get mechanism => _mechanism?.id ?? 'linux';

  @override
  Stream<PresencePlatformEvent> samples() => _controller.stream;

  @override
  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;

    final DBusClient client;
    try {
      client = DBusClient.session();
    } catch (error) {
      _controller.add(
        PresenceUnavailableEvent('D-Bus session bus unavailable: $error'),
      );
      return;
    }
    _client = client;

    final factories = <_LinuxMechanism Function()>[
      () => _LogindMechanism(client, _controller),
      () => _GnomeIdleMechanism(client, _controller),
      () => _KdeScreensaverMechanism(client, _controller),
    ];

    for (final create in factories) {
      final mechanism = create();
      try {
        await mechanism.start();
      } catch (_) {
        // This desktop does not provide this mechanism; try the next one.
        continue;
      }
      _mechanism = mechanism;
      // Push signals (logind Lock/Unlock/PropertiesChanged, KDE
      // ActiveChanged) carry transitions; the 2 s poll re-syncs idle time
      // and covers desktops without push.
      _pollTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _safePoll(mechanism),
      );
      return;
    }

    _controller.add(
      const PresenceUnavailableEvent(
        'no presence mechanism responded (logind, GNOME IdleMonitor or '
        'KDE ScreenSaver)',
      ),
    );
  }

  Future<void> _safePoll(_LinuxMechanism mechanism) async {
    try {
      await mechanism.poll();
    } catch (_) {
      _controller.add(
        PresenceUnavailableEvent('${mechanism.id} stopped responding'),
      );
    }
  }

  @override
  Future<void> stop() async {
    if (!_started) {
      return;
    }
    _started = false;
    _pollTimer?.cancel();
    _pollTimer = null;
    await _mechanism?.stop();
    _mechanism = null;
    await _client?.close();
    _client = null;
  }
}

/// Shared plumbing for the per-desktop mechanisms: they all write into the
/// platform's controller and only differ in where lock/idle come from.
abstract class _LinuxMechanism {
  _LinuxMechanism(this._client, this._controller);

  final DBusClient _client;
  final StreamController<PresencePlatformEvent> _controller;

  /// Identifier reported as `PresenceState.mechanism`.
  String get id;

  /// Probe and initialise. Throws when this mechanism is not available on
  /// the current desktop, in which case the platform tries the next one.
  Future<void> start();

  /// Re-read the current state and emit it.
  Future<void> poll();

  /// Release signal subscriptions.
  Future<void> stop() async {}

  void emitSample(PresenceSample sample) {
    if (!_controller.isClosed) {
      _controller.add(PresenceSampleEvent(sample));
    }
  }

  void emitUnavailable(String reason) {
    if (!_controller.isClosed) {
      _controller.add(PresenceUnavailableEvent(reason));
    }
  }
}

/// logind (`org.freedesktop.login1`) — the primary mechanism: covers lock,
/// idle and sleep on every logind desktop.
class _LogindMechanism extends _LinuxMechanism {
  _LogindMechanism(super.client, super.controller);

  static const String _service = 'org.freedesktop.login1';
  static const String _managerPath = '/org/freedesktop/login1';
  static const String _managerInterface = 'org.freedesktop.login1.Manager';
  static const String _sessionInterface = 'org.freedesktop.login1.Session';

  late DBusRemoteObject _session;
  final Stopwatch _idleClock = Stopwatch();
  StreamSubscription<DBusSignal>? _lockSub;
  StreamSubscription<DBusSignal>? _unlockSub;
  StreamSubscription<DBusSignal>? _sleepSub;
  StreamSubscription<DBusPropertiesChangedSignal>? _propsSub;
  bool _suspended = false;

  @override
  String get id => 'logind';

  @override
  Future<void> start() async {
    final manager = DBusRemoteObject(
      _client,
      name: _service,
      path: const DBusObjectPath.unchecked(_managerPath),
    );
    // Throws on desktops without logind → platform falls back.
    final reply = await manager.callMethod(
      _managerInterface,
      'GetSessionByPID',
      [DBusUint32(pid)],
      replySignature: DBusSignature('o'),
    );
    final sessionPath = reply.returnValues[0].asObjectPath();
    _session = DBusRemoteObject(
      _client,
      name: _service,
      path: sessionPath,
    );

    // Push: the lock state changes the moment it happens, not on the next
    // poll tick.
    _lockSub = DBusRemoteObjectSignalStream(
      object: _session,
      interface: _sessionInterface,
      name: 'Lock',
    ).listen((_) => emitSample(PresenceSample(
          locked: true,
          idleFor: _idleFor,
        )));

    _unlockSub = DBusRemoteObjectSignalStream(
      object: _session,
      interface: _sessionInterface,
      name: 'Unlock',
    ).listen((_) => poll());

    _sleepSub = DBusRemoteObjectSignalStream(
      object: manager,
      interface: _managerInterface,
      name: 'PrepareForSleep',
    ).listen((signal) {
      final suspending = signal.values.isNotEmpty && signal.values[0].asBoolean();
      _suspended = suspending;
      if (suspending) {
        // Screens are off while suspended: presence is absent.
        emitSample(PresenceSample(locked: true, idleFor: _idleFor));
      } else {
        poll();
      }
    });

    _propsSub = _session.propertiesChanged.listen((change) {
      if (change.propertiesInterface != _sessionInterface) {
        return;
      }
      _applyProps(change.changedProperties);
    });

    await poll();
  }

  @override
  Future<void> poll() async {
    final props = await _session.getAllProperties(_sessionInterface);
    if (!props.containsKey('LockedHint') || !props.containsKey('IdleHint')) {
      emitUnavailable('logind session properties unavailable');
      return;
    }
    _applyProps(props);
  }

  @override
  Future<void> stop() async {
    await _lockSub?.cancel();
    await _unlockSub?.cancel();
    await _sleepSub?.cancel();
    await _propsSub?.cancel();
  }

  Duration get _idleFor =>
      _idleClock.isRunning ? _idleClock.elapsed : Duration.zero;

  /// Derives lock/idle from the logind session properties. `IdleHint` edges
  /// drive a local monotonic stopwatch (see the library doc comment);
  /// `IdleSinceHintMonotonic` arrives in the same `GetAll` reply and is
  /// deliberately not used for arithmetic.
  void _applyProps(Map<String, DBusValue> props) {
    if (_suspended) {
      // Stay "locked" while the machine sleeps; the resume poll below will
      // correct the state.
      return;
    }
    final locked = props['LockedHint']!.asBoolean();
    final idle = props['IdleHint']!.asBoolean();
    if (idle && !_idleClock.isRunning) {
      _idleClock
        ..reset()
        ..start();
    } else if (!idle && _idleClock.isRunning) {
      _idleClock
        ..stop()
        ..reset();
    }
    emitSample(PresenceSample(locked: locked, idleFor: _idleFor));
  }
}

/// GNOME without a usable logind session (rare; GNOME normally uses
/// logind): idle from `org.gnome.Mutter.IdleMonitor.GetIdletime`, lock from
/// `org.freedesktop.ScreenSaver.GetActive` where the desktop provides it.
class _GnomeIdleMechanism extends _LinuxMechanism {
  _GnomeIdleMechanism(super.client, super.controller);

  static const String _service = 'org.gnome.Mutter.IdleMonitor';
  static const String _path = '/org/gnome/Mutter/IdleMonitor';
  static const String _interface = 'org.gnome.Mutter.IdleMonitor';

  DBusRemoteObject? _idleMonitor;
  DBusRemoteObject? _screenSaver;
  bool _hasLockSource = false;

  @override
  String get id => 'gnome-idle-monitor';

  @override
  Future<void> start() async {
    _idleMonitor = DBusRemoteObject(
      _client,
      name: _service,
      path: const DBusObjectPath.unchecked(_path),
    );
    // Probe: throws (→ fallback) when Mutter's IdleMonitor is absent.
    await _idleMonitor!.callMethod(
      _interface,
      'GetIdletime',
      const [],
      replySignature: DBusSignature('t'),
    );
    try {
      final screensaver = DBusRemoteObject(
        _client,
        name: 'org.freedesktop.ScreenSaver',
        path: const DBusObjectPath.unchecked('/ScreenSaver'),
      );
      await screensaver.callMethod(
        'org.freedesktop.ScreenSaver',
        'GetActive',
        const [],
        replySignature: DBusSignature('b'),
      );
      _screenSaver = screensaver;
      _hasLockSource = true;
    } catch (_) {
      _hasLockSource = false;
    }
  }

  @override
  Future<void> poll() async {
    final idleReply = await _idleMonitor!.callMethod(
      _interface,
      'GetIdletime',
      const [],
      replySignature: DBusSignature('t'),
    );
    final idleMilliseconds = idleReply.returnValues[0].asUint64();

    var locked = false;
    if (_hasLockSource) {
      final lockReply = await _screenSaver!.callMethod(
        'org.freedesktop.ScreenSaver',
        'GetActive',
        const [],
        replySignature: DBusSignature('b'),
      );
      locked = lockReply.returnValues[0].asBoolean();
    }

    emitSample(PresenceSample(
      locked: locked,
      idleFor: Duration(milliseconds: idleMilliseconds),
      degraded: !_hasLockSource,
      degradedReason:
          !_hasLockSource ? 'lock state unavailable on this desktop' : null,
    ));
  }
}

/// KDE (and other desktops exposing the freedesktop screensaver interface):
/// idle from `GetSessionIdleTime`, lock from `GetActive`, pushed by
/// `ActiveChanged`.
class _KdeScreensaverMechanism extends _LinuxMechanism {
  _KdeScreensaverMechanism(super.client, super.controller);

  static const String _service = 'org.freedesktop.ScreenSaver';
  static const String _path = '/ScreenSaver';
  static const String _interface = 'org.freedesktop.ScreenSaver';

  DBusRemoteObject? _screensaver;
  StreamSubscription<DBusSignal>? _activeSub;

  @override
  String get id => 'kde-screensaver';

  @override
  Future<void> start() async {
    _screensaver = DBusRemoteObject(
      _client,
      name: _service,
      path: const DBusObjectPath.unchecked(_path),
    );
    // Probe: throws (→ fallback) when no screensaver service exists.
    await _screensaver!.callMethod(
      _interface,
      'GetSessionIdleTime',
      const [],
      replySignature: DBusSignature('u'),
    );
    _activeSub = DBusRemoteObjectSignalStream(
      object: _screensaver!,
      interface: _interface,
      name: 'ActiveChanged',
    ).listen((_) => poll());
  }

  @override
  Future<void> poll() async {
    final idleReply = await _screensaver!.callMethod(
      _interface,
      'GetSessionIdleTime',
      const [],
      replySignature: DBusSignature('u'),
    );
    final idleMilliseconds = idleReply.returnValues[0].asUint32();
    final lockReply = await _screensaver!.callMethod(
      _interface,
      'GetActive',
      const [],
      replySignature: DBusSignature('b'),
    );
    final locked = lockReply.returnValues[0].asBoolean();
    emitSample(PresenceSample(
      locked: locked,
      idleFor: Duration(milliseconds: idleMilliseconds),
    ));
  }

  @override
  Future<void> stop() async {
    await _activeSub?.cancel();
  }
}
