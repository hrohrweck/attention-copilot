/// The desktop disruptive alert surface: un-ignorable always-on-top windows
/// plus looping audio, driven exclusively by the alert engine through
/// [AlertSurfacePort].
///
/// Design rules:
///   * the surface never decides an alert is over — it only consumes
///     `ring` / `escalate` / `stop` from the engine;
///   * **acknowledgement is the ONLY way audio stops**: the alert window is
///     not closable until acknowledged — OS close attempts re-raise it and
///     keep it ringing;
///   * audio loops by replaying on completion, never by relying on a gapless
///     native loop;
///   * a deferred alert is reported by the engine simply *not* calling
///     `ring`, so the surface stays silent by construction (it never plays
///     audio on its own initiative).
library;

import 'dart:async';

import 'package:attention_copilot/domain/alert_engine.dart';
import 'package:attention_copilot/domain/alert_policy.dart';

/// One display as the alert surface sees it.
final class AlertDisplay {
  const AlertDisplay({required this.id, this.name});

  /// Stable platform display id (from `screen_retriever`'s `Display.id`).
  final String id;

  /// Human-readable display name, when the platform provides one.
  final String? name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AlertDisplay && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

/// A window the surface created for one display.
final class AlertWindowHandle {
  const AlertWindowHandle({
    required this.id,
    required this.displayId,
    this.managed = true,
  });

  /// Surface-scoped window identity.
  final String id;

  /// The display this window was created for.
  final String displayId;

  /// False when the platform could not create a real window for this display
  /// (e.g. `window_manager` manages a single native window). The surface
  /// keeps issuing the same commands — the driver no-ops them — so escalation
  /// logic stays uniform and diagnostics can state the limitation.
  final bool managed;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AlertWindowHandle &&
          other.id == id &&
          other.displayId == displayId &&
          other.managed == managed;

  @override
  int get hashCode => Object.hash(id, displayId, managed);
}

/// Low-level window/audio driver behind [DesktopAlertSurface].
///
/// The real implementation ([WindowManagerAudioDriver] in
/// `alert_platform_driver.dart`) uses `window_manager` + `screen_retriever`
/// for windows and `audioplayers` for audio; tests substitute a fake. The
/// surface contains no platform calls of its own.
abstract interface class AlertPlatformDriver {
  /// The attached displays. An empty result is treated by the surface as
  /// "unknown — a single primary display".
  Future<List<AlertDisplay>> listDisplays();

  /// Creates (or claims) one alert window for [display].
  Future<AlertWindowHandle> createWindow(AlertDisplay display);

  Future<void> showWindow(AlertWindowHandle window);

  Future<void> focusWindow(AlertWindowHandle window);

  Future<void> setAlwaysOnTop(AlertWindowHandle window, bool value);

  Future<void> setFullScreen(AlertWindowHandle window, bool value);

  /// Closes the door until acknowledged: while `true` the OS close button
  /// must not destroy the window (it emits [windowCloseRequested] instead).
  Future<void> setPreventClose(AlertWindowHandle window, bool value);

  /// Applies the accent token to the alert window content.
  Future<void> setAccent(AlertWindowHandle window, String accent);

  Future<void> closeWindow(AlertWindowHandle window);

  /// Emitted when the user attempts to close an alert window (close button,
  /// Alt+F4, ...) while it is still shown. The surface must re-raise it.
  Stream<AlertWindowHandle> get windowCloseRequested;

  /// Plays (or restarts from the beginning) the audio cycle for [audioId]
  /// at [volume]. Replaces whatever cycle is currently playing.
  Future<void> playAudio(String audioId, {required double volume});

  /// Changes the volume of the current cycle without restarting it.
  Future<void> setAudioVolume(double volume);

  /// Stops audio outright. The ONLY place audio ever stops.
  Future<void> stopAudio();

  /// Emitted when the current audio cycle reached its natural end.
  Stream<void> get audioCycleCompleted;

