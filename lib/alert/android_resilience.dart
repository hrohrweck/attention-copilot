/// Android resilience: reboot rescheduling, capability checks with deep
/// links, and the visible fallback ladder (plan todo 20).
///
/// Two hard rules from the plan:
///
///  * **Re-plan from persisted absolute instants, never trust the OS alarm
///    cache.** Android discards every scheduled alarm on reboot, so after a
///    boot the pending triggers must be rebuilt from the persisted pending
///    set. [AndroidResilience.restore] rebuilds the engine (whose own
///    `_rearm` re-arms the earliest trigger), and [rescheduleOnBoot] pushes
///    every pending trigger within the horizon back onto the scheduler from
///    its stored instant — idempotent by alarm id, so the extra arms never
///    double-fire.
///
///  * **Every degradation is visible, never silent.** The capability checks
///    feed [AndroidResilienceReport], which always carries a
///    [AndroidResilienceDegradation] with a diagnostics label
///    (`degraded: inexact-alarms`, …) and a user-language
///    [AndroidResilienceReport.degradationReason], plus a deep link to the
///    settings screen that grants the missing capability. A positive denial
///    degrades; an unknown (not measurable) capability is reported as
///    unknown, never silently assumed granted or denied.
///
/// The fallback ladder is verified here and honoured by the sibling
/// `AndroidAlertScheduler`:
///
///  * no full-screen intent → the alarm notification (already high
///    importance, alarm category, alarm audio) still rings; Android drops
///    the full-screen launch and shows the notification instead;
///  * no exact alarms → `exactAllowWhileIdle` (`setAndAllowWhileIdle`) with
///    the visible `degraded: inexact-alarms` warning — the scheduler resolves
///    this at schedule time, this module makes it visible and actionable;
///  * no `POST_NOTIFICATIONS` → nothing can be posted, and the report says
///    so instead of letting the meeting pass silently.
///
/// Battery-optimisation exemption is deliberately never requested: the stack
/// relies on alarm-clock exact alarms and, when those are denied, on
/// `setAndAllowWhileIdle` with a visible warning.
library;

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/alert_engine.dart';

/// The Android capabilities the alert stack depends on.
enum AndroidCapability { exactAlarms, fullScreenIntent, notifications }

/// How the Android alert path has degraded, if at all. Every non-[none]
/// value carries a diagnostics label (for the todo 27 diagnostics view) and
/// a user-language reason — never silent.
enum AndroidResilienceDegradation {
  none,

  /// The user denied `POST_NOTIFICATIONS`: nothing can be posted, so no
  /// meeting alert can be shown at all.
  notificationsDenied,

  /// Full-screen intent is unavailable: the alert still rings as a
  /// high-importance alarm notification, but does not take over the screen.
  fullScreenIntentUnavailable,

  /// `SCHEDULE_EXACT_ALARM`/`USE_EXACT_ALARM` is unavailable: alarms fall
  /// back to `exactAllowWhileIdle` (`setAndAllowWhileIdle`) and may drift.
  inexactAlarms;

  /// The diagnostics-view label: `degraded: inexact-alarms` etc. [none] has
  /// no label.
  String get diagnosticLabel => switch (this) {
        none => 'none',
        notificationsDenied => 'degraded: notifications-denied',
        fullScreenIntentUnavailable =>
          'degraded: full-screen-intent-unavailable',
        inexactAlarms => 'degraded: inexact-alarms',
      };
}

/// Android intent actions that deep-link to the settings screen granting the
/// matching capability. These are the exact action strings
/// `ACTION_REQUEST_SCHEDULE_EXACT_ALARM`,
/// `ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT` and
/// `ACTION_APP_NOTIFICATION_SETTINGS` carry.
abstract final class AndroidDeepLinks {
  static const exactAlarms = 'android.settings.REQUEST_SCHEDULE_EXACT_ALARM';
  static const fullScreenIntent =
      'android.settings.MANAGE_APP_USE_FULL_SCREEN_INTENT';
  static const notifications = 'android.settings.APP_NOTIFICATION_SETTINGS';
}

/// The notification the ladder falls back to when full-screen intent is
/// unavailable (or nothing, when notifications are denied).
abstract final class AndroidNotificationFallback {
  static const fullScreen = 'full-screen alarm notification';
  static const highImportance = 'high-importance alarm notification';
  static const none = 'no notification can be shown';
}

/// The measured state of one [AndroidCapability], with a user-language
/// explanation and the deep link that grants it.
class AndroidCapabilityStatus {
  const AndroidCapabilityStatus({
    required this.capability,
    required this.granted,
    required this.explanation,
    required this.deepLinkAction,
  });

  final AndroidCapability capability;

