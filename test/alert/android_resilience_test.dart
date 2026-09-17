import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:attention_copilot/alert/android_resilience.dart';
import 'package:attention_copilot/domain/alert_engine.dart';
import 'package:attention_copilot/domain/alert_policy.dart';

/// One recorded scheduler call: the absolute instant and the alarm id, so the
/// boot-rescheduling tests can prove the re-planned instants come from the
/// persisted records and not from the OS alarm cache.
class _ScheduledCall {
  _ScheduledCall(this.instantUtc, this.alarmId);

  final DateTime instantUtc;
  final String alarmId;
}

/// Fake alarm scheduler: records every schedule/cancel against the port.
class _FakeScheduler implements AlertSchedulerPort {
  final List<_ScheduledCall> scheduled = [];
  final List<String> cancelled = [];

  @override
  void schedule(DateTime instantUtc, String alarmId) {
    scheduled.add(_ScheduledCall(instantUtc, alarmId));
  }

  @override
  void cancel(String alarmId) {
    cancelled.add(alarmId);
  }

  Set<String> get scheduledAlarmIds =>
      scheduled.map((call) => call.alarmId).toSet();
}

/// Fake alert surface: the resilience module never rings anything directly,
/// but `AlertEngine.restore` needs one.
class _FakeSurface implements AlertSurfacePort {
  final List<String> rung = [];

  @override
  void ring(AlertTrigger trigger, {required List<AcknowledgementAction> actions}) {
    rung.add(trigger.alarmId);
  }

  @override
  void escalate(String alarmId, EscalationStep step) {}

  @override
  void stop(String alarmId) {}
}

/// Fake persistence: holds the persisted pending set that survives restarts.
class _FakePersistence implements AlertPersistencePort {
  List<PendingTriggerRecord> stored = [];

  @override
  Future<void> savePending(List<PendingTriggerRecord> records) async {
    stored = List.of(records);
  }

  @override
  Future<List<PendingTriggerRecord>> loadPending() async => List.of(stored);
}

/// Fake capability probe: every check value is configurable, and every
/// remediation request is recorded. Requesting a capability updates the
/// corresponding check value, mirroring the real user-grant round trip.
class _FakeProbe implements AndroidCapabilityProbe {
  bool exactAlarms = true;
  bool? fullScreenIntent = true;
  bool? notifications = true;

  bool? exactAlarmsRequestResult;
  bool? fullScreenIntentRequestResult;
  bool? notificationsRequestResult;

  int exactAlarmsRequests = 0;
  int fullScreenIntentRequests = 0;
  int notificationsRequests = 0;

  @override
  Future<bool> canScheduleExactAlarms() async => exactAlarms;

  @override
  Future<bool?> canUseFullScreenIntent() async => fullScreenIntent;

  @override
  Future<bool?> areNotificationsEnabled() async => notifications;

  @override
  Future<bool?> requestExactAlarmsPermission() async {
    exactAlarmsRequests += 1;
    final granted = exactAlarmsRequestResult;
    if (granted != null) exactAlarms = granted;
    return granted;
  }

  @override
  Future<bool?> requestFullScreenIntentPermission() async {
    fullScreenIntentRequests += 1;
    final granted = fullScreenIntentRequestResult;
    if (granted != null) fullScreenIntent = granted;
    return granted;
  }

  @override
  Future<bool?> requestNotificationPermission() async {
    notificationsRequests += 1;
    final granted = notificationsRequestResult;
    if (granted != null) notifications = granted;
    return granted;
  }
}

/// Fake boot flag: the flag the `BootReceiver` sets, consumed on app start.
class _FakeBootFlag implements BootRescheduleFlag {
  bool value = false;
  int consumeCalls = 0;

  @override
  Future<bool> consume() async {
    consumeCalls += 1;
    final wasSet = value;
    value = false;
    return wasSet;
  }
}

PendingTriggerRecord _record({
  required String alarmId,
  required DateTime instantUtc,
  PendingTriggerState state = PendingTriggerState.pending,
  DateTime? endUtc,
}) {
  return PendingTriggerRecord(
    alarmId: alarmId,
    occurrenceId: 'occ-$alarmId',
    instantUtc: instantUtc,
    endUtc: endUtc ?? instantUtc.add(const Duration(minutes: 30)),
    lead: AlertLeadTime.tenMinutes,
    state: state,
  );
}

Future<AndroidResilience> _restore({
  required _FakePersistence persistence,
  _FakeProbe? probe,
  _FakeBootFlag? bootFlag,
  _FakeScheduler? scheduler,
}) async {
  return AndroidResilience.restore(
    scheduler: scheduler ?? _FakeScheduler(),
    surface: _FakeSurface(),
    persistence: persistence,
    presence: EnginePresence.active,
    probe: probe ?? _FakeProbe(),
    bootFlag: bootFlag ?? _FakeBootFlag(),
  );
}