  /// Releases all platform resources. Idempotent.
  Future<void> dispose();
}

/// The user-facing alert surface: the local contract on top of the engine's
/// [AlertSurfacePort].
///
/// Implementations: [DesktopAlertSurface] (real, over an
/// [AlertPlatformDriver]) and [FakeAlertSurface] (engine/sibling tests).
abstract interface class AlertSurface implements AlertSurfacePort {
  /// Wires what happens when the user acknowledges (Dismiss/Join). The app
  /// wires this to the engine's `acknowledge`, which in turn calls `stop` —
  /// the surface itself never decides an alert is over.
  void setOnAcknowledgement(void Function(String alarmId) onAcknowledgement);

  /// Called by the alert window UI when the user acknowledges. Forwards to
  /// the wired handler; no-op when the alarm is not ringing.
  void requestAcknowledgement(String alarmId);

  /// Releases platform resources (windows, audio). Idempotent.
  Future<void> dispose();
}

/// The real desktop alert surface.
///
/// Consumes the engine's [AlertSurfacePort] calls and drives the platform
/// through an [AlertPlatformDriver]:
///   * `ring` opens one always-on-top alert window per display (see
///     [alertOnAllDisplays]) and starts the audio cycle at the profile's
///     volume and accent;
///   * `escalate` maps each [EscalationAction] onto window/audio behaviour
///     and keeps the escalation log;
///   * `stop` — reached only via acknowledgement — frees the close lock,
///     closes the windows and stops the audio.
class DesktopAlertSurface implements AlertSurface {
  DesktopAlertSurface({
    required this.driver,
    this.alertOnAllDisplays,
    this.volumeStep = 0.1,
    this.accentLadder = const ['amber', 'orange', 'red'],
  }) {
    _closeSub = driver.windowCloseRequested.listen(_onWindowCloseRequested);
    _audioCompleteSub = driver.audioCycleCompleted.listen((_) {
      _onAudioCycleCompleted();
    });
  }

  final AlertPlatformDriver driver;

  /// Whether to open an alert window on every attached display. Null (the
  /// default) means ON when 2+ displays exist — a single window on the
  /// monitor the user is not looking at would not be un-ignorable.
  final bool? alertOnAllDisplays;

  /// Volume added by one `raiseVolume` escalation step.
  final double volumeStep;

  /// Accent intensities, weakest first; `changeAccent` walks this ladder and
  /// stays at the strongest.
  final List<String> accentLadder;

  final Set<String> _ringing = {};
  final Map<String, AlertTrigger> _triggerByAlarm = {};
  final Map<String, List<AlertWindowHandle>> _windowsByAlarm = {};
  final Map<String, double> _volumeByAlarm = {};
  final Map<String, String> _accentByAlarm = {};
  final Map<String, int> _closeAttemptsByAlarm = {};
  final Map<String, List<EscalationAction>> _escalationsByAlarm = {};

  /// The alarm whose audio cycle currently owns the (single) audio channel.
  String? _audioAlarmId;
  late final StreamSubscription<AlertWindowHandle> _closeSub;
  late final StreamSubscription<void> _audioCompleteSub;
  void Function(String alarmId)? _onAcknowledgement;
  bool _disposed = false;

  // ---------------------------------------------------------------------
  // AlertSurfacePort
  // ---------------------------------------------------------------------

  @override
  void ring(
    AlertTrigger trigger, {
    required List<AcknowledgementAction> actions,
  }) {
    final alarmId = trigger.alarmId;
    final profile = trigger.lead.profile;
    _ringing.add(alarmId);
    _triggerByAlarm[alarmId] = trigger;
    _volumeByAlarm[alarmId] = profile.volume;
    _accentByAlarm[alarmId] = profile.accent;
    unawaited(_openWindows(alarmId, profile: profile));
    unawaited(_startAudio(alarmId));
  }

