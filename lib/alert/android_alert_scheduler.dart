/// Android alert scheduling and ringing stack: exact alarms via
/// `flutter_local_notifications` (alarm-clock mode, full-screen intent,
/// alarm audio usage), a `flutter_foreground_task` keep-alive service while an
/// alert rings, and a permission-denied fallback that degrades visibly instead
/// of failing silently.
///
/// This file is the Android half of the acknowledgement contract: the
/// notification is `ongoing`, never auto-cancels, and stops only when the
/// engine acknowledges the alert, which cancels the notification and tears
/// the foreground service down.
///
/// DND policy: Android 15 forbids changing the user's global DND state, so
/// nothing here ever does. The channel's `setBypassDnd` is *attempted* only
/// when the user grants notification-policy access, and the ringing path
/// never relies on it succeeding.
library;

import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart'
    hide NotificationVisibility;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../domain/alert_engine.dart';

/// How the Android alert path has degraded, if at all.
///
/// Every non-`none` value is user-visible (settings/diagnostics, todo 20/27)
/// and never silent.
enum AndroidAlertDegradation {
  none,

  /// The user denied `POST_NOTIFICATIONS`: nothing can be posted.
  notificationsDenied,

  /// `SCHEDULE_EXACT_ALARM`/`USE_EXACT_ALARM` is unavailable: alarms fall
  /// back to `exactAllowWhileIdle` and may drift.
  inexactAlarms,
}

/// Thin gateway over `flutter_local_notifications` so tests can run against a
/// fake and assert the exact alarm semantics without a device.
///
/// Android-only: constructing it on another platform is a programmer error.
abstract interface class AndroidNotificationGateway {
  Future<void> initialize(String defaultIcon);

  /// Creates (or updates) a notification channel on Android 8+.
  Future<void> createChannel(AndroidNotificationChannel channel);

  Future<bool?> requestNotificationPermission();

  Future<bool> canScheduleExactNotifications();

  Future<bool?> requestExactAlarmsPermission();

  /// Requests notification-policy access (the precondition for any channel to
  /// bypass DND). Attempted, never relied upon.
  Future<bool?> requestNotificationPolicyAccess();

  /// Schedules one notification at [instantUtc] in [timezoneName].
  Future<void> schedule({
    required int id,
    required DateTime instantUtc,
    required String timezoneName,
    required String title,
    required String body,
    required String payload,
    required AndroidScheduleMode scheduleMode,
    required AndroidNotificationDetails android,
  });

  Future<void> cancel(int id);

  Future<void> cancelAll();
}

/// Thin gateway over `flutter_foreground_task` (same fake-for-tests purpose).
abstract interface class RingingServiceGateway {
  Future<void> init();

  Future<bool> get isRunning;

  /// Starts the keep-alive service for one ringing alert. The service
  /// notification is deliberately quiet — the alarm notification rings.
  Future<void> start({
    required String alarmId,
    required String title,
    required String body,
  });

  Future<void> stop();
}

/// The Android implementation of [AlertSchedulerPort] plus the ringing
/// lifecycle the Android alert surface (todo 19) drives:
///
///  * [schedule]/[cancel]: exact alarms; one alarm id maps to one stable
///    notification id.
///  * [startRinging]: starts the foreground keep-alive service.
///  * [acknowledge]: cancels the notification and stops the service — the
///    only way a ringing alert ends.
///
/// Deferral is enforced by the engine: when it defers a trigger it calls
/// [cancel] (via `_rearm`), and this scheduler honours that by removing the
/// platform alarm, so nothing rings while the engine reports the alert
/// deferred.
class AndroidAlertScheduler implements AlertSchedulerPort {
  AndroidAlertScheduler({
    required this._notifications,
    required this._service,
    Future<String> Function()? timezoneName,
  }) : _timezoneName = timezoneName ?? _systemTimezoneName;

  /// Alarm notification channel: high importance, alarm audio usage.
  static const alarmChannelId = 'meeting_alerts';
  static const alarmChannelName = 'Meeting alerts';
  static const alarmChannelDescription =
      'Un-ignorable meeting alerts that stop only when you acknowledge them.';

  /// Quiet keep-alive channel for the ringing foreground service. The alarm
  /// notification rings; this one must not.
  static const ringingServiceChannelId = 'alert_ringing_keepalive';
  static const ringingServiceChannelName = 'Alert keep-alive';

  final AndroidNotificationGateway _notifications;
  final RingingServiceGateway _service;
  final Future<String> Function() _timezoneName;

  /// Serialises all plugin work so schedule/cancel/acknowledge never
  /// interleave; `whenIdle` lets tests (and diagnostics) await the tail.
  Future<void> _queue = Future.value();
  bool _initialized = false;
  bool _channelBypassDnd = false;
  AndroidAlertDegradation _degradation = AndroidAlertDegradation.none;
  Object? _lastError;

  /// The current degraded state of the alarm path.
  AndroidAlertDegradation get degradation => _degradation;

