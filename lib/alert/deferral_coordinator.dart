import 'dart:async';

import '../domain/alert_engine.dart';
import '../presence/presence_service.dart';
import '../presence/presence_state.dart';

/// Wires a [PresenceService] into an [AlertEngine]: every derived
/// [PresenceState] is mapped onto the engine's [EnginePresence] and
/// forwarded through `onPresenceChanged`, so the engine defers due alerts
/// while the machine is locked or the user is away, and catches up on
/// return. Unlock transitions additionally fire `onWakeOrUnlock`, because
/// the machine may have been asleep and due instants may have passed while
/// the app could not run.
///
/// The coordinator never reads the wall clock: [now] is injected, so tests
/// (and the app) control time.
///
/// The presence-aware threshold and override are mutable so the app can
/// push settings-store changes through without rebuilding the coordinator.
class DeferralCoordinator {
  DeferralCoordinator({
    required PresenceService presence,
    required AlertEngine engine,
    required DateTime Function() now,
    this.quietWhenAwayThreshold = kDefaultIdleThreshold,
    this.alertEvenWhileLockedOrAway = false,
  })  : _presenceService = presence,
        _alertEngine = engine,
        _clock = now;

  /// The presence source whose [PresenceService.states] are consumed.
  final PresenceService _presenceService;

  /// The engine that defers and fires alerts according to the reported
  /// presence.
  final AlertEngine _alertEngine;

  /// Injected clock; every hook argument is read through it.
  final DateTime Function() _clock;

  /// Idle duration at or above which an unlocked user counts as away.
  /// Defaults to [kDefaultIdleThreshold] (5 minutes); the app can bind this
  /// to the persisted settings value.
  Duration quietWhenAwayThreshold;

  /// Manual override: when `true` the coordinator always reports
  /// [EnginePresence.active], so alerts fire even while locked or away.
  /// Defaults to OFF.
  bool alertEvenWhileLockedOrAway;

  StreamSubscription<PresenceState>? _subscription;
  PresenceState? _lastState;
  EnginePresence? _reported;

  /// Subscribes to the presence stream (receiving the current state
  /// immediately — the stream replays it on subscribe) and starts the
  /// underlying mechanism. Idempotent.
  Future<void> start() async {
    if (_subscription != null) {
      return;
    }
    _subscription = _presenceService.states().listen(_onState);
    await _presenceService.start();
  }

  /// Cancels the subscription and stops the underlying mechanism.
  /// Idempotent.
  Future<void> dispose() async {
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    await _presenceService.stop();
  }

  /// Maps a [PresenceState] onto the engine's [EnginePresence].
  ///
  /// A platform with no presence mechanism (`supported == false`) cannot
  /// know whether the user is present, so it maps to `active`: presence must
  /// never silently suppress alerts it cannot measure.
  EnginePresence _mapState(PresenceState state) {
    if (alertEvenWhileLockedOrAway || !state.supported) {
      return EnginePresence.active;
    }
    if (state.locked) {
      return EnginePresence.locked;
    }
    if (!state.active || state.idleFor > quietWhenAwayThreshold) {
      return EnginePresence.away;
    }
    return EnginePresence.active;
  }

  void _onState(PresenceState state) {
    final previous = _lastState;
    _lastState = state;

    // An unlock is a wake/resume: the machine may have been asleep, so the
    // engine must re-run its return processing against the fresh `now`.
    final unlocked = previous != null && previous.locked && !state.locked;
    if (unlocked) {
      _alertEngine.onWakeOrUnlock(_clock());
    }

    final mapped = _mapState(state);
    if (mapped != _reported) {
      _reported = mapped;
      _alertEngine.onPresenceChanged(mapped, _clock());
    }
  }
}