  /// `true` granted, `false` denied, `null` not measurable here (reported as
  /// unknown, never silently assumed).
  final bool? granted;

  /// User-language explanation of what this capability does.
  final String explanation;

  /// The settings intent action that grants this capability.
  final String deepLinkAction;
}

/// The result of a capability evaluation: three statuses plus the derived
/// degradation, its visible reason, and the resulting fallback ladder.
class AndroidResilienceReport {
  const AndroidResilienceReport({
    required this.capabilities,
    required this.degradation,
    required this.degradationReason,
    required this.scheduleMode,
    required this.notificationFallback,
  });

  final List<AndroidCapabilityStatus> capabilities;
  final AndroidResilienceDegradation degradation;

  /// User-language reason, empty when the path is fully capable. Never
  /// silent: this is what settings and diagnostics surface.
  final String degradationReason;

  /// The mode the scheduler will use: [AndroidScheduleMode.alarmClock] when
  /// exact alarms are available, `exactAllowWhileIdle` (the
  /// `setAndAllowWhileIdle` fallback) when they are not, `null` when
  /// notifications are denied and nothing can be posted.
  final AndroidScheduleMode? scheduleMode;

  /// What the alert will look like: the full-screen alarm, the
  /// high-importance alarm notification fallback, or nothing.
  final String notificationFallback;
}

/// Reads the Android capabilities and performs the permission/deep-link
/// flows. Android-only; faked in tests.
abstract interface class AndroidCapabilityProbe {
  /// `SCHEDULE_EXACT_ALARM`/`USE_EXACT_ALARM` availability (no side effects).
  Future<bool> canScheduleExactAlarms();

  /// `NotificationManager.canUseFullScreenIntent()` status, or null when it
  /// cannot be measured here (unknown, never silently granted).
  Future<bool?> canUseFullScreenIntent();

  /// `POST_NOTIFICATIONS` status, or null when it cannot be measured here.
  Future<bool?> areNotificationsEnabled();

  /// Deep link: opens `ACTION_REQUEST_SCHEDULE_EXACT_ALARM` when needed.
  Future<bool?> requestExactAlarmsPermission();

  /// Deep link: opens `ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT` when
  /// needed; completes with the resulting grant state.
  Future<bool?> requestFullScreenIntentPermission();

  /// Deep link: the `POST_NOTIFICATIONS` request flow.
  Future<bool?> requestNotificationPermission();
}

/// The flag [BootReceiver] sets on `BOOT_COMPLETED`. Consuming it (read +
/// clear) is the trigger for the reschedule path on the next app start.
abstract interface class BootRescheduleFlag {
  /// Reads and clears the flag. `true` means the device booted since the
  /// last app start and pending triggers must be re-planned.
  Future<bool> consume();
}

/// The Android resilience layer: restores the engine from persisted
/// instants, re-plans the scheduler after a boot, and evaluates the
/// capability ladder with visible degradations and deep links.
class AndroidResilience {
  AndroidResilience._(
    this._engine,
    this._scheduler,
    this._persistence,
    this._probe,
    this._bootFlag,
    this._rescheduleHorizon,
  );

  /// Rebuilds the engine from the persisted pending set (absolute UTC
  /// instants — nothing is lost across a reboot) and re-arms the scheduler.
  ///
  /// This is the app-start half of the reschedule contract; [rescheduleOnBoot]
  /// / [rescheduleAfterBootIfNeeded] are the boot half.
  static Future<AndroidResilience> restore({
    required AlertSchedulerPort scheduler,
    required AlertSurfacePort surface,
    required AlertPersistencePort persistence,
    required EnginePresence presence,
    required AndroidCapabilityProbe probe,
    required BootRescheduleFlag bootFlag,
    Duration meetingEndedGrace = const Duration(minutes: 2),
    Duration rescheduleHorizon = const Duration(hours: 24),
  }) async {
    final engine = await AlertEngine.restore(
      scheduler: scheduler,
      surface: surface,
      persistence: persistence,
      presence: presence,
      meetingEndedGrace: meetingEndedGrace,
    );
    return AndroidResilience._(
      engine,
      scheduler,
      persistence,
      probe,
      bootFlag,
      rescheduleHorizon,
    );
  }

  final AlertEngine _engine;
  final AlertSchedulerPort _scheduler;
  final AlertPersistencePort _persistence;
  final AndroidCapabilityProbe _probe;
  final BootRescheduleFlag _bootFlag;
  final Duration _rescheduleHorizon;
  AndroidResilienceReport? _lastReport;

  /// The engine rebuilt from the persisted pending set.
  AlertEngine get engine => _engine;

