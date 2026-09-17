import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:attention_copilot/alert/deferral_coordinator.dart';
import 'package:attention_copilot/domain/alert_engine.dart';
import 'package:attention_copilot/domain/alert_policy.dart';
import 'package:attention_copilot/presence/presence_service.dart';
import 'package:attention_copilot/presence/presence_state.dart';

/// Scriptable presence service emitting exactly the states the test wants —
/// no state machine in between, so a test can emit any (locked, idleFor,
/// active) combination, including ones the real machine would only produce
/// under a different threshold.
class _ScriptedPresence implements PresenceService {
  final StreamController<PresenceState> _controller =
      StreamController<PresenceState>.broadcast(sync: true);

  bool started = false;

  @override
  Stream<PresenceState> states() => _controller.stream;

  @override
  Future<void> start() async => started = true;

  @override
  Future<void> stop() async {}

  void emit(PresenceState state) => _controller.add(state);
}

/// Records every scheduler call; the coordinator never touches it directly,
/// but the engine constructor requires a port.
class _FakeScheduler implements AlertSchedulerPort {
  @override
  void schedule(DateTime instantUtc, String alarmId) {}

  @override
  void cancel(String alarmId) {}
}

class _FakeSurface implements AlertSurfacePort {
  @override
  void ring(
    AlertTrigger trigger, {
    required List<AcknowledgementAction> actions,
  }) {}

  @override
  void escalate(String alarmId, EscalationStep step) {}

  @override
  void stop(String alarmId) {}
}

class _FakePersistence implements AlertPersistencePort {
  @override
  Future<void> savePending(List<PendingTriggerRecord> records) async {}

  @override
  Future<List<PendingTriggerRecord>> loadPending() async => const [];
}

/// Records the presence hooks instead of processing them, so the test can
/// assert exactly what the coordinator forwards to a real engine.
class _RecordingEngine extends AlertEngine {
  _RecordingEngine()
      : super(
          scheduler: _FakeScheduler(),
          surface: _FakeSurface(),
          persistence: _FakePersistence(),
          presence: EnginePresence.active,
        );

  final List<(EnginePresence, DateTime)> presenceChanges = [];
  final List<DateTime> wakeOrUnlocks = [];

  @override
  void onPresenceChanged(EnginePresence presence, DateTime now) {
    presenceChanges.add((presence, now));
  }

  @override
  void onWakeOrUnlock(DateTime now) {
    wakeOrUnlocks.add(now);
  }
}

class _Harness {
  _Harness({bool alertEvenWhileLockedOrAway = false}) {
    engine = _RecordingEngine();
    presence = _ScriptedPresence();
    coordinator = DeferralCoordinator(
      presence: presence,
      engine: engine,
      now: () => nowValue,
      alertEvenWhileLockedOrAway: alertEvenWhileLockedOrAway,
    );
  }

  late final _RecordingEngine engine;
  late final _ScriptedPresence presence;
  late final DeferralCoordinator coordinator;

  /// Mutable injected clock: tests advance it to assert the hook arguments.
  DateTime nowValue = DateTime.utc(2026, 1, 1, 9, 0);
}

PresenceState _presence({
  bool locked = false,
  Duration idleFor = Duration.zero,
  bool active = true,
}) =>
    PresenceState(locked: locked, idleFor: idleFor, active: active);

void main() {
  group('DeferralCoordinator', () {
    test('locked screen reports EnginePresence.locked and no wake', () async {
      final h = _Harness();
      await h.coordinator.start();

      h.presence.emit(_presence(locked: true, active: false));

      expect(
        h.engine.presenceChanges,
        [(EnginePresence.locked, h.nowValue)],
      );
      expect(h.engine.wakeOrUnlocks, isEmpty);
    });

    test('idle beyond the threshold reports away', () async {
      final h = _Harness();
      await h.coordinator.start();

      h.presence.emit(
        _presence(idleFor: const Duration(minutes: 6), active: false),
      );

      expect(h.engine.presenceChanges.single.$1, EnginePresence.away);
      expect(h.engine.wakeOrUnlocks, isEmpty);
    });

    test('returning to activity reports active', () async {
      final h = _Harness();
      await h.coordinator.start();

      h.presence.emit(
        _presence(idleFor: const Duration(minutes: 6), active: false),
      );
      h.presence.emit(_presence(idleFor: const Duration(seconds: 10)));

      expect(
        h.engine.presenceChanges.map((c) => c.$1),
        [EnginePresence.away, EnginePresence.active],
      );
      // Idle return is not a wake: only the presence hook fires.
      expect(h.engine.wakeOrUnlocks, isEmpty);
    });

    test('unlock fires onWakeOrUnlock and reports active at the unlock '
        'instant', () async {
      final h = _Harness();
      await h.coordinator.start();

      h.presence.emit(_presence(locked: true, active: false));
      h.nowValue = DateTime.utc(2026, 1, 1, 9, 5);
      h.presence.emit(_presence());

      expect(
        h.engine.presenceChanges.map((c) => c.$1),
        [EnginePresence.locked, EnginePresence.active],
      );
      expect(h.engine.wakeOrUnlocks, [h.nowValue]);
      expect(h.engine.presenceChanges.last.$2, h.nowValue);
    });

    test('alertEvenWhileLockedOrAway override always reports active',
        () async {
      final h = _Harness(alertEvenWhileLockedOrAway: true);
      await h.coordinator.start();

      h.presence.emit(_presence(locked: true, active: false));
      h.presence.emit(
        _presence(
          locked: true,
          idleFor: const Duration(minutes: 6),
          active: false,
        ),
      );

      // Locked and away both collapse to active; no wake fires (no unlock).
      expect(h.engine.presenceChanges.single.$1, EnginePresence.active);
      expect(h.engine.wakeOrUnlocks, isEmpty);
    });

    test('changing quietWhenAwayThreshold takes effect on later states',
        () async {
      final h = _Harness();
      await h.coordinator.start();

      // 6 minutes idle crosses the default 5-minute threshold even though
      // the machine still reports the user active.
      h.presence.emit(_presence(idleFor: const Duration(minutes: 6)));
      expect(h.engine.presenceChanges.single.$1, EnginePresence.away);

      h.coordinator.quietWhenAwayThreshold = const Duration(minutes: 10);
      h.presence.emit(_presence(idleFor: const Duration(minutes: 6)));
      expect(h.engine.presenceChanges.last.$1, EnginePresence.active);
    });

    test('unsupported presence still reports active (never silently defers)',
        () async {
      final h = _Harness();
      await h.coordinator.start();

      h.presence.emit(
        const PresenceState.unsupported(reason: 'no mechanism responds'),
      );

      expect(h.engine.presenceChanges.single.$1, EnginePresence.active);
    });

    test('re-emitted identical states do not duplicate engine calls',
        () async {
      final h = _Harness();
      await h.coordinator.start();

      h.presence.emit(_presence());
      h.presence.emit(_presence());

      expect(h.engine.presenceChanges.length, 1);
    });
  });
}
