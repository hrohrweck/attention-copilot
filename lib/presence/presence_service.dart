import 'dart:async';

import 'presence_platform.dart';
import 'presence_state.dart';
import 'presence_state_machine.dart';

/// Idle duration at or above which the user counts as away, unless a
/// consumer configures another threshold. Mirrors the engine's planned
/// `quietWhenAwayThreshold` default (5 minutes).
const Duration kDefaultIdleThreshold = Duration(minutes: 5);

/// Cross-platform screen-lock and user-idle detection behind one interface.
///
/// Implementations: [StreamPresenceService] (real, over a
/// [PresencePlatform]) and [FakePresenceService] (tests). Consumers listen
/// to [states] and call [start] once; [stop] releases the mechanism.
abstract interface class PresenceService {
  /// Derived presence states. A broadcast stream: every listener receives
  /// the current state on subscribe and every transition afterwards.
  ///
  /// Only transitions are emitted (locked/unlocked, active/inactive, the
  /// degradation flags), never mere idle-time growth — see
  /// [PresenceStateMachine].
  Stream<PresenceState> states();

  /// Starts presence detection. Idempotent. On a platform where no
  /// mechanism responds, emits exactly one `supported=false` state with a
  /// reason and never throws.
  Future<void> start();

  /// Stops detection and releases OS resources. Idempotent, never throws.
  Future<void> stop();
}

/// [PresenceService] over a real [PresencePlatform], with the platform's
/// raw samples reduced by a [PresenceStateMachine].
class StreamPresenceService implements PresenceService {
  StreamPresenceService({
    required PresencePlatform platform,
    this.idleThreshold = kDefaultIdleThreshold,
  }) : _platform = platform,
       _machine = PresenceStateMachine(
         idleThreshold: idleThreshold,
         mechanism: platform.mechanism,
       );

  final PresencePlatform _platform;
  final Duration idleThreshold;
  final PresenceStateMachine _machine;

  late final StreamController<PresenceState> _controller =
      StreamController<PresenceState>.broadcast(
    sync: true,
    onListen: () {
      // Replay the current state to the first listener so the UI can always
      // render something on subscribe.
      final last = _last;
      if (last != null && !_controller.isClosed) {
        _controller.add(last);
      }
    },
  );

  StreamSubscription<PresencePlatformEvent>? _subscription;
  PresenceState? _last;
  bool _started = false;
  bool _unavailable = false;

  @override
  Stream<PresenceState> states() => _controller.stream;

  @override
  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;
    _machine.reset();
    if (!_platform.supported) {
      _emitUnavailable(
        _platform.unsupportedReason ??
            'presence not supported on this platform',
      );
      return;
    }
    try {
      _subscription = _platform.samples().listen(
            _onEvent,
            onError: (Object error, StackTrace stackTrace) =>
                _emitUnavailable('presence mechanism failed: $error'),
          );
      await _platform.start();
    } catch (error) {
      _emitUnavailable('presence mechanism failed to start: $error');
    }
  }

  @override
  Future<void> stop() async {
    if (!_started) {
      return;
    }
    _started = false;
    await _subscription?.cancel();
    _subscription = null;
    await _platform.stop();
  }

  void _onEvent(PresencePlatformEvent event) {
    switch (event) {
      case PresenceSampleEvent(:final sample):
        if (_unavailable) {
          return;
        }
        final next = _machine.onSample(sample);
        if (next != null) {
          _emit(next);
        }
      case PresenceUnavailableEvent(:final reason):
        _emitUnavailable(reason);
    }
  }

  void _emitUnavailable(String reason) {
    if (_unavailable) {
      return;
    }
    _unavailable = true;
    _emit(
      PresenceState.unsupported(
        reason: reason,
        mechanism: _platform.mechanism,
      ),
    );
  }

  void _emit(PresenceState state) {
    _last = state;
    if (!_controller.isClosed) {
      _controller.add(state);
    }
  }
}

/// Scriptable [PresenceService] for tests and previews.
///
/// Drives the SAME [PresenceStateMachine] as [StreamPresenceService], so
/// tests written against the fake exercise the real state logic. Samples are
/// injected synchronously with [emitSample]; listeners receive emissions
/// synchronously.
class FakePresenceService implements PresenceService {
  FakePresenceService({
    this.idleThreshold = kDefaultIdleThreshold,
    this.supported = true,
    this.unsupportedReason,
    String mechanism = 'fake',
  }) : _machine = PresenceStateMachine(
          idleThreshold: idleThreshold,
          mechanism: mechanism,
        );

  final Duration idleThreshold;

  /// Mirrors [PresencePlatform.supported]: when `false`, the fake behaves
  /// like a platform with no mechanism (emits one `supported=false` state
  /// and silently ignores injected samples).
  final bool supported;

  /// Why [supported] is `false` (used only when it is).
  final String? unsupportedReason;

  final PresenceStateMachine _machine;

  late final StreamController<PresenceState> _controller =
      StreamController<PresenceState>.broadcast(
    sync: true,
    onListen: () {
      final last = _last;
      if (last != null && !_controller.isClosed) {
        _controller.add(last);
      }
    },
  );

  PresenceState? _last;

  @override
  Stream<PresenceState> states() => _controller.stream;

  @override
  Future<void> start() async {
    if (!supported && _last == null) {
      _emit(
        PresenceState.unsupported(
          reason: unsupportedReason ?? 'presence not supported',
          mechanism: 'fake',
        ),
      );
    }
  }

  @override
  Future<void> stop() async {
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }

  /// Injects a raw platform sample through the machine. On an unsupported
  /// fake this is a silent no-op (mirroring the real service, which ignores
  /// everything after unavailability) and never throws.
  void emitSample({
    required bool locked,
    Duration idleFor = Duration.zero,
    bool degraded = false,
    String? degradedReason,
  }) {
    if (!supported) {
      return;
    }
    final next = _machine.onSample(
      PresenceSample(
        locked: locked,
        idleFor: idleFor,
        degraded: degraded,
        degradedReason: degradedReason,
      ),
    );
    if (next != null) {
      _emit(next);
    }
  }

  void _emit(PresenceState state) {
    _last = state;
    if (!_controller.isClosed) {
      _controller.add(state);
    }
  }
}