  /// The current degraded state (updated by [evaluateCapabilities] and
  /// [applyRemediation]). Visible, never silent.
  AndroidResilienceDegradation get degradation =>
      _lastReport?.degradation ?? AndroidResilienceDegradation.none;

  /// Human-readable reason for the degradation, or an empty string when the
  /// alert path is fully capable.
  String get degradationReason => _lastReport?.degradationReason ?? '';

  /// Evaluates the three capabilities and derives the visible degradation
  /// state and the fallback ladder.
  Future<AndroidResilienceReport> evaluateCapabilities() async {
    final exact = await _probe.canScheduleExactAlarms();
    final fullScreenIntent = await _probe.canUseFullScreenIntent();
    final notifications = await _probe.areNotificationsEnabled();
    final report = _buildReport(
      exactAlarms: exact,
      fullScreenIntent: fullScreenIntent,
      notifications: notifications,
    );
    _lastReport = report;
    return report;
  }

  /// Runs the deep-link / permission flow for [capability] and re-evaluates.
  /// A granted flow clears the degradation; a denied one keeps it visible.
  Future<AndroidResilienceReport> applyRemediation(
    AndroidCapability capability,
  ) async {
    switch (capability) {
      case AndroidCapability.exactAlarms:
        await _probe.requestExactAlarmsPermission();
      case AndroidCapability.fullScreenIntent:
        await _probe.requestFullScreenIntentPermission();
      case AndroidCapability.notifications:
        await _probe.requestNotificationPermission();
    }
    return evaluateCapabilities();
  }

  /// Re-plans the scheduler from the persisted absolute instants after a
  /// boot: every pending trigger whose stored instant falls in
  /// `(now, now + rescheduleHorizon]` is re-armed, idempotent by alarm id.
  ///
  /// The OS alarm cache is never trusted — Android discards it on reboot —
  /// and nothing is silently dropped:
  ///
  ///  * deferred/ringing triggers are the engine's runtime concern (it
  ///    re-arms them on its own state changes), not the scheduler's;
  ///  * triggers that came due while the device was off are left for the
  ///    engine to fire or retire on its next tick, never armed in the past;
  ///  * triggers beyond the horizon are re-planned by the next agenda plan.
  ///
  /// Returns the number of triggers re-armed.
  Future<int> rescheduleOnBoot(DateTime now) async {
    final nowUtc = now.toUtc();
    final horizon = nowUtc.add(_rescheduleHorizon);
    final records = await _persistence.loadPending();
    var count = 0;
    for (final record in records) {
      if (record.state != PendingTriggerState.pending) continue;
      if (record.instantUtc.isBefore(nowUtc)) continue;
      if (record.instantUtc.isAfter(horizon)) continue;
      // The engine re-arms only the earliest trigger; arming every trigger
      // within the horizon makes each one a separate platform alarm, so a
      // Doze cycle or a missed wake-up can never lose the chain. Same
      // notification id = the platform replaces, never duplicates.
      _scheduler.schedule(record.instantUtc, record.alarmId);
      count += 1;
    }
    return count;
  }

  /// App-start hook: consumes the [BootReceiver] flag and, when the device
  /// booted since the last start, re-plans the pending triggers. Returns the
  /// number of triggers re-armed (0 when no boot happened).
  Future<int> rescheduleAfterBootIfNeeded(DateTime now) async {
    if (!await _bootFlag.consume()) return 0;
    return rescheduleOnBoot(now);
  }

