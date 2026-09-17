import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:attention_copilot/alert/android_alert_scheduler.dart';

/// One recorded schedule call, captured with every field the scheduler chose,
/// so the tests can assert the exact alarm semantics without a device.
class _ScheduledRecord {
  _ScheduledRecord({
    required this.id,
    required this.instantUtc,
    required this.timezoneName,
    required this.title,
    required this.body,
    required this.payload,
    required this.scheduleMode,
    required this.android,
  });

  final int id;
  final DateTime instantUtc;
  final String timezoneName;
  final String title;
  final String body;
  final String payload;
  final AndroidScheduleMode scheduleMode;
  final AndroidNotificationDetails android;
}

/// Fake notification plugin gateway. Every value the scheduler reads from the
/// platform is configurable, and every call it makes is recorded.
class _FakeNotificationGateway implements AndroidNotificationGateway {
  final List<_ScheduledRecord> scheduled = [];
  final List<int> cancelled = [];
  final List<AndroidNotificationChannel> createdChannels = [];
  int initializeCalls = 0;
  int cancelAllCalls = 0;

  bool canScheduleExact = true;
  bool? exactPermissionResult;
  bool? notificationsPermissionResult;
  bool? policyAccessResult;

  @override
  Future<void> initialize(String defaultIcon) async {
    initializeCalls += 1;
  }

  @override
  Future<void> createChannel(AndroidNotificationChannel channel) async {
    createdChannels.add(channel);
  }

  @override
  Future<bool?> requestNotificationPermission() async =>
      notificationsPermissionResult;

  @override
  Future<bool> canScheduleExactNotifications() async => canScheduleExact;

  @override
  Future<bool?> requestExactAlarmsPermission() async => exactPermissionResult;

  @override
  Future<bool?> requestNotificationPolicyAccess() async =>
      policyAccessResult;

  @override
  Future<void> schedule({
    required int id,
    required DateTime instantUtc,
    required String timezoneName,
    required String title,
    required String body,
    required String payload,
    required AndroidScheduleMode scheduleMode,
    required AndroidNotificationDetails android,
  }) async {
    scheduled.add(_ScheduledRecord(
      id: id,
      instantUtc: instantUtc,
      timezoneName: timezoneName,
      title: title,
      body: body,
      payload: payload,
      scheduleMode: scheduleMode,
      android: android,
    ));
  }

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
  }

  @override
  Future<void> cancelAll() async {
    cancelAllCalls += 1;
  }
}

/// Fake foreground-service gateway: records start/stop so the tests can prove
/// acknowledgement tears the ringing service down.
class _FakeRingingServiceGateway implements RingingServiceGateway {
  final List<String> startedAlarmIds = [];
  int initCalls = 0;
  int stopCalls = 0;
  bool running = false;

  @override
  Future<void> init() async {
    initCalls += 1;
  }

  @override
  Future<bool> get isRunning async => running;

  @override
  Future<void> start({
    required String alarmId,
    required String title,
    required String body,
  }) async {
    startedAlarmIds.add(alarmId);
    running = true;
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
    running = false;
  }
}

AndroidAlertScheduler _scheduler(
  _FakeNotificationGateway notifications,
  _FakeRingingServiceGateway service,
) {
  return AndroidAlertScheduler(
    notifications: notifications,
    service: service,
    // Tests pin the timezone so the asserted instant is deterministic.
    timezoneName: () async => 'Europe/Berlin',
  );
}