  @override
  void escalate(String alarmId, EscalationStep step) {
    // Deferred or unknown alerts never ring, so they never escalate.
    if (!_ringing.contains(alarmId)) return;
    _escalationsByAlarm.putIfAbsent(alarmId, () => []).add(step.action);
    switch (step.action) {
      case EscalationAction.repeatAudioCycle:
        // Restart the cycle from the top at the current (possibly escalated)
        // volume. The repeat cadence is the engine's `repeatEvery`.
        unawaited(_startAudio(alarmId));
      case EscalationAction.raiseVolume:
        final current = _volumeByAlarm[alarmId] ?? 0.0;
        final next = current + volumeStep > 1.0 ? 1.0 : current + volumeStep;
        _volumeByAlarm[alarmId] = next;
        unawaited(driver.setAudioVolume(next));
      case EscalationAction.reRaiseWindow:
        unawaited(_reRaise(alarmId));
      case EscalationAction.changeAccent:
        final current = _accentByAlarm[alarmId] ?? accentLadder.first;
        final next = _nextAccent(current);
        _accentByAlarm[alarmId] = next;
        unawaited(_setAccent(alarmId, next));
      case EscalationAction.holdWindowAndRemind:
        // Hold: re-assert the window and make sure the audio channel is
        // alive. The periodic reminder cadence is the engine re-sending
        // this step at `repeatEvery`.
        unawaited(_reRaise(alarmId));
        unawaited(_ensureAudio(alarmId));
    }
  }

  @override
  void stop(String alarmId) {
    if (!_ringing.contains(alarmId)) return;
    _ringing.remove(alarmId);
    final windows =
        _windowsByAlarm.remove(alarmId) ?? const <AlertWindowHandle>[];
    // Free the close lock first: only an acknowledged alert may close.
    for (final window in windows) {
      unawaited(driver.setPreventClose(window, false));
      unawaited(driver.closeWindow(window));
    }
    if (alarmId == _audioAlarmId) {
      _audioAlarmId = null;
      unawaited(driver.stopAudio());
      if (_ringing.isNotEmpty) {
        // Another alert is still ringing: its cycle takes the channel.
        unawaited(_startAudio(_ringing.first));
      }
    }
  }

  // ---------------------------------------------------------------------
  // AlertSurface (acknowledgement + lifecycle)
  // ---------------------------------------------------------------------

  @override
  void setOnAcknowledgement(void Function(String alarmId) onAcknowledgement) {
    _onAcknowledgement = onAcknowledgement;
  }

  @override
  void requestAcknowledgement(String alarmId) {
    final handler = _onAcknowledgement;
    if (handler == null || !_ringing.contains(alarmId)) return;
    handler(alarmId);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _closeSub.cancel();
    await _audioCompleteSub.cancel();
    _ringing.clear();
    _audioAlarmId = null;
    await driver.dispose();
  }

  // ---------------------------------------------------------------------
  // Observability (tests + diagnostics)
  // ---------------------------------------------------------------------

  bool isRinging(String alarmId) => _ringing.contains(alarmId);

  /// The current (possibly escalated) volume of a ringing alarm.
  double volumeFor(String alarmId) => _volumeByAlarm[alarmId] ?? 0.0;

  /// The current (possibly escalated) accent of a ringing alarm.
  String? accentFor(String alarmId) => _accentByAlarm[alarmId];

  /// How many OS close attempts were made on this alarm while unacknowledged.
  int closeAttemptsFor(String alarmId) => _closeAttemptsByAlarm[alarmId] ?? 0;

  /// The escalation actions received for this alarm, in order.
  List<EscalationAction> escalationLog(String alarmId) =>
      List.unmodifiable(_escalationsByAlarm[alarmId] ?? const []);

  /// The windows currently open for this alarm (one per covered display).
  List<AlertWindowHandle> windowsFor(String alarmId) => List.unmodifiable(
        _windowsByAlarm[alarmId] ?? const <AlertWindowHandle>[],
      );

  // ---------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------

  Future<void> _openWindows(
    String alarmId, {
    required AlertProfile profile,
  }) async {
    final displays = await driver.listDisplays();
    final usable = displays.isEmpty
        ? const [AlertDisplay(id: 'primary', name: 'Primary display')]
        : displays;
    final multiDisplay = usable.length > 1;
    final targets = (alertOnAllDisplays ?? multiDisplay)
        ? usable
        : usable.take(1).toList();

    final windows = <AlertWindowHandle>[];
    for (final display in targets) {
      final window = await driver.createWindow(display);
      // Always-on-top is re-asserted before every show: the window must
      // never lose topmost after a refocus.
      await driver.setAlwaysOnTop(window, true);
      if (profile.fullscreen) {
        await driver.setFullScreen(window, true);
      }
      await driver.setAccent(window, profile.accent);
      // Not closable until acknowledged.
      await driver.setPreventClose(window, true);
      await driver.showWindow(window);
      await driver.focusWindow(window);
      windows.add(window);
    }
    _windowsByAlarm[alarmId] = windows;
  }