  AndroidResilienceReport _buildReport({
    required bool exactAlarms,
    required bool? fullScreenIntent,
    required bool? notifications,
  }) {
    final statuses = <AndroidCapabilityStatus>[
      AndroidCapabilityStatus(
        capability: AndroidCapability.exactAlarms,
        granted: exactAlarms,
        explanation: 'Exact alarms let a meeting alert fire at the precise '
            'moment. Without them the alert may arrive late.',
        deepLinkAction: AndroidDeepLinks.exactAlarms,
      ),
      AndroidCapabilityStatus(
        capability: AndroidCapability.fullScreenIntent,
        granted: fullScreenIntent,
        explanation: 'Full-screen alerts take over the screen, even over the '
            'lock screen. Without them a high-importance notification rings '
            'instead.',
        deepLinkAction: AndroidDeepLinks.fullScreenIntent,
      ),
      AndroidCapabilityStatus(
        capability: AndroidCapability.notifications,
        granted: notifications,
        explanation: 'Notifications are how a meeting alert is shown. '
            'Without them no alert can appear.',
        deepLinkAction: AndroidDeepLinks.notifications,
      ),
    ];

    final reasons = <String>[];
    var degradation = AndroidResilienceDegradation.none;
    if (notifications == false) {
      degradation = AndroidResilienceDegradation.notificationsDenied;
      reasons.add(_notificationsReason);
    }
    if (fullScreenIntent == false) {
      degradation = degradation == AndroidResilienceDegradation.none
          ? AndroidResilienceDegradation.fullScreenIntentUnavailable
          : degradation;
      reasons.add(_fullScreenIntentReason);
    }
    if (!exactAlarms) {
      degradation = degradation == AndroidResilienceDegradation.none
          ? AndroidResilienceDegradation.inexactAlarms
          : degradation;
      reasons.add(_inexactAlarmsReason);
    }

    // The ladder: mode and visible form of the alert, derived from the
    // measurements above.
    final AndroidScheduleMode? scheduleMode;
    final String notificationFallback;
    if (notifications == false) {
      scheduleMode = null;
      notificationFallback = AndroidNotificationFallback.none;
    } else {
      scheduleMode = exactAlarms
          ? AndroidScheduleMode.alarmClock
          : AndroidScheduleMode.exactAllowWhileIdle;
      notificationFallback = fullScreenIntent == false
          ? AndroidNotificationFallback.highImportance
          : AndroidNotificationFallback.fullScreen;
    }

    return AndroidResilienceReport(
      capabilities: statuses,
      degradation: degradation,
      degradationReason: reasons.join(' '),
      scheduleMode: scheduleMode,
      notificationFallback: notificationFallback,
    );
  }

  static const _notificationsReason =
      'Notifications are disabled: meeting alerts cannot be shown. Enable '
      'notifications for attention_copilot in system settings.';

  static const _fullScreenIntentReason =
      'Full-screen alerts are unavailable: a meeting alert appears as a '
      'high-importance notification instead of taking over the screen. '
      'Allow full-screen alerts for attention_copilot in system settings.';

  static const _inexactAlarmsReason =
      'Exact alarms are not permitted: alerts may be late. Grant '
      '"Alarms & reminders" access to attention_copilot.';
}

/// Real capability probe over `flutter_local_notifications`. Construct on
/// Android only.
///
/// Full-screen intent is the one capability the plugin does not expose as a
/// pure status read — its channel only offers the combined
/// check-then-remediate flow (`requestFullScreenIntentPermission`). The pure
/// check therefore goes through the `attention_copilot/android_capabilities`
/// channel; until a handler is attached it reports unknown (never silently
/// granted), and every remediation call records the definitive grant state.
class FlutterNotificationCapabilityProbe implements AndroidCapabilityProbe {
  FlutterNotificationCapabilityProbe({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static const _capabilitiesChannel =
      MethodChannel('attention_copilot/android_capabilities');

  final FlutterLocalNotificationsPlugin _plugin;
  bool? _lastKnownFullScreenIntent;

  AndroidFlutterLocalNotificationsPlugin get _android =>
      _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()!;

  @override
  Future<bool> canScheduleExactAlarms() async =>
      await _android.canScheduleExactNotifications() ?? false;

  @override
  Future<bool?> canUseFullScreenIntent() async {
    try {
      final value =
          await _capabilitiesChannel.invokeMethod<bool>('canUseFullScreenIntent');
      if (value != null) {
        _lastKnownFullScreenIntent = value;
        return value;
      }
    } on MissingPluginException {
      // No handler attached: unknown, not silently granted or denied.
    } on PlatformException {
      // Channel error: unknown, not silently granted or denied.
    }
    return _lastKnownFullScreenIntent;
  }

  @override
  Future<bool?> areNotificationsEnabled() => _android.areNotificationsEnabled();

  @override
  Future<bool?> requestExactAlarmsPermission() =>
      _android.requestExactAlarmsPermission();

  @override
  Future<bool?> requestFullScreenIntentPermission() async {
    final granted = await _android.requestFullScreenIntentPermission();
    if (granted != null) _lastKnownFullScreenIntent = granted;
    return granted;
  }

  @override
  Future<bool?> requestNotificationPermission() =>
      _android.requestNotificationsPermission();
}

/// Real [BootRescheduleFlag] over `shared_preferences`. The Kotlin
/// [BootReceiver] writes the same key (with the `flutter.` prefix the
/// plugin applies) into the same `FlutterSharedPreferences` file, so the
/// boot event crosses the platform boundary without a dedicated channel.
class SharedPreferencesBootRescheduleFlag implements BootRescheduleFlag {
  static const prefKey = 'boot_reschedule_pending';

  @override
  Future<bool> consume() async {
    final prefs = await SharedPreferences.getInstance();
    final wasSet = prefs.getBool(prefKey) ?? false;
    if (wasSet) {
      await prefs.remove(prefKey);
    }
    return wasSet;
  }
}