  /// Human-readable reason for the degradation, or an empty string when the
  /// alarm path is fully capable. Never silent: callers surface this text.
  String get degradationReason => switch (_degradation) {
        AndroidAlertDegradation.none => '',
        AndroidAlertDegradation.notificationsDenied =>
          'Notifications are disabled: alerts cannot be shown. Enable '
              'notifications for attention_copilot in system settings.',
        AndroidAlertDegradation.inexactAlarms =>
          'Exact alarms are not permitted: alerts may be late. Grant '
              '"Alarms & reminders" access to attention_copilot.',
      };

  /// The last plugin error, for diagnostics. Null when the path is clean.
  Object? get lastError => _lastError;

  /// Completes when all queued scheduling work has finished.
  Future<void> get whenIdle => _queue;

  /// Stable, deterministic mapping from an engine alarm id to an Android
  /// notification id (FNV-1a, 31-bit positive). Not `String.hashCode`: that
  /// is not guaranteed stable across restarts, and cancel-after-restart
  /// needs the same id.
  static int notificationIdFor(String alarmId) {
    var hash = 0x811c9dc5;
    for (final unit in alarmId.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash;
  }

  static Future<String> _systemTimezoneName() async =>
      (await FlutterTimezone.getLocalTimezone()).identifier;

  /// Initialises the plugin, creates the alarm channel (once) and prepares
  /// the ringing service. Idempotent.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    await _notifications.initialize('@mipmap/ic_launcher');
    await _notifications
        .createChannel(_alarmChannel(bypassDnd: _channelBypassDnd));
    await _service.init();
  }

  /// Requests the Android capabilities this stack needs, and records the
  /// resulting degraded state. Safe to call repeatedly (e.g. from settings).
  Future<void> requestPermissions() async {
    final work = _queue;
    _queue = work.then((_) async {
      try {
        await initialize();
        final notifications =
            await _notifications.requestNotificationPermission();
        if (notifications == false) {
          _degradation = AndroidAlertDegradation.notificationsDenied;
        } else if (_degradation ==
            AndroidAlertDegradation.notificationsDenied) {
          _degradation = AndroidAlertDegradation.none;
        }
        if (await _notifications.canScheduleExactNotifications()) {
          return;
        }
        final exact = await _notifications.requestExactAlarmsPermission();
        if (exact != true) {
          _degradation = AndroidAlertDegradation.inexactAlarms;
        }
      } catch (error) {
        _lastError = error;
      }
    });
    await _queue;
  }

  /// Attempts DND-bypass policy access for the alarm channel. The alarm path
  /// never relies on this succeeding; it only upgrades the channel when the
  /// user granted access (note Android freezes channel importance after
  /// first creation, so the upgrade is best-effort).
  Future<void> attemptDndBypassAccess() async {
    final work = _queue;
    _queue = work.then((_) async {
      try {
        await initialize();
        final granted =
            await _notifications.requestNotificationPolicyAccess();
        if (granted == true && !_channelBypassDnd) {
          _channelBypassDnd = true;
          await _notifications.createChannel(_alarmChannel(bypassDnd: true));
        }
      } catch (error) {
        _lastError = error;
      }
    });
    await _queue;
  }

  @override
  void schedule(DateTime instantUtc, String alarmId) {
    _queue = _queue.then((_) => _scheduleNow(instantUtc, alarmId));
  }

  @override
  void cancel(String alarmId) {
    _queue = _queue.then((_) async {
      try {
        await _notifications.cancel(notificationIdFor(alarmId));
      } catch (error) {
        _lastError = error;
      }
    });
  }

  /// Starts the foreground keep-alive service for one ringing alert. Called
  /// by the Android alert surface when the engine fires an alert; never
  /// called while the engine reports the alert deferred.
  Future<void> startRinging({
    required String alarmId,
    required String title,
    required String body,
  }) async {
    await _queue;
    await _service.start(alarmId: alarmId, title: title, body: body);
  }

  /// Explicit acknowledgement: cancels the notification and stops the
  /// ringing service. The only way a ringing alert ends.
  Future<void> acknowledge(String alarmId) async {
    final work = _queue;
    _queue = work.then((_) => _acknowledgeNow(alarmId));
    await _queue;
  }

  Future<void> _scheduleNow(DateTime instantUtc, String alarmId) async {
    try {
      await initialize();
      final mode = await _resolveScheduleMode();
      final timezoneName = await _timezoneName();
      await _notifications.schedule(
        id: notificationIdFor(alarmId),
        instantUtc: instantUtc.toUtc(),
        timezoneName: timezoneName,
        title: 'Meeting alert',
        body: 'Your meeting needs you. Acknowledge to stop the alarm.',
        payload: alarmId,
        scheduleMode: mode,
        android: _alarmDetails(),
      );
    } catch (error) {
      _lastError = error;
    }
  }

  Future<AndroidScheduleMode> _resolveScheduleMode() async {
    if (await _notifications.canScheduleExactNotifications()) {
      return AndroidScheduleMode.alarmClock;
    }
    final granted = await _notifications.requestExactAlarmsPermission();
    if (granted == true) {
      return AndroidScheduleMode.alarmClock;
    }
    _degradation = AndroidAlertDegradation.inexactAlarms;
    // Fallback: exact while idle, visibly degraded, never silently missing.
    return AndroidScheduleMode.exactAllowWhileIdle;
  }

