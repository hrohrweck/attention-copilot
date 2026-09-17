import 'package:flutter_test/flutter_test.dart';

import 'package:attention_copilot/domain/alert_engine.dart';
import 'package:attention_copilot/domain/alert_policy.dart';

/// Minimal occurrence test double; the real `EventOccurrence` implements the
/// same [AlertOccurrence] interface later.
class _Occ implements AlertOccurrence {
  _Occ({
    required this.id,
    required this.startUtc,
    required this.endUtc,
    this.hasJoinAction = false,
  });

  @override
  final String id;

  @override
  final DateTime startUtc;

  @override
  final DateTime endUtc;

  @override
  List<AlertLeadTime>? get leadTimesOverride => null;

  @override
  final bool hasJoinAction;
}

/// Records every scheduler call; the platform scheduler is a cache, so tests
/// assert arming/cancelling rather than any real timing.
class _FakeScheduler implements AlertSchedulerPort {
  final List<MapEntry<DateTime, String>> scheduled = [];
  final List<String> cancelled = [];

  @override
  void schedule(DateTime instantUtc, String alarmId) {
    scheduled.add(MapEntry(instantUtc, alarmId));
  }

  @override
  void cancel(String alarmId) {
    cancelled.add(alarmId);
  }
}

class _FakeSurface implements AlertSurfacePort {
  final List<AlertTrigger> rung = [];
  final List<List<AcknowledgementAction>> actionsForRing = [];
  final List<(String, EscalationStep)> escalated = [];
  final List<String> stopped = [];

  @override
  void ring(AlertTrigger trigger, {required List<AcknowledgementAction> actions}) {
    rung.add(trigger);
    actionsForRing.add(List.of(actions));
  }

  @override
  void escalate(String alarmId, EscalationStep step) {
    escalated.add((alarmId, step));
  }

  @override
  void stop(String alarmId) {
    stopped.add(alarmId);
  }
}

/// Stores synchronously so tests can assert the persisted set right after an
/// engine call (the engine never awaits the port).
class _FakePersistence implements AlertPersistencePort {
  List<PendingTriggerRecord> stored = [];
  int saves = 0;

  @override
  Future<void> savePending(List<PendingTriggerRecord> records) async {
    stored = List.of(records);
    saves++;
  }

  @override
  Future<List<PendingTriggerRecord>> loadPending() async => List.of(stored);
}

/// A policy with a single 10-minute lead time for deterministic instants.
AlertPolicy _singleLeadPolicy() => AlertPolicy(
      leadTimes: const [AlertLeadTime.tenMinutes],
      escalation: AlertPolicy.defaultEscalation,
      snooze: SnoozeConfig.disabled,
    );

({AlertEngine engine, _FakeScheduler scheduler, _FakeSurface surface,
    _FakePersistence persistence}) _makeEngine(
  DateTime now, {
  EnginePresence presence = EnginePresence.active,
}) {
  final scheduler = _FakeScheduler();
  final surface = _FakeSurface();
  final persistence = _FakePersistence();
  final engine = AlertEngine(
    scheduler: scheduler,
    surface: surface,
    persistence: persistence,
    presence: presence,
  );
  return (
    engine: engine,
    scheduler: scheduler,
    surface: surface,
    persistence: persistence,
  );
}