void main() {
  final now = DateTime.utc(2026, 9, 18, 8, 0);

  group('reboot rescheduling', () {
    test(
        'after clearing in-memory state and simulating boot, every pending '
        'trigger within the next 24 h is rescheduled from the persisted '
        'absolute instants', () async {
      final within = <String, DateTime>{
        'occ1': now.add(const Duration(hours: 1)),
        'occ2': now.add(const Duration(hours: 5)),
        'occ3': now.add(const Duration(hours: 23)),
      };
      final persistence = _FakePersistence();
      persistence.stored = [
        for (final entry in within.entries)
          _record(alarmId: entry.key, instantUtc: entry.value),
        // Outside the 24 h horizon: must not be rescheduled by boot.
        _record(
          alarmId: 'occ4',
          instantUtc: now.add(const Duration(hours: 25)),
        ),
        // Deferred and ringing triggers are the engine's runtime concern,
        // not the scheduler's: excluded from the boot re-plan.
        _record(
          alarmId: 'occ5',
          instantUtc: now.add(const Duration(hours: 2)),
          state: PendingTriggerState.deferredLocked,
        ),
        _record(
          alarmId: 'occ6',
          instantUtc: now.add(const Duration(hours: 3)),
          state: PendingTriggerState.ringing,
        ),
        // Came due while the device was off: the engine fires or retires it
        // on the next tick, it must not be armed in the past.
        _record(
          alarmId: 'occ7',
          instantUtc: now.subtract(const Duration(minutes: 10)),
        ),
      ];
      final scheduler = _FakeScheduler();
      // A fresh instance over the same persistence is the simulated boot:
      // all in-memory state is gone, only the persisted records remain.
      final resilience =
          await _restore(persistence: persistence, scheduler: scheduler);

      // The engine restore re-arms the earliest pending trigger - here the
      // one that came due while the device was off, which the engine fires
      // or retires on its next tick. That is the engine's contract, not the
      // boot re-plan's.
      expect(scheduler.scheduledAlarmIds, {'occ7'});
      scheduler.scheduled.clear();

      final rescheduled = await resilience.rescheduleOnBoot(now);

      expect(rescheduled, 3);
      expect(
        scheduler.scheduledAlarmIds,
        {'occ1', 'occ2', 'occ3'},
        reason: 'only pending triggers within 24 h are re-planned',
      );
      // Each re-plan carries the persisted absolute instant, never a
      // recomputed one and never anything read back from the OS alarm cache.
      for (final entry in within.entries) {
        final call =
            scheduler.scheduled.where((c) => c.alarmId == entry.key).single;
        expect(call.instantUtc, entry.value);
      }
    });

    test('restore rebuilds the engine from the persisted pending set', () async {
      final persistence = _FakePersistence();
      persistence.stored = [
        _record(alarmId: 'a', instantUtc: now.add(const Duration(hours: 1))),
        _record(
          alarmId: 'b',
          instantUtc: now.add(const Duration(hours: 2)),
          state: PendingTriggerState.deferredAway,
        ),
        _record(
          alarmId: 'c',
          instantUtc: now.add(const Duration(hours: 3)),
          state: PendingTriggerState.ringing,
        ),
      ];

      final resilience = await _restore(persistence: persistence);

      expect(
        resilience.engine.pendingTriggers.map((t) => t.alarmId),
        unorderedEquals(['a', 'b', 'c']),
      );
    });

    test('a set boot flag triggers the reschedule path; a cleared flag does '
        'not reschedule anything on top of the engine re-arm', () async {
      final persistence = _FakePersistence();
      persistence.stored = [
        _record(alarmId: 'occ1', instantUtc: now.add(const Duration(hours: 1))),
        _record(alarmId: 'occ4', instantUtc: now.add(const Duration(hours: 25))),
      ];

      final setFlag = _FakeBootFlag()..value = true;
      final scheduler = _FakeScheduler();
      final resilience = await _restore(
        persistence: persistence,
        bootFlag: setFlag,
        scheduler: scheduler,
      );

      final rescheduled = await resilience.rescheduleAfterBootIfNeeded(now);

      expect(rescheduled, 1);
      expect(setFlag.consumeCalls, 1);
      expect(setFlag.value, isFalse, reason: 'the flag is consumed once');

      // No flag: nothing beyond what `AlertEngine.restore` already re-armed.
      scheduler.scheduled.clear();
      final cleared = await _restore(
        persistence: persistence,
        bootFlag: _FakeBootFlag(),
        scheduler: scheduler,
      );
      scheduler.scheduled.clear();
      final extra = await cleared.rescheduleAfterBootIfNeeded(now);
      expect(extra, 0);
      expect(scheduler.scheduled, isEmpty);
    });
  });

  group('capability checks - grant and deny for each', () {
    test('exact alarms: granted keeps the alarm-clock mode, denied produces '
        'the degraded: inexact-alarms state', () async {
      final grantedProbe = _FakeProbe()..exactAlarms = true;
      final granted = await _restore(
        persistence: _FakePersistence(),
        probe: grantedProbe,
      );
      final grantedReport = await granted.evaluateCapabilities();
      expect(grantedReport.degradation, AndroidResilienceDegradation.none);
      expect(grantedReport.scheduleMode, AndroidScheduleMode.alarmClock);
      final grantedStatus = grantedReport.capabilities
          .singleWhere((s) => s.capability == AndroidCapability.exactAlarms);
      expect(grantedStatus.granted, isTrue);

      final deniedProbe = _FakeProbe()..exactAlarms = false;
      final denied = await _restore(
        persistence: _FakePersistence(),
        probe: deniedProbe,
      );
      final deniedReport = await denied.evaluateCapabilities();

      expect(
        deniedReport.degradation,
        AndroidResilienceDegradation.inexactAlarms,
      );
      expect(
        deniedReport.degradation.diagnosticLabel,
        'degraded: inexact-alarms',
      );
      expect(denied.degradationReason, contains('late'));
      expect(
        deniedReport.scheduleMode,
        AndroidScheduleMode.exactAllowWhileIdle,
        reason: 'the ladder falls back to setAndAllowWhileIdle',
      );
      final deniedStatus = deniedReport.capabilities
          .singleWhere((s) => s.capability == AndroidCapability.exactAlarms);
      expect(deniedStatus.granted, isFalse);
      expect(
        deniedStatus.deepLinkAction,
        AndroidDeepLinks.exactAlarms,
        reason: 'denial always carries the settings deep link',
      );
    });

    test(
        'full-screen intent: granted keeps the full-screen alarm, denied '
        'falls back to a high-importance alarm notification', () async {
      final grantedProbe = _FakeProbe()..fullScreenIntent = true;
      final granted = await _restore(
        persistence: _FakePersistence(),
        probe: grantedProbe,
      );
      final grantedReport = await granted.evaluateCapabilities();
      expect(grantedReport.degradation, AndroidResilienceDegradation.none);
      expect(
        grantedReport.notificationFallback,
        AndroidNotificationFallback.fullScreen,
      );

      final deniedProbe = _FakeProbe()..fullScreenIntent = false;
      final denied = await _restore(
        persistence: _FakePersistence(),
        probe: deniedProbe,
      );
      final deniedReport = await denied.evaluateCapabilities();

      expect(
        deniedReport.degradation,
        AndroidResilienceDegradation.fullScreenIntentUnavailable,
      );
      expect(
        deniedReport.degradation.diagnosticLabel,
        'degraded: full-screen-intent-unavailable',
      );
      expect(denied.degradationReason, contains('full-screen'));
      expect(
        deniedReport.notificationFallback,
        AndroidNotificationFallback.highImportance,
        reason: 'the alarm still rings as a high-importance notification',
      );
      final deniedStatus = deniedReport.capabilities.singleWhere(
          (s) => s.capability == AndroidCapability.fullScreenIntent);
      expect(deniedStatus.granted, isFalse);
      expect(deniedStatus.deepLinkAction, AndroidDeepLinks.fullScreenIntent);
    });

    test('full-screen intent: unknown is reported, never silently treated as '
        'granted or denied', () async {
      final probe = _FakeProbe()..fullScreenIntent = null;
      final resilience = await _restore(
        persistence: _FakePersistence(),
        probe: probe,
      );

      final report = await resilience.evaluateCapabilities();

      final status = report.capabilities
          .singleWhere((s) => s.capability == AndroidCapability.fullScreenIntent);
      expect(status.granted, isNull);
      // Unknown is not a degradation: the notification still attempts the
      // full-screen intent and Android itself falls back to the
      // high-importance notification when it is not permitted.
      expect(report.degradation, AndroidResilienceDegradation.none);
    });

    test('POST_NOTIFICATIONS: granted keeps the alert path intact, denied '
        'produces the notifications-denied state', () async {
      final grantedProbe = _FakeProbe()..notifications = true;
      final granted = await _restore(
        persistence: _FakePersistence(),
        probe: grantedProbe,
      );
      final grantedReport = await granted.evaluateCapabilities();
      expect(grantedReport.degradation, AndroidResilienceDegradation.none);

      final deniedProbe = _FakeProbe()..notifications = false;
      final denied = await _restore(
        persistence: _FakePersistence(),
        probe: deniedProbe,
      );
      final deniedReport = await denied.evaluateCapabilities();

      expect(
        deniedReport.degradation,
        AndroidResilienceDegradation.notificationsDenied,
      );
      expect(
        deniedReport.degradation.diagnosticLabel,
        'degraded: notifications-denied',
      );
      expect(denied.degradationReason, contains('notification'));
      expect(deniedReport.scheduleMode, isNull,
          reason: 'with notifications denied nothing can be posted');
      expect(
        deniedReport.notificationFallback,
        AndroidNotificationFallback.none,
      );
      final deniedStatus = deniedReport.capabilities
          .singleWhere((s) => s.capability == AndroidCapability.notifications);
      expect(deniedStatus.granted, isFalse);
      expect(deniedStatus.deepLinkAction, AndroidDeepLinks.notifications);
    });
  });

  group('fallback ladder', () {
    test(
        'no exact alarms: scheduling still happens and the degraded: '
        'inexact-alarms state is visible, never silent', () async {
      final persistence = _FakePersistence();
      persistence.stored = [
        _record(alarmId: 'occ1', instantUtc: now.add(const Duration(hours: 1))),
      ];
      final scheduler = _FakeScheduler();
      final probe = _FakeProbe()..exactAlarms = false;
      final resilience = await _restore(
        persistence: persistence,
        probe: probe,
        scheduler: scheduler,
      );

      final rescheduled = await resilience.rescheduleOnBoot(now);
      final report = await resilience.evaluateCapabilities();

      expect(rescheduled, 1, reason: 'the fallback still arms the trigger');
      expect(scheduler.scheduledAlarmIds, {'occ1'});
      expect(
        report.degradation,
        AndroidResilienceDegradation.inexactAlarms,
      );
      expect(report.degradation.diagnosticLabel, 'degraded: inexact-alarms');
      expect(report.degradationReason, isNotEmpty);
      expect(resilience.degradation, AndroidResilienceDegradation.inexactAlarms);
    });

    test(
        'notifications denied dominates the ladder and the reason names every '
        'degraded capability', () async {
      final probe = _FakeProbe()
        ..notifications = false
        ..fullScreenIntent = false
        ..exactAlarms = false;
      final resilience = await _restore(
        persistence: _FakePersistence(),
        probe: probe,
      );

      final report = await resilience.evaluateCapabilities();

      expect(report.degradation, AndroidResilienceDegradation.notificationsDenied);
      expect(report.degradationReason, contains('notification'));
      expect(report.degradationReason, contains('full-screen'));
      expect(report.degradationReason, contains('late'));
      expect(
        report.capabilities
            .where((s) => s.granted == false)
            .map((s) => s.capability),
        unorderedEquals([
          AndroidCapability.exactAlarms,
          AndroidCapability.fullScreenIntent,
          AndroidCapability.notifications,
        ]),
      );
    });
  });

  group('remediation deep links', () {
    test('each remediation action opens the matching deep link and '
        're-evaluates the capabilities', () async {
      final probe = _FakeProbe()
        ..exactAlarms = false
        ..exactAlarmsRequestResult = true;
      final resilience = await _restore(
        persistence: _FakePersistence(),
        probe: probe,
      );

      final afterExact =
          await resilience.applyRemediation(AndroidCapability.exactAlarms);

      expect(probe.exactAlarmsRequests, 1);
      expect(afterExact.degradation, AndroidResilienceDegradation.none);

      final probe2 = _FakeProbe()
        ..fullScreenIntent = false
        ..fullScreenIntentRequestResult = true;
      final resilience2 = await _restore(
        persistence: _FakePersistence(),
        probe: probe2,
      );
      final afterFsi = await resilience2
          .applyRemediation(AndroidCapability.fullScreenIntent);
      expect(probe2.fullScreenIntentRequests, 1);
      expect(afterFsi.degradation, AndroidResilienceDegradation.none);

      final probe3 = _FakeProbe()
        ..notifications = false
        ..notificationsRequestResult = true;
      final resilience3 = await _restore(
        persistence: _FakePersistence(),
        probe: probe3,
      );
      final afterNotifications = await resilience3
          .applyRemediation(AndroidCapability.notifications);
      expect(probe3.notificationsRequests, 1);
      expect(afterNotifications.degradation, AndroidResilienceDegradation.none);
    });

    test('a denied remediation keeps the degraded state visible', () async {
      final probe = _FakeProbe()
        ..exactAlarms = false
        ..exactAlarmsRequestResult = false;
      final resilience = await _restore(
        persistence: _FakePersistence(),
        probe: probe,
      );

      final report =
          await resilience.applyRemediation(AndroidCapability.exactAlarms);

      expect(report.degradation, AndroidResilienceDegradation.inexactAlarms);
      expect(report.degradation.diagnosticLabel, 'degraded: inexact-alarms');
    });
  });
}