  Future<void> _acknowledgeNow(String alarmId) async {
    try {
      await _notifications.cancel(notificationIdFor(alarmId));
    } catch (error) {
      // The service must still stop even if the notification cancel failed.
      _lastError = error;
    }
    await _service.stop();
  }

  AndroidNotificationChannel _alarmChannel({required bool bypassDnd}) =>
      AndroidNotificationChannel(
        alarmChannelId,
        alarmChannelName,
        description: alarmChannelDescription,
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
        audioAttributesUsage: AudioAttributesUsage.alarm,
        bypassDnd: bypassDnd,
      );

  /// The notification that IS the alarm: full-screen intent over the lock
  /// screen, alarm category, alarm audio stream, ongoing, never auto-cancel.
  ///
  /// Audio looping is not expressible through the notification itself; it is
  /// driven by the engine's escalation ladder (`repeatAudioCycle`), which
  /// re-raises the alert until the user acknowledges it.
  AndroidNotificationDetails _alarmDetails() => AndroidNotificationDetails(
        alarmChannelId,
        alarmChannelName,
        channelDescription: alarmChannelDescription,
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.alarm,
        fullScreenIntent: true,
        playSound: true,
        audioAttributesUsage: AudioAttributesUsage.alarm,
        enableVibration: true,
        ongoing: true,
        autoCancel: false,
        visibility: NotificationVisibility.public,
      );
}

/// Real `flutter_local_notifications` gateway. Construct on Android only.
class FlutterNotificationGateway implements AndroidNotificationGateway {
  FlutterNotificationGateway({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  AndroidFlutterLocalNotificationsPlugin get _android =>
      _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()!;

  @override
  Future<void> initialize(String defaultIcon) async {
    await _plugin.initialize(
      settings: InitializationSettings(
        android: AndroidInitializationSettings(defaultIcon),
      ),
    );
  }

  @override
  Future<void> createChannel(AndroidNotificationChannel channel) =>
      _android.createNotificationChannel(channel);

  @override
  Future<bool?> requestNotificationPermission() =>
      _android.requestNotificationsPermission();

  @override
  Future<bool> canScheduleExactNotifications() async =>
      await _android.canScheduleExactNotifications() ?? false;

  @override
  Future<bool?> requestExactAlarmsPermission() =>
      _android.requestExactAlarmsPermission();

  @override
  Future<bool?> requestNotificationPolicyAccess() =>
      _android.requestNotificationPolicyAccess();

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
    tzdata.initializeTimeZones();
    final location = tz.getLocation(timezoneName);
    await _plugin.zonedSchedule(
      id: id,
      scheduledDate: tz.TZDateTime.from(instantUtc, location),
      title: title,
      body: body,
      payload: payload,
      notificationDetails: NotificationDetails(android: android),
      androidScheduleMode: scheduleMode,
    );
  }

  @override
  Future<void> cancel(int id) => _plugin.cancel(id: id);

  @override
  Future<void> cancelAll() => _plugin.cancelAll();
}

/// Real `flutter_foreground_task` gateway. Construct on Android only.
class FlutterRingingServiceGateway implements RingingServiceGateway {
  @override
  Future<void> init() async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: AndroidAlertScheduler.ringingServiceChannelId,
        channelName: AndroidAlertScheduler.ringingServiceChannelName,
        channelDescription:
            'Keeps the process alive while a meeting alert rings.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        playSound: false,
        enableVibration: false,
        showWhen: false,
        showBadge: false,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
        // No zombie restarts: acknowledgement is the only thing that stops
        // a ringing alert, and it stops this service too.
        allowAutoRestart: false,
      ),
    );
  }

  @override
  Future<bool> get isRunning => FlutterForegroundTask.isRunningService;

  @override
  Future<void> start({
    required String alarmId,
    required String title,
    required String body,
  }) async {
    if (await FlutterForegroundTask.isRunningService) return;
    final result = await FlutterForegroundTask.startService(
      serviceTypes: const [ForegroundServiceTypes.mediaPlayback],
      notificationTitle: title,
      notificationText: body,
      callback: alertRingingServiceEntry,
    );
    if (result is ServiceRequestFailure) {
      throw StateError('foreground service failed to start: ${result.error}');
    }
  }

  @override
  Future<void> stop() async {
    if (!await FlutterForegroundTask.isRunningService) return;
    final result = await FlutterForegroundTask.stopService();
    if (result is ServiceRequestFailure) {
      throw StateError('foreground service failed to stop: ${result.error}');
    }
  }
}

/// Entry point executed by `flutter_foreground_task` in a separate isolate.
@pragma('vm:entry-point')
void alertRingingServiceEntry() {
  FlutterForegroundTask.setTaskHandler(AlertRingingTaskHandler());
}

/// Keep-alive handler: the service exists only so the process survives while
/// the alarm notification rings; all user-facing behaviour lives in the
/// alarm notification and the `AlertActivity`.
class AlertRingingTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}