  /// Starts (or restarts) the audio cycle for [alarmId] at its current
  /// volume and makes it the owner of the audio channel.
  Future<void> _startAudio(String alarmId) async {
    final t = _triggerByAlarm[alarmId];
    if (t == null) return;
    _audioAlarmId = alarmId;
    final volume = _volumeByAlarm[alarmId] ?? t.lead.profile.volume;
    await driver.playAudio(t.lead.profile.audioId, volume: volume);
  }

  /// Restarts the ringing alarm's cycle if the channel is silent.
  Future<void> _ensureAudio(String alarmId) async {
    if (_audioAlarmId != null) return;
    await _startAudio(alarmId);
  }

  /// Re-asserts every window of the alarm: topmost, shown, focused.
  Future<void> _reRaise(String alarmId) async {
    for (final window in _windowsByAlarm[alarmId] ??
        const <AlertWindowHandle>[]) {
      await driver.setAlwaysOnTop(window, true);
      await driver.showWindow(window);
      await driver.focusWindow(window);
    }
  }

  Future<void> _setAccent(String alarmId, String accent) async {
    for (final window in _windowsByAlarm[alarmId] ??
        const <AlertWindowHandle>[]) {
      await driver.setAccent(window, accent);
    }
  }

  String _nextAccent(String current) {
    final index = accentLadder.indexOf(current);
    if (index < 0) return accentLadder.last;
    if (index + 1 < accentLadder.length) return accentLadder[index + 1];
    return accentLadder.last;
  }

  String? _ownerOf(AlertWindowHandle window) {
    for (final entry in _windowsByAlarm.entries) {
      if (entry.value.any((w) => w.id == window.id)) return entry.key;
    }
    return null;
  }

  void _onWindowCloseRequested(AlertWindowHandle window) {
    unawaited(_reRaiseAfterCloseAttempt(window));
  }

  /// The acknowledgement gate: a close attempt on a ringing alert re-arms
  /// close prevention, re-raises the window and keeps the audio going.
  Future<void> _reRaiseAfterCloseAttempt(AlertWindowHandle window) async {
    final owner = _ownerOf(window);
    if (owner == null || !_ringing.contains(owner)) return;
    _closeAttemptsByAlarm[owner] = (_closeAttemptsByAlarm[owner] ?? 0) + 1;
    await driver.setPreventClose(window, true);
    await driver.showWindow(window);
    await driver.setAlwaysOnTop(window, true);
    await driver.focusWindow(window);
  }

  /// Replay-on-completion: when a cycle ends and the alert is still ringing
  /// with `loopAudio`, start it again. Never a gapless native loop.
  void _onAudioCycleCompleted() {
    final alarmId = _audioAlarmId;
    if (alarmId == null || !_ringing.contains(alarmId)) return;
    final t = _triggerByAlarm[alarmId];
    if (t == null || !t.lead.profile.loopAudio) return;
    unawaited(_startAudio(alarmId));
  }
}

/// Recording [AlertSurface] for engine and integration tests.
class FakeAlertSurface implements AlertSurface {
  final List<AlertTrigger> rung = [];
  final List<(String, EscalationStep)> escalations = [];
  final List<String> stopped = [];
  final List<String> acknowledged = [];
  void Function(String alarmId)? _onAcknowledgement;

  @override
  void ring(
    AlertTrigger trigger, {
    required List<AcknowledgementAction> actions,
  }) {
    rung.add(trigger);
  }

  @override
  void escalate(String alarmId, EscalationStep step) {
    escalations.add((alarmId, step));
  }

  @override
  void stop(String alarmId) {
    stopped.add(alarmId);
  }

  @override
  void setOnAcknowledgement(void Function(String alarmId) onAcknowledgement) {
    _onAcknowledgement = onAcknowledgement;
  }

  @override
  void requestAcknowledgement(String alarmId) {
    acknowledged.add(alarmId);
    _onAcknowledgement?.call(alarmId);
  }

  @override
  Future<void> dispose() async {}

  /// Whether the alarm has rung and has not been stopped since.
  bool isRinging(String alarmId) =>
      rung.any((t) => t.alarmId == alarmId) && !stopped.contains(alarmId);
}