void main() {
  group('exact alarm scheduling', () {
    test(
        'schedule arms an alarmClock notification with full-screen intent, '
        'alarm category, ongoing, no auto-cancel and alarm audio usage', () async {
      final notifications = _FakeNotificationGateway();
      final service = _FakeRingingServiceGateway();
      final scheduler = _scheduler(notifications, service);

      final instant = DateTime.utc(2026, 9, 18, 7, 50);
      scheduler.schedule(instant, 'occ42#lead600');
      await scheduler.whenIdle;

      expect(notifications.scheduled, hasLength(1));
      final record = notifications.scheduled.single;
      expect(record.scheduleMode, AndroidScheduleMode.alarmClock);
      expect(record.instantUtc, instant);
      expect(record.timezoneName, 'Europe/Berlin');
      expect(record.payload, 'occ42#lead600');
      expect(record.id, AndroidAlertScheduler.notificationIdFor('occ42#lead600'));

      final android = record.android;
      expect(android.fullScreenIntent, isTrue);
      expect(android.category, AndroidNotificationCategory.alarm);
      expect(android.ongoing, isTrue);
      expect(android.autoCancel, isFalse);
      expect(android.importance, Importance.high);
      expect(android.audioAttributesUsage, AudioAttributesUsage.alarm);
      expect(android.channelId, AndroidAlertScheduler.alarmChannelId);
      expect(android.playSound, isTrue);
      expect(android.enableVibration, isTrue);
    });

    test('notification ids are stable and distinct per alarm id', () {
      final a = AndroidAlertScheduler.notificationIdFor('occ1#lead60');
      final b = AndroidAlertScheduler.notificationIdFor('occ2#lead60');
      final aAgain = AndroidAlertScheduler.notificationIdFor('occ1#lead60');

      expect(a, aAgain); // deterministic across restarts (stable hash)
      expect(a, isNot(b));
      expect(a, greaterThan(0)); // valid Android notification id
    });

    test('cancel removes the armed notification by the same id', () async {
      final notifications = _FakeNotificationGateway();
      final scheduler = _scheduler(notifications, _FakeRingingServiceGateway());

      scheduler.schedule(DateTime.utc(2026, 9, 18, 7, 50), 'occ42#lead60');
      await scheduler.whenIdle;
      scheduler.cancel('occ42#lead60');
      await scheduler.whenIdle;

      expect(
        notifications.cancelled,
        [AndroidAlertScheduler.notificationIdFor('occ42#lead60')],
      );
    });

    test('initialize creates the alarm channel with high importance and '
        'alarm audio usage once', () async {
      final notifications = _FakeNotificationGateway();
      final scheduler = _scheduler(notifications, _FakeRingingServiceGateway());

      await scheduler.initialize();
      await scheduler.initialize();

      expect(notifications.initializeCalls, 1);
      expect(notifications.createdChannels, hasLength(1));
      final channel = notifications.createdChannels.single;
      expect(channel.id, AndroidAlertScheduler.alarmChannelId);
      expect(channel.importance, Importance.high);
      expect(channel.audioAttributesUsage, AudioAttributesUsage.alarm);
      expect(channel.bypassDnd, isFalse); // never relied upon by default
    });
  });

  group('acknowledgement', () {
    test('acknowledge cancels the notification and stops the ringing service',
        () async {
      final notifications = _FakeNotificationGateway();
      final service = _FakeRingingServiceGateway();
      final scheduler = _scheduler(notifications, service);

      await scheduler.startRinging(
        alarmId: 'occ42#lead60',
        title: 'Meeting alert',
        body: 'Q3 planning starts in 10 minutes',
      );
      expect(service.startedAlarmIds, ['occ42#lead60']);
      expect(service.running, isTrue);

      await scheduler.acknowledge('occ42#lead60');

      expect(
        notifications.cancelled,
        contains(AndroidAlertScheduler.notificationIdFor('occ42#lead60')),
      );
      expect(service.stopCalls, 1);
      expect(service.running, isFalse);
    });

    test('the service never starts while no alert is ringing', () async {
      final service = _FakeRingingServiceGateway();
      final scheduler = _scheduler(_FakeNotificationGateway(), service);

      await scheduler.whenIdle;

      expect(service.startedAlarmIds, isEmpty);
      expect(service.running, isFalse);
    });
  });

  group('permission-denied fallback', () {
    test(
        'denied exact-alarm permission degrades to exactAllowWhileIdle with a '
        'clear degraded state instead of failing', () async {
      final notifications = _FakeNotificationGateway()
        ..canScheduleExact = false
        ..exactPermissionResult = null; // user denied
      final scheduler = _scheduler(notifications, _FakeRingingServiceGateway());

      scheduler.schedule(DateTime.utc(2026, 9, 18, 7, 50), 'occ42#lead600');
      await scheduler.whenIdle;

      expect(notifications.scheduled, hasLength(1));
      expect(
        notifications.scheduled.single.scheduleMode,
        AndroidScheduleMode.exactAllowWhileIdle,
      );
      expect(
        scheduler.degradation,
        AndroidAlertDegradation.inexactAlarms,
      );
      expect(scheduler.degradationReason, isNotEmpty);
      expect(scheduler.degradationReason.toLowerCase(), contains('exact'));
    });

    test('granting exact-alarm permission on request keeps alarmClock and '
        'clears the degradation', () async {
      final notifications = _FakeNotificationGateway()
        ..canScheduleExact = false
        ..exactPermissionResult = true; // user granted when asked
      final scheduler = _scheduler(notifications, _FakeRingingServiceGateway());

      scheduler.schedule(DateTime.utc(2026, 9, 18, 7, 50), 'occ42#lead600');
      await scheduler.whenIdle;

      expect(
        notifications.scheduled.single.scheduleMode,
        AndroidScheduleMode.alarmClock,
      );
      expect(scheduler.degradation, AndroidAlertDegradation.none);
    });

    test('denied notification permission yields the notifications-denied '
        'degraded state on requestPermissions', () async {
      final notifications = _FakeNotificationGateway()
        ..notificationsPermissionResult = false;
      final scheduler = _scheduler(notifications, _FakeRingingServiceGateway());

      await scheduler.requestPermissions();

      expect(
        scheduler.degradation,
        AndroidAlertDegradation.notificationsDenied,
      );
      expect(scheduler.degradationReason, contains('notification'));
    });

    test('DND policy access is attempted but the alarm path never depends on '
        'it', () async {
      final notifications = _FakeNotificationGateway()
        ..policyAccessResult = null; // access not granted
      final service = _FakeRingingServiceGateway();
      final scheduler = _scheduler(notifications, service);

      // Scheduling still works and still rings via playSound + alarm usage.
      scheduler.schedule(DateTime.utc(2026, 9, 18, 7, 50), 'occ42#lead600');
      await scheduler.whenIdle;

      expect(notifications.scheduled, hasLength(1));
      expect(notifications.scheduled.single.android.playSound, isTrue);
      expect(
        notifications.scheduled.single.android.audioAttributesUsage,
        AudioAttributesUsage.alarm,
      );
      // The ringing surface never gates on DND bypass: the service starts
      // regardless of policy access.
      await scheduler.startRinging(
        alarmId: 'occ42#lead600',
        title: 'Meeting alert',
        body: 'starting soon',
      );
      expect(service.startedAlarmIds, ['occ42#lead600']);
    });
  });
}