void main() {
  final t0 = DateTime.utc(2026, 9, 17, 9, 0);

  group('plan + onTick', () {
    test('fires each trigger exactly once, in instant order', () {
      final e = _makeEngine(t0);
      final occurrence = _Occ(
        id: 'evt-1',
        startUtc: t0.add(const Duration(minutes: 15)),
        endUtc: t0.add(const Duration(minutes: 45)),
      );

      e.engine.plan([occurrence], AlertPolicy.defaults(), t0);
      e.engine.onTick(t0);
      expect(e.surface.rung, isEmpty);

      // 10-minute lead fires first.
      final first = t0.add(const Duration(minutes: 5));
      e.engine.onTick(first);
      expect(e.surface.rung, hasLength(1));
      expect(e.surface.rung.single.alarmId, 'evt-1#lead600');

      // Ticking again right after does not double-fire.
      e.engine.onTick(first.add(const Duration(seconds: 1)));
      expect(e.surface.rung, hasLength(1));

      // 1-minute lead fires next.
      final second = t0.add(const Duration(minutes: 14));
      e.engine.onTick(second);
      expect(e.surface.rung, hasLength(2));
      expect(e.surface.rung.last.alarmId, 'evt-1#lead60');

      e.engine.onTick(second.add(const Duration(seconds: 1)));
      expect(e.surface.rung, hasLength(2));

      final fired =
          e.engine.records.where((r) => r.reason == AlertRecordReason.fired);
      expect(fired, hasLength(2));
    });

    test('a forward clock jump past a trigger is caught by the heartbeat and '
        'fires once', () {
      final e = _makeEngine(t0);
      final occurrence = _Occ(
        id: 'evt-1',
        startUtc: t0.add(const Duration(minutes: 20)),
        endUtc: t0.add(const Duration(minutes: 40)),
      );

      e.engine.plan([occurrence], _singleLeadPolicy(), t0);

      // Trigger is at t0+10min; the app missed every tick until t0+30min.
      e.engine.onTick(t0.add(const Duration(minutes: 30)));
      expect(e.surface.rung, hasLength(1));
      expect(e.surface.rung.single.alarmId, 'evt-1#lead600');

      e.engine.onTick(t0.add(const Duration(minutes: 31)));
      expect(e.surface.rung, hasLength(1));
    });
  });

  group('presence gating', () {
    test('a trigger due while locked is deferred, not rung, and fires '
        'immediately on unlock', () {
      final e = _makeEngine(t0, presence: EnginePresence.locked);
      final occurrence = _Occ(
        id: 'evt-1',
        startUtc: t0.add(const Duration(minutes: 11)),
        endUtc: t0.add(const Duration(minutes: 30)),
      );
      e.engine.plan([occurrence], _singleLeadPolicy(), t0);

      final due = t0.add(const Duration(minutes: 1));
      e.engine.onTick(due);

      expect(e.surface.rung, isEmpty);
      expect(e.surface.escalated, isEmpty);
      expect(e.engine.deferredAlerts, hasLength(1));
      expect(e.engine.deferredAlerts.single.alarmId, 'evt-1#lead600');
      expect(
        e.engine.records
            .any((r) => r.reason == AlertRecordReason.deferredLocked),
        isTrue,
      );

      // Meeting has not ended yet: unlock fires immediately.
      e.engine.onPresenceChanged(
        EnginePresence.active,
        due.add(const Duration(minutes: 1)),
      );
      expect(e.surface.rung, hasLength(1));
      expect(e.engine.deferredAlerts, isEmpty);
      expect(
        e.engine.records.where((r) => r.reason == AlertRecordReason.fired),
        hasLength(1),
      );
    });

    test('a trigger due while away is deferred with no surface call, and '
        'fires when presence returns', () {
      final e = _makeEngine(t0, presence: EnginePresence.away);
      final occurrence = _Occ(
        id: 'evt-1',
        startUtc: t0.add(const Duration(minutes: 11)),
        endUtc: t0.add(const Duration(minutes: 30)),
      );
      e.engine.plan([occurrence], _singleLeadPolicy(), t0);

      final due = t0.add(const Duration(minutes: 1));
      e.engine.onTick(due);

      expect(e.surface.rung, isEmpty);
      expect(
        e.engine.records
            .any((r) => r.reason == AlertRecordReason.deferredAway),
        isTrue,
      );

      e.engine.onPresenceChanged(
        EnginePresence.active,
        due.add(const Duration(minutes: 1)),
      );
      expect(e.surface.rung, hasLength(1));
    });

    test('unlock after the meeting ended beyond the grace retires it without '
        'ringing', () {
      final e = _makeEngine(t0, presence: EnginePresence.locked);
      final occurrence = _Occ(
        id: 'evt-1',
        startUtc: t0.add(const Duration(minutes: 11)),
        endUtc: t0.add(const Duration(minutes: 15)),
      );
      e.engine.plan([occurrence], _singleLeadPolicy(), t0);

      final due = t0.add(const Duration(minutes: 1));
      e.engine.onTick(due); // deferred while locked
      expect(e.surface.rung, isEmpty);

      final unlock = occurrence.endUtc.add(const Duration(minutes: 10));
      e.engine.onPresenceChanged(EnginePresence.active, unlock);

      expect(e.surface.rung, isEmpty);
      expect(e.engine.pendingTriggers, isEmpty);
      expect(
        e.engine.records
            .any((r) => r.reason == AlertRecordReason.meetingEnded),
        isTrue,
      );
    });

    test('unlock shortly after the meeting ended (within grace) still fires',
        () {
      final e = _makeEngine(t0, presence: EnginePresence.locked);
      final occurrence = _Occ(
        id: 'evt-1',
        startUtc: t0.add(const Duration(minutes: 11)),
        endUtc: t0.add(const Duration(minutes: 15)),
      );
      e.engine.plan([occurrence], _singleLeadPolicy(), t0);

      final due = t0.add(const Duration(minutes: 1));
      e.engine.onTick(due);

      final unlock = occurrence.endUtc.add(const Duration(minutes: 1));
      e.engine.onPresenceChanged(EnginePresence.active, unlock);
      expect(e.surface.rung, hasLength(1));
    });

    test('onWakeOrUnlock fires deferred triggers in deterministic order', () {
      final e = _makeEngine(t0, presence: EnginePresence.locked);
      final occurrence = _Occ(
        id: 'evt-1',
        startUtc: t0.add(const Duration(minutes: 15)),
        endUtc: t0.add(const Duration(minutes: 45)),
      );
      e.engine.plan([occurrence], AlertPolicy.defaults(), t0);

      // Both leads came due while locked.
      e.engine.onTick(t0.add(const Duration(minutes: 14)));
      expect(e.surface.rung, isEmpty);
      expect(e.engine.deferredAlerts, hasLength(2));

      e.engine.onWakeOrUnlock(t0.add(const Duration(minutes: 15)));
      expect(e.surface.rung, hasLength(2));
      expect(e.surface.rung[0].alarmId, 'evt-1#lead600');
      expect(e.surface.rung[1].alarmId, 'evt-1#lead60');
    });
  });

  group('idempotency', () {
    test('re-planning the same agenda never duplicates a trigger', () {
      final e = _makeEngine(t0);
      final occurrence = _Occ(
        id: 'evt-1',
        startUtc: t0.add(const Duration(minutes: 20)),
        endUtc: t0.add(const Duration(minutes: 40)),
      );

      e.engine.plan([occurrence], _singleLeadPolicy(), t0);
      e.engine.plan(
        [occurrence],
        _singleLeadPolicy(),
        t0.add(const Duration(seconds: 30)),
      );

      expect(e.engine.pendingTriggers, hasLength(1));
      // Nothing changed on the second plan: no extra persistence round-trip.
      expect(e.persistence.saves, 1);

      e.engine.onTick(t0.add(const Duration(minutes: 10)));
      expect(e.surface.rung, hasLength(1));
    });

    test('a trigger removed from the agenda is retired with '
        'occurrenceRemoved', () {
      final e = _makeEngine(t0);
      final early = _Occ(
        id: 'a',
        startUtc: t0.add(const Duration(minutes: 15)),
        endUtc: t0.add(const Duration(minutes: 45)),
      );
      final late = _Occ(
        id: 'b',
        startUtc: t0.add(const Duration(minutes: 30)),
        endUtc: t0.add(const Duration(minutes: 60)),
      );
      e.engine.plan([early, late], _singleLeadPolicy(), t0);
      expect(e.engine.pendingTriggers, hasLength(2));
      expect(e.scheduler.scheduled.last.value, 'a#lead600');

      e.engine.plan([late], _singleLeadPolicy(), t0);

      expect(e.engine.pendingTriggers, hasLength(1));
      expect(e.engine.pendingTriggers.single.alarmId, 'b#lead600');
      expect(
        e.engine.records
            .any((r) => r.reason == AlertRecordReason.occurrenceRemoved),
        isTrue,
      );
      expect(e.scheduler.cancelled, contains('a#lead600'));
    });
  });

  group('persistence across restarts', () {
    test('the pending set survives a restart with no duplicates and no loss',
        () async {
      final persistence = _FakePersistence();
      final first = AlertEngine(
        scheduler: _FakeScheduler(),
        surface: _FakeSurface(),
        persistence: persistence,
        presence: EnginePresence.active,
      );
      final occurrence = _Occ(
        id: 'evt-1',
        startUtc: t0.add(const Duration(minutes: 15)),
        endUtc: t0.add(const Duration(minutes: 45)),
      );
      first.plan([occurrence], AlertPolicy.defaults(), t0);
      expect(persistence.stored, hasLength(2));

      // Crash/quit: restore into a brand-new engine from the same port.
      final scheduler = _FakeScheduler();
      final surface = _FakeSurface();
      final restored = await AlertEngine.restore(
        scheduler: scheduler,
        surface: surface,
        persistence: persistence,
        presence: EnginePresence.active,
      );
      expect(restored.pendingTriggers, hasLength(2));

      // Re-plan the same agenda: still two, no duplicates.
      restored.plan(
        [occurrence],
        AlertPolicy.defaults(),
        t0.add(const Duration(minutes: 1)),
      );
      expect(restored.pendingTriggers, hasLength(2));

      restored.onTick(t0.add(const Duration(minutes: 5)));
      restored.onTick(t0.add(const Duration(minutes: 14)));
      expect(surface.rung, hasLength(2));

      restored.onTick(t0.add(const Duration(minutes: 15)));
      expect(surface.rung, hasLength(2));
    });
  });

  group('acknowledgement and heartbeat', () {
    test('acknowledge stops the ringing alert and removes it from the '
        'pending set', () {
      final e = _makeEngine(t0);
      final occurrence = _Occ(
        id: 'evt-1',
        startUtc: t0.add(const Duration(minutes: 20)),
        endUtc: t0.add(const Duration(minutes: 40)),
        hasJoinAction: true,
      );
      e.engine.plan([occurrence], _singleLeadPolicy(), t0);
      e.engine.onTick(t0.add(const Duration(minutes: 10)));

      expect(e.surface.rung, hasLength(1));
      expect(e.surface.actionsForRing.single,
          contains(AcknowledgementAction.dismiss));
      expect(e.surface.actionsForRing.single,
          contains(AcknowledgementAction.join));
      expect(e.engine.recommendedHeartbeat, const Duration(seconds: 1));

      e.engine.acknowledge('evt-1#lead600');

      expect(e.surface.stopped, contains('evt-1#lead600'));
      expect(e.engine.pendingTriggers, isEmpty);
      expect(
        e.engine.records
            .any((r) => r.reason == AlertRecordReason.acknowledged),
        isTrue,
      );
      expect(e.engine.recommendedHeartbeat, isNull);
    });

    test('recommendedHeartbeat is null when idle, 30s while pending, 1s '
        'while ringing', () {
      final e = _makeEngine(t0);
      expect(e.engine.recommendedHeartbeat, isNull);

      final occurrence = _Occ(
        id: 'evt-1',
        startUtc: t0.add(const Duration(minutes: 20)),
        endUtc: t0.add(const Duration(minutes: 40)),
      );
      e.engine.plan([occurrence], _singleLeadPolicy(), t0);
      expect(e.engine.recommendedHeartbeat, const Duration(seconds: 30));

      e.engine.onTick(t0.add(const Duration(minutes: 10)));
      expect(e.engine.recommendedHeartbeat, const Duration(seconds: 1));
    });
  });

  group('platform scheduler cache', () {
    test('arms the earliest pending trigger and re-arms on fire', () {
      final e = _makeEngine(t0);
      final occurrence = _Occ(
        id: 'evt-1',
        startUtc: t0.add(const Duration(minutes: 15)),
        endUtc: t0.add(const Duration(minutes: 45)),
      );
      e.engine.plan([occurrence], AlertPolicy.defaults(), t0);

      expect(e.scheduler.scheduled, hasLength(1));
      expect(e.scheduler.scheduled.single.key,
          t0.add(const Duration(minutes: 5)));
      expect(e.scheduler.scheduled.single.value, 'evt-1#lead600');

      e.engine.onTick(t0.add(const Duration(minutes: 5)));
      expect(e.scheduler.cancelled, contains('evt-1#lead600'));
      expect(e.scheduler.scheduled.last.key,
          t0.add(const Duration(minutes: 14)));
      expect(e.scheduler.scheduled.last.value, 'evt-1#lead60');
    });
  });

  group('escalation', () {
    test('escalation steps are driven while an alert rings unacknowledged',
        () {
      final e = _makeEngine(t0);
      final occurrence = _Occ(
        id: 'evt-1',
        startUtc: t0.add(const Duration(minutes: 20)),
        endUtc: t0.add(const Duration(minutes: 40)),
      );
      e.engine.plan([occurrence], _singleLeadPolicy(), t0);

      final due = t0.add(const Duration(minutes: 10));
      e.engine.onTick(due);
      expect(
        e.surface.escalated.any(
            (x) => x.$2.action == EscalationAction.repeatAudioCycle),
        isTrue,
      );

      e.engine.onTick(due.add(const Duration(seconds: 30)));
      expect(
        e.surface.escalated
            .any((x) => x.$2.action == EscalationAction.raiseVolume),
        isTrue,
      );
    });
  });

  group('PendingTriggerRecord JSON', () {
    test('round-trips through toJson/fromJson', () {
      final record = PendingTriggerRecord(
        alarmId: 'evt-1#lead600',
        occurrenceId: 'evt-1',
        instantUtc: DateTime.utc(2026, 9, 17, 9, 5),
        endUtc: DateTime.utc(2026, 9, 17, 9, 30),
        lead: AlertLeadTime.tenMinutes,
        state: PendingTriggerState.deferredLocked,
      );

      final restored = PendingTriggerRecord.fromJson(record.toJson());

      expect(restored.alarmId, record.alarmId);
      expect(restored.occurrenceId, record.occurrenceId);
      expect(restored.instantUtc, record.instantUtc);
      expect(restored.endUtc, record.endUtc);
      expect(restored.state, record.state);
      expect(restored.lead.before, record.lead.before);
      expect(restored.lead.profile.audioId, record.lead.profile.audioId);
      expect(restored.lead.profile.volume, record.lead.profile.volume);
      expect(restored.lead.profile.accent, record.lead.profile.accent);
      expect(restored.lead.profile.fullscreen, record.lead.profile.fullscreen);
      expect(restored.lead.profile.loopAudio, record.lead.profile.loopAudio);
    });
  });
}
