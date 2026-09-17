/// The application composition root: the riverpod provider graph that wires
/// storage, calendar sources, the alert engine, presence, the tray/autostart
/// integrations and the UI routes into one bootable app.
///
/// Design rules:
///   * every plugin and IO call sits behind a provider so widget tests boot
///     the app with fakes and never touch `window_manager`, `tray_manager`,
///     `audioplayers`, `flutter_local_notifications` or a native channel;
///   * the wall clock is read in exactly one place — [clockProvider] — and
///     everything else is handed `now` or a clock function;
///   * platform variants are gated by [defaultTargetPlatform] through the
///     [appIsAndroid]/[appIsDesktop] helpers, so a test host (or a web
///     build) falls back to the neutral wiring instead of crashing.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:path_provider/path_provider.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:window_manager/window_manager.dart';

import '../alert/alert_platform_driver.dart';
import '../alert/alert_surface.dart';
import '../alert/android_alert_scheduler.dart';
import '../alert/android_resilience.dart';
import '../alert/deferral_coordinator.dart';
import '../data/sources/calendar_contract_source.dart';
import '../data/sources/eventkit_source.dart';
import '../data/sources/google_calendar_source.dart';
import '../data/sources/ics_source.dart';
import '../data/sources/refresh_orchestrator.dart';
import '../data/sources/registry.dart';
import '../data/sources/source.dart';
import '../data/storage/agenda_cache.dart';
import '../data/storage/secret_store.dart';
import '../data/storage/settings_store.dart';
import '../diagnostics/diagnostics_view.dart' as diagnostics;
import '../domain/alert_engine.dart';
import '../domain/alert_policy.dart';
import '../domain/models/event_occurrence.dart';
import '../domain/models/meeting_join_info.dart';
import '../presence/presence_factory.dart';
import '../presence/presence_service.dart';
import '../presence/presence_state.dart';
import '../ui/agenda_screen.dart';
import '../ui/onboarding_wizard.dart';
import '../ui/ringing_alert_view.dart';
import '../ui/settings_screen.dart';
import 'autostart_controller.dart';
import 'tray_controller.dart';
import 'tray_platform.dart';

// ---------------------------------------------------------------------------
// Platform gates
// ---------------------------------------------------------------------------

/// Whether the app targets Android (the `defaultTargetPlatform` value the
/// composition root uses for all platform branching).
bool get appIsAndroid => defaultTargetPlatform == TargetPlatform.android;

/// Whether the app targets macOS.
bool get appIsMacOS => defaultTargetPlatform == TargetPlatform.macOS;

/// Whether the app targets a desktop OS (macOS, Windows or Linux).
bool get appIsDesktop =>
    appIsMacOS ||
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.linux;

// ---------------------------------------------------------------------------
// Time
// ---------------------------------------------------------------------------

/// The injected wall clock. The ONLY place `DateTime.now` is read in the
/// application layer; every consumer reads "now" through this provider.
final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Resolves the device's IANA timezone. Also initialises the bundled tzdata
/// database, so this is safe to call before any `tz.getLocation` use.
Future<tz.Location> resolveLocalTimezone() async {
  tzdata.initializeTimeZones();
  final info = await FlutterTimezone.getLocalTimezone();
  return tz.getLocation(info.identifier);
}

/// The user's IANA timezone. `main()` overrides this with the zone it
/// resolved during bootstrap; tests override it with a fixed zone.
final localTimezoneProvider =
    FutureProvider<tz.Location>((ref) => resolveLocalTimezone());

// ---------------------------------------------------------------------------
// Storage seams
// ---------------------------------------------------------------------------

/// Persisted application settings (`shared_preferences`).
final settingsStoreProvider =
    Provider<SettingsStore>((ref) => SettingsStore());

/// Secret material (OAuth tokens, ICS bearer URL) over the platform
/// keychain.
final secretStoreProvider = Provider<SecretStore>((ref) => SecretStore());

/// The incremental-sync cursor cache in the application-support directory.
final agendaCacheProvider = Provider<AgendaCache>((ref) => AgendaCache());

// ---------------------------------------------------------------------------
// Settings state
// ---------------------------------------------------------------------------

/// The live [AppSettings] document, loaded from [settingsStoreProvider] and
/// saved back through [SettingsNotifier.save].
final settingsProvider =
    AsyncNotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);

/// Loads and persists [AppSettings].
class SettingsNotifier extends AsyncNotifier<AppSettings> {
  @override
  Future<AppSettings> build() async {
    final store = ref.watch(settingsStoreProvider);
    final result = await store.load();
    return result.settings;
  }

  /// Persists [next] and publishes it to the UI.
  Future<void> save(AppSettings next) async {
    await ref.read(settingsStoreProvider).save(next);
    state = AsyncData(next);
  }
}

/// The presentation-layer settings ([SettingsExtras]) that are not part of
/// the persisted document yet.
final settingsExtrasProvider = NotifierProvider<SettingsExtrasNotifier,
    SettingsExtras>(SettingsExtrasNotifier.new);

/// Holds the live [SettingsExtras]; persisted wiring lands with the extras
/// store todo.
class SettingsExtrasNotifier extends Notifier<SettingsExtras> {
  @override
  SettingsExtras build() => SettingsExtras.defaults;

  /// Publishes [next] to the UI; callers apply the side effects.
  void update(SettingsExtras next) => state = next;
}

// ---------------------------------------------------------------------------
// Calendar sources
// ---------------------------------------------------------------------------

/// A monotonically increasing revision bumped whenever a connect /
/// disconnect / permission action changes the source set, forcing
/// [registryProvider] (and the wizard statuses) to rebuild.
final registryRevisionProvider =
    NotifierProvider<RegistryRevisionNotifier, int>(RegistryRevisionNotifier.new);

/// The source-set revision counter.
class RegistryRevisionNotifier extends Notifier<int> {
  @override
  int build() => 0;

  /// Invalidates every provider derived from the registry.
  void bump() => state = state + 1;
}

/// The calendar source registry for this platform, rebuilt whenever the
/// settings, the extras or the revision change:
///
///  * EventKit on macOS, enabled by the "macOS calendar integration" toggle;
///  * CalendarContract on Android, enabled by the "device calendars" toggle;
///  * Google Calendar everywhere but Android (Google blocks loopback OAuth
///    there; CalendarContract covers device+Google calendars), registered
///    once a client id exists and enabled only once credentials exist;
///  * ICS everywhere, enabled once a feed URL is configured.
final registryProvider = FutureProvider<CalendarSourceRegistry>((ref) async {
  ref.watch(registryRevisionProvider);
  final settings = await ref.watch(settingsProvider.future);
  final extras = ref.watch(settingsExtrasProvider);
  final secrets = ref.watch(secretStoreProvider);
  final clock = ref.watch(clockProvider);

  final registry = CalendarSourceRegistry();

  if (appIsMacOS) {
    registry.register(
      EventKitSource(),
      enabled: extras.macCalendarsEnabled,
    );
  }
  if (appIsAndroid) {
    registry.register(
      CalendarContractSource(clock: clock),
      enabled: settings.deviceCalendarsEnabled,
    );
  }
  final clientId = settings.googleClientId;
  if (clientId != null && !appIsAndroid) {
    final source = GoogleCalendarSource(
      clientId: clientId,
      calendarId: 'primary',
      secretStore: secrets,
      clock: clock,
    );
    // Registered but only enabled once credentials actually exist: a
    // configured-but-unauthenticated Google source drives the connect flow
    // instead of producing failing fetches.
    registry.register(source, enabled: await secrets.readAccessToken() != null);
  }
  final icsUrl = await secrets.readIcsBearerUrl();
  if (icsUrl != null && icsUrl.isNotEmpty) {
    registry.register(
      IcsSource(url: icsUrl, secretStore: secrets, clock: clock),
      enabled: true,
    );
  }
  return registry;
});

/// The refresh orchestrator over the live registry, seeded with the
/// incremental cursors from the agenda cache so a restart continues where
/// the last fetch stopped.
final refreshOrchestratorProvider =
    FutureProvider<RefreshOrchestrator>((ref) async {
  final registry = await ref.watch(registryProvider.future);
  final cache = ref.watch(agendaCacheProvider);
  final clock = ref.watch(clockProvider);

  final cached = await cache.load();
  final initialCursors = <String, SourceCursor>{};
  for (final entry in cached.data.cursors.entries) {
    final cursor = entry.value;
    if (entry.key.startsWith('ics:')) {
      // ICS persists only the HTTP validators; the content hash is rebuilt
      // in memory on the next fetch.
      initialCursors[entry.key] =
          SourceCursor(IcsSourceCursor.fromAgendaCursor(cursor));
    } else if (cursor.syncToken != null) {
      // Google: the sync token IS the cursor payload.
      initialCursors[entry.key] = SourceCursor(cursor.syncToken);
    }
  }

  return RefreshOrchestrator(
    registry: registry,
    clock: clock,
    initialCursors: initialCursors,
  );
});

// ---------------------------------------------------------------------------
// Agenda state
// ---------------------------------------------------------------------------

/// The agenda the UI renders: the orchestrator's last-known-good occurrences
/// plus the per-source statuses and the last refresh instant.
class AgendaViewState {
  const AgendaViewState({
    required this.occurrences,
    required this.statuses,
    required this.lastRefreshedAt,
  });

  final List<EventOccurrence> occurrences;
  final Map<String, SourceStatus> statuses;
  final DateTime? lastRefreshedAt;
}

/// The live agenda. Building it runs the initial refresh; [AgendaNotifier.refreshNow]
/// is the manual / pull-to-refresh path. After every refresh the cursors are
/// persisted to the agenda cache and the alert engine is re-planned.
final agendaStateProvider =
    AsyncNotifierProvider<AgendaNotifier, AgendaViewState>(AgendaNotifier.new);

/// Owns the refresh lifecycle and the engine re-plan.
class AgendaNotifier extends AsyncNotifier<AgendaViewState> {
  @override
  Future<AgendaViewState> build() async {
    final orchestrator = await ref.watch(refreshOrchestratorProvider.future);
    final result = await orchestrator.refresh(force: true);
    await _afterRefresh(orchestrator, result);
    return _view(result);
  }

  /// Runs a forced refresh and publishes the result. Returns when the fetch,
  /// the cursor persistence and the engine re-plan have all finished.
  Future<void> refreshNow() async {
    final orchestrator = await ref.read(refreshOrchestratorProvider.future);
    final result = await orchestrator.refresh(force: true);
    await _afterRefresh(orchestrator, result);
    state = AsyncData(_view(result));
  }

  Future<void> _afterRefresh(
    RefreshOrchestrator orchestrator,
    RefreshResult result,
  ) async {
    await _persistCursors(orchestrator, result);
    await _planEngine(result.occurrences);
  }

  Future<void> _persistCursors(
    RefreshOrchestrator orchestrator,
    RefreshResult result,
  ) async {
    final cursors = <String, AgendaSourceCursor>{};
    for (final entry in orchestrator.cursors.entries) {
      switch (entry.value.value) {
        case final IcsSourceCursor ics:
          cursors[entry.key] = ics.toAgendaCursor();
        case final String syncToken:
          cursors[entry.key] = AgendaSourceCursor(syncToken: syncToken);
        case null:
          break;
        default:
          // An unrecognised cursor payload is never persisted: writing it
          // could corrupt a future load.
          break;
      }
    }
    await ref.read(agendaCacheProvider).save(AgendaCacheData(
      schemaVersion: AgendaCacheData.currentSchemaVersion,
      fetchedAt: result.startedAt?.toUtc(),
      cursors: cursors,
    ));
  }

  Future<void> _planEngine(List<EventOccurrence> occurrences) async {
    final engine = await ref.read(alertEngineProvider.future);
    final policy = ref.read(alertPolicyProvider);
    final now = ref.read(clockProvider)();
    engine.plan(
      [for (final occurrence in occurrences) _AlertOccurrenceAdapter(occurrence)],
      policy,
      now,
    );
  }

  AgendaViewState _view(RefreshResult result) => AgendaViewState(
        occurrences: result.occurrences,
        statuses: result.statuses,
        lastRefreshedAt: result.startedAt,
      );
}

// ---------------------------------------------------------------------------
// Alert policy
// ---------------------------------------------------------------------------

/// The heads-up profile used for long lead times (>= 5 minutes).
const AlertProfile _headsUpProfile = AlertProfile(
  audioId: 'chime',
  volume: 0.6,
  accent: 'amber',
  fullscreen: false,
  loopAudio: false,
);

/// The urgent profile used for short lead times (< 5 minutes).
const AlertProfile _urgentProfile = AlertProfile(
  audioId: 'alarm',
  volume: 1.0,
  accent: 'red',
  fullscreen: true,
  loopAudio: true,
);

/// Maps one persisted lead-time minute onto a lead-time entry: long lead
/// times get the gentle chime profile, short ones the loud urgent profile.
AlertLeadTime _leadTimeForMinutes(int minutes) => minutes >= 5
    ? AlertLeadTime(Duration(minutes: minutes), _headsUpProfile)
    : AlertLeadTime(Duration(minutes: minutes), _urgentProfile);

/// The alert policy derived from the persisted settings: lead times from
/// [AppSettings.alertLeadMinutes], escalation cadence from
/// [SettingsExtras.repeatIntervalSeconds] / [SettingsExtras.maxAlertDurationMinutes]
/// and the snooze switch from [AppSettings.snoozeEnabled].
final alertPolicyProvider = Provider<AlertPolicy>((ref) {
  final settings = ref.watch(settingsProvider).value ?? AppSettings.defaults();
  final extras = ref.watch(settingsExtrasProvider);
  final repeatEvery = Duration(seconds: extras.repeatIntervalSeconds);
  final holdAfter = Duration(minutes: extras.maxAlertDurationMinutes);
  return AlertPolicy(
    leadTimes: [
      for (final minutes in settings.alertLeadMinutes) _leadTimeForMinutes(minutes),
    ],
    escalation: [
      EscalationStep(
        after: Duration.zero,
        action: EscalationAction.repeatAudioCycle,
        repeatEvery: repeatEvery,
      ),
      const EscalationStep(
        after: Duration(seconds: 30),
        action: EscalationAction.raiseVolume,
      ),
      const EscalationStep(
        after: Duration(seconds: 60),
        action: EscalationAction.reRaiseWindow,
      ),
      const EscalationStep(
        after: Duration(seconds: 90),
        action: EscalationAction.changeAccent,
      ),
      EscalationStep(
        after: holdAfter,
        action: EscalationAction.holdWindowAndRemind,
        repeatEvery: repeatEvery,
      ),
    ],
    snooze: SnoozeConfig(enabled: settings.snoozeEnabled),
  );
});

// ---------------------------------------------------------------------------
// Alert engine
// ---------------------------------------------------------------------------

/// Persistence for the engine's pending set. On Android this doubles as the
/// reschedule-after-boot source ([AndroidResilience]).
final alertPersistencePortProvider =
    Provider<AlertPersistencePort>((ref) => _FileEnginePersistence());

/// JSON-file persistence for the pending trigger set in the
/// application-support directory (atomic temp-file + rename writes, a
/// corrupt document is discarded rather than thrown).
class _FileEnginePersistence implements AlertPersistencePort {
  static const String _fileName = 'pending_triggers.json';

  Future<File> _file() async => File(
      '${(await getApplicationSupportDirectory()).path}/$_fileName');

  @override
  Future<void> savePending(List<PendingTriggerRecord> records) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode([for (final record in records) record.toJson()]),
      flush: true,
    );
    try {
      await tmp.rename(file.path);
    } on FileSystemException {
      // Windows cannot rename over an existing file.
      if (await file.exists()) {
        await file.delete();
      }
      await tmp.rename(file.path);
    }
  }

  @override
  Future<List<PendingTriggerRecord>> loadPending() async {
    final file = await _file();
    try {
      if (!await file.exists()) {
        return const [];
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) {
        return const [];
      }
      return [
        for (final item in decoded)
          if (item is Map)
            PendingTriggerRecord.fromJson(item.cast<String, Object?>()),
      ];
    } on FormatException {
      return const [];
    } on FileSystemException {
      return const [];
    }
  }
}

/// Desktop scheduler port: the desktop app keeps its own heartbeat (no OS
/// alarm exists yet), so this records the engine's armed/cancelled instants
/// in memory. The engine remains the authority; nothing here touches the OS.
final desktopSchedulerPortProvider =
    Provider<AlertSchedulerPort>((ref) => _InProcessSchedulerPort());

/// In-memory [AlertSchedulerPort] for desktop.
class _InProcessSchedulerPort implements AlertSchedulerPort {
  /// The currently armed instants by alarm id, for diagnostics.
  final Map<String, DateTime> armed = {};

  @override
  void schedule(DateTime instantUtc, String alarmId) =>
      armed[alarmId] = instantUtc;

  @override
  void cancel(String alarmId) => armed.remove(alarmId);
}

/// The Android alarm scheduler (`flutter_local_notifications` exact alarms +
/// the `flutter_foreground_task` ringing keep-alive). Android-only; tests
/// override the port provider so this is never constructed.
final androidAlertSchedulerProvider =
    Provider<AndroidAlertScheduler>((ref) => AndroidAlertScheduler(
          notifications: FlutterNotificationGateway(),
          service: FlutterRingingServiceGateway(),
        ));

/// The engine's scheduler port for the current platform.
final alertSchedulerPortProvider = Provider<AlertSchedulerPort>((ref) {
  if (appIsAndroid) {
    return ref.watch(androidAlertSchedulerProvider);
  }
  return ref.watch(desktopSchedulerPortProvider);
});

/// One alert currently ringing on Android, as presented by the
/// `AlertActivity` full-screen surface.
class RingingAlarm {
  const RingingAlarm({
    required this.alarmId,
    required this.occurrenceId,
    required this.startUtc,
    required this.title,
    required this.accent,
    this.joinInfo,
  });

  final String alarmId;
  final String occurrenceId;
  final DateTime startUtc;
  final String title;
  final String accent;
  final MeetingJoinInfo? joinInfo;
}

/// The alert currently ringing on Android (set by the engine surface when
/// the engine fires, cleared when it stops).
final ringingAlarmProvider =
    NotifierProvider<RingingAlarmNotifier, RingingAlarm?>(RingingAlarmNotifier.new);

/// Holds the currently ringing Android alert.
class RingingAlarmNotifier extends Notifier<RingingAlarm?> {
  @override
  RingingAlarm? build() => null;

  /// Records the alert that just started ringing.
  void set(RingingAlarm alarm) => state = alarm;

  /// Clears the ringing alert when it was the one that stopped.
  void clearIf(String alarmId) {
    if (state?.alarmId == alarmId) {
      state = null;
    }
  }
}

/// The engine's user-facing surface for the current platform:
///
///  * desktop: the always-on-top, acknowledgement-gated [DesktopAlertSurface]
///    over `window_manager` + `audioplayers`;
///  * Android: the notification-driven surface that starts the ringing
///    keep-alive service and records the ringing alert for `AlertActivity`.
final alertSurfaceProvider = Provider<AlertSurfacePort>((ref) {
  if (appIsAndroid) {
    final scheduler = ref.watch(androidAlertSchedulerProvider);
    return _AndroidEngineSurface(
      scheduler: scheduler,
      occurrences: () => ref.read(agendaStateProvider).value?.occurrences ??
          const <EventOccurrence>[],
      onRing: (alarm) => ref.read(ringingAlarmProvider.notifier).set(alarm),
      onStop: (alarmId) =>
          ref.read(ringingAlarmProvider.notifier).clearIf(alarmId),
    );
  }
  return DesktopAlertSurface(driver: WindowManagerAudioDriver());
});

/// Android engine surface: `ring` starts the foreground keep-alive service
/// (the alarm notification itself rings natively and lands on
/// `AlertActivity`), `stop` — reached only via engine acknowledgement —
/// cancels the notification and stops the service.
class _AndroidEngineSurface implements AlertSurfacePort {
  _AndroidEngineSurface({
    required this.scheduler,
    required this.occurrences,
    required this.onRing,
    required this.onStop,
  });

  final AndroidAlertScheduler scheduler;
  final List<EventOccurrence> Function() occurrences;
  final void Function(RingingAlarm alarm) onRing;
  final void Function(String alarmId) onStop;

  @override
  void ring(
    AlertTrigger trigger, {
    required List<AcknowledgementAction> actions,
  }) {
    EventOccurrence? occurrence;
    for (final candidate in occurrences()) {
      if (candidate.id == trigger.occurrenceId) {
        occurrence = candidate;
        break;
      }
    }
    final title = occurrence?.title ?? 'Meeting alert';
    onRing(RingingAlarm(
      alarmId: trigger.alarmId,
      occurrenceId: trigger.occurrenceId,
      startUtc: occurrence?.startUtc ?? trigger.instant,
      title: title,
      accent: trigger.lead.profile.accent,
      joinInfo: occurrence?.joinInfo,
    ));
    unawaited(scheduler.startRinging(
      alarmId: trigger.alarmId,
      title: title,
      body: 'Your meeting needs you. Acknowledge to stop the alarm.',
    ));
  }

  @override
  void escalate(String alarmId, EscalationStep step) {
    // The alarm notification is a native, ongoing full-screen alert; audio
    // and screen-wake are native. The engine's escalation cadence only needs
    // the process to stay alive, which the ringing service guarantees.
  }

  @override
  void stop(String alarmId) {
    onStop(alarmId);
    unawaited(scheduler.acknowledge(alarmId));
  }
}

/// The Android resilience layer: restores the engine, re-plans the OS alarm
/// cache after a boot and evaluates the capability ladder. Null on every
/// other platform. `AlertEngine.restore` on Android runs through this so the
/// engine is a single shared instance.
final androidResilienceProvider =
    FutureProvider<AndroidResilience?>((ref) async {
  if (!appIsAndroid) {
    return null;
  }
  return AndroidResilience.restore(
    scheduler: ref.watch(androidAlertSchedulerProvider),
    surface: ref.watch(alertSurfaceProvider),
    persistence: ref.watch(alertPersistencePortProvider),
    presence: EnginePresence.active,
    probe: FlutterNotificationCapabilityProbe(),
    bootFlag: SharedPreferencesBootRescheduleFlag(),
  );
});

/// The single [AlertEngine] of the app, restored from the persisted pending
/// set (absolute UTC instants survive a restart) and wired so the surface's
/// acknowledgements stop alerts through the engine — the only path that ends
/// a ringing alert.
final alertEngineProvider = FutureProvider<AlertEngine>((ref) async {
  final resilience = await ref.watch(androidResilienceProvider.future);
  if (resilience != null) {
    return resilience.engine;
  }

  final scheduler = ref.watch(alertSchedulerPortProvider);
  final surface = ref.watch(alertSurfaceProvider);
  final persistence = ref.watch(alertPersistencePortProvider);
  final engine = await AlertEngine.restore(
    scheduler: scheduler,
    surface: surface,
    persistence: persistence,
    presence: EnginePresence.active,
  );
  if (surface is AlertSurface) {
    surface.setOnAcknowledgement(engine.acknowledge);
  }
  return engine;
});

/// The latest Android capability report (exact alarms, full-screen intent,
/// notifications), filled by the bootstrapper on Android.
final androidCapabilityReportProvider =
    NotifierProvider<AndroidCapabilityReportNotifier, AndroidResilienceReport?>(
        AndroidCapabilityReportNotifier.new);

/// Holds the latest [AndroidResilienceReport].
class AndroidCapabilityReportNotifier extends Notifier<AndroidResilienceReport?> {
  @override
  AndroidResilienceReport? build() => null;

  /// Publishes a freshly evaluated report.
  void update(AndroidResilienceReport report) => state = report;
}

// ---------------------------------------------------------------------------
// Presence + deferral
// ---------------------------------------------------------------------------

/// The presence service over the platform's real mechanism (created through
/// `presence_factory.dart`, which reports `supported=false` where no
/// mechanism exists). Tests override this with a [FakePresenceService].
final presenceServiceProvider =
    Provider<PresenceService>((ref) => StreamPresenceService(
          platform: createPresencePlatform(),
        ));

/// Wires the presence stream into the engine: locked/away defers due alerts,
/// returning fires them; an unlock also runs the wake processing.
final deferralCoordinatorProvider =
    FutureProvider<DeferralCoordinator>((ref) async {
  final engine = await ref.watch(alertEngineProvider.future);
  return DeferralCoordinator(
    presence: ref.watch(presenceServiceProvider),
    engine: engine,
    now: ref.watch(clockProvider),
  );
});

/// The latest derived [PresenceState] for the diagnostics surface.
final latestPresenceProvider =
    NotifierProvider<LatestPresenceNotifier, PresenceState>(LatestPresenceNotifier.new);

/// Mirrors the presence stream into provider state.
class LatestPresenceNotifier extends Notifier<PresenceState> {
  @override
  PresenceState build() {
    final service = ref.watch(presenceServiceProvider);
    final subscription = service.states().listen((state) => this.state = state);
    ref.onDispose(subscription.cancel);
    // Neutral placeholder until the mechanism reports: nothing is asserted
    // about the user before a real sample arrives.
    return const PresenceState(
      locked: false,
      idleFor: Duration.zero,
      active: true,
    );
  }
}

// ---------------------------------------------------------------------------
// Heartbeat
// ---------------------------------------------------------------------------

/// Kill-switch for the engine heartbeat (tests set this to false so no
/// periodic timers outlive a widget test).
final heartbeatEnabledProvider = Provider<bool>((ref) => true);

/// Drives the engine heartbeat: a periodic timer at the engine's
/// [AlertEngine.recommendedHeartbeat] cadence, re-armed whenever the engine
/// (or its pending set) changes. Only runs while [heartbeatEnabledProvider]
/// is true.
final heartbeatProvider =
    NotifierProvider<HeartbeatNotifier, void>(HeartbeatNotifier.new);

/// Owns the engine heartbeat timer.
class HeartbeatNotifier extends Notifier<void> {
  Timer? _timer;

  @override
  void build() {
    final enabled = ref.watch(heartbeatEnabledProvider);
    if (!enabled) {
      return;
    }
    final engineSub = ref.listen(alertEngineProvider, (previous, next) {
      _sync(next.value);
    });
    ref.onDispose(() {
      engineSub.close();
      _timer?.cancel();
    });
    _sync(ref.read(alertEngineProvider).value);
  }

  void _sync(AlertEngine? engine) {
    _timer?.cancel();
    _timer = null;
    final period = engine?.recommendedHeartbeat;
    if (engine == null || period == null) {
      return;
    }
    final clock = ref.read(clockProvider);
    _timer = Timer.periodic(period, (_) {
      ref.read(alertEngineProvider).value?.onTick(clock());
    });
  }
}

// ---------------------------------------------------------------------------
// Desktop tray + autostart
// ---------------------------------------------------------------------------

/// The `GlobalKey<NavigatorState>` the tray "Settings" action (and any
/// non-widget navigation) pushes routes through.
final navigatorKeyProvider =
    Provider<GlobalKey<NavigatorState>>((ref) => GlobalKey<NavigatorState>());

/// The real tray backend on desktop, null everywhere else.
final trayPlatformProvider =
    Provider<TrayPlatform?>((ref) => appIsDesktop ? TrayManagerTrayPlatform() : null);

/// The tray controller on desktop (resident-mode policy + menu routing),
/// null everywhere else. Closing the main window hides it; Quit is the only
/// exit.
final trayControllerProvider = Provider<TrayController?>((ref) {
  final platform = ref.watch(trayPlatformProvider);
  if (platform == null) {
    return null;
  }
  return TrayController(
    actions: TrayActions(
      onOpenToday: () async {
        await windowManager.show();
        await windowManager.focus();
      },
      onTestAlert: () =>
          ref.read(testAlertControllerProvider.notifier).fire(),
      onOpenSettings: () async {
        final navigator = ref.read(navigatorKeyProvider).currentState;
        if (navigator != null) {
          unawaited(navigator.pushNamed(SettingsRoute.path));
        }
      },
      onHideMainWindow: () => windowManager.hide(),
      onQuit: () async {
        await windowManager.destroy();
        // The explicit quit is the only process-exit path.
        exit(0);
      },
    ),
  );
});

/// The autostart controller on desktop, null everywhere else. Constructed
/// lazily (and only read by desktop bootstrapping / settings), so tests
/// never instantiate the `launch_at_startup` plugin.
final autostartControllerProvider = Provider<AutostartController?>((ref) {
  if (!appIsDesktop) {
    return null;
  }
  return AutostartController(platform: LaunchAtStartupAutostartPlatform());
});

// ---------------------------------------------------------------------------
// Bootstrapping
// ---------------------------------------------------------------------------

/// Runs the one-shot app-start side effects: presence + deferral start,
/// platform scheduler/resilience initialisation, tray/autostart application.
/// Watched once by the app root; tests override it with a no-op.
final bootstrapperProvider =
    NotifierProvider<AppBootstrapper, void>(AppBootstrapper.new);

/// Owns the app-start side effects.
class AppBootstrapper extends Notifier<void> {
  bool _trayInitialized = false;

  @override
  void build() {
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      await _startDeferral();
      if (appIsAndroid) {
        await _bootstrapAndroid();
      } else if (appIsDesktop) {
        await _bootstrapDesktop();
      }
    } catch (error, stackTrace) {
      // A failed bootstrap must never prevent the UI from rendering; the
      // diagnostics surface exposes the resulting degraded state.
      debugPrint('app bootstrap failed: $error\n$stackTrace');
    }
  }

  Future<void> _startDeferral() async {
    final coordinator = await ref.read(deferralCoordinatorProvider.future);
    final extrasSub = ref.listen(settingsExtrasProvider, (previous, next) {
      coordinator.quietWhenAwayThreshold =
          Duration(minutes: next.quietWhenAwayMinutes);
      coordinator.alertEvenWhileLockedOrAway = next.alertWhileLockedOrAway;
      unawaited(_applySystemIntegration(next));
    });
    ref.onDispose(extrasSub.close);
    final extras = ref.read(settingsExtrasProvider);
    coordinator.quietWhenAwayThreshold =
        Duration(minutes: extras.quietWhenAwayMinutes);
    coordinator.alertEvenWhileLockedOrAway = extras.alertWhileLockedOrAway;
    await coordinator.start();
  }

  Future<void> _bootstrapAndroid() async {
    final scheduler = ref.read(androidAlertSchedulerProvider);
    await scheduler.initialize();
    final resilience = await ref.read(androidResilienceProvider.future);
    if (resilience == null) {
      return;
    }
    final now = ref.read(clockProvider)();
    // A boot discards the OS alarm cache: re-arm the persisted triggers.
    await resilience.rescheduleAfterBootIfNeeded(now);
    final report = await resilience.evaluateCapabilities();
    ref.read(androidCapabilityReportProvider.notifier).update(report);
  }

  Future<void> _bootstrapDesktop() async {
    await windowManager.ensureInitialized();
    final listener = _AppWindowListener(() {
      unawaited(ref.read(trayControllerProvider)?.handleMainWindowClose());
    });
    windowManager.addListener(listener);
    ref.onDispose(() => windowManager.removeListener(listener));
    await windowManager.waitUntilReadyToShow();
    await windowManager.show();

    final extras = ref.read(settingsExtrasProvider);
    await _applySystemIntegration(extras);
  }

  /// Applies the tray/autostart extras to the OS. A tray that was disposed
  /// (disabled) cannot be re-initialised in this process — re-enabling takes
  /// effect on the next start; autostart is applied on every change.
  Future<void> _applySystemIntegration(SettingsExtras extras) async {
    final autostart = ref.read(autostartControllerProvider);
    if (autostart != null) {
      await autostart.setEnabled(extras.autostartEnabled);
    }
    final tray = ref.read(trayControllerProvider);
    final platform = ref.read(trayPlatformProvider);
    if (tray == null || platform == null) {
      return;
    }
    if (extras.trayEnabled && !_trayInitialized) {
      await tray.initialize(platform);
      _trayInitialized = true;
    } else if (!extras.trayEnabled &&
        _trayInitialized &&
        tray.state.status == TrayAvailabilityStatus.available) {
      await tray.dispose();
    }
  }
}

/// Forwards the main-window close attempt to the tray's resident policy.
class _AppWindowListener with WindowListener {
  _AppWindowListener(this._onClose);

  final void Function() _onClose;

  @override
  void onWindowClose() => _onClose();
}

// ---------------------------------------------------------------------------
// External actions
// ---------------------------------------------------------------------------

/// Opens a join URL in the system browser on desktop. On Android there is no
/// `url_launcher` dependency yet — the URL is logged until the native
/// open-browser channel lands.
Future<void> _openUrl(String url) async {
  final List<String> command;
  if (appIsMacOS) {
    command = ['open', url];
  } else if (defaultTargetPlatform == TargetPlatform.linux) {
    command = ['xdg-open', url];
  } else if (defaultTargetPlatform == TargetPlatform.windows) {
    command = ['cmd', '/c', 'start', '', url];
  } else {
    debugPrint('join URLs cannot be opened on this platform yet: $url');
    return;
  }
  await Process.start(command.first, command.sublist(1),
      mode: ProcessStartMode.detached);
}

/// The `onJoinMeeting` action for the agenda.
final openUrlProvider =
    Provider<void Function(String url)>((ref) => _openUrl);

/// Executes the end-to-end test alert (usable from widgets and from
/// non-widget callers like the tray, since [WidgetRef] and [Ref] are not
/// interchangeable in riverpod 3).
final testAlertControllerProvider =
    NotifierProvider<TestAlertController, void>(TestAlertController.new);

/// Fires a real end-to-end test alert through the engine: a synthetic
/// occurrence starting a few seconds from now is planned with a zero lead
/// time and fired on the next tick, so the real surface rings and only
/// explicit acknowledgement stops it. A later agenda re-plan retires the
/// synthetic occurrence unless it is still ringing.
class TestAlertController extends Notifier<void> {
  @override
  void build() {}

  /// Fires the test alert.
  Future<void> fire() async {
    final engine = await ref.read(alertEngineProvider.future);
    final policy = ref.read(alertPolicyProvider);
    final clock = ref.read(clockProvider);
    final now = clock();
    final start = now.add(const Duration(seconds: 5));
    final agenda = ref.read(agendaStateProvider).value?.occurrences ??
        const <EventOccurrence>[];
    engine.plan(
      [
        for (final occurrence in agenda) _AlertOccurrenceAdapter(occurrence),
        _TestAlertOccurrence(
          start: start,
          end: start.add(const Duration(minutes: 30)),
        ),
      ],
      policy,
      now,
    );
    engine.onTick(now.add(const Duration(seconds: 6)));
  }
}

/// Adapter from the data-model occurrence to the engine's minimal view.
class _AlertOccurrenceAdapter implements AlertOccurrence {
  const _AlertOccurrenceAdapter(this.occurrence);

  final EventOccurrence occurrence;

  @override
  String get id => occurrence.id;

  @override
  DateTime get startUtc => occurrence.startUtc;

  @override
  DateTime get endUtc => occurrence.endUtc;

  @override
  List<AlertLeadTime>? get leadTimesOverride => null;

  @override
  bool get hasJoinAction => occurrence.joinInfo != null;
}

/// The synthetic occurrence behind the test alert.
class _TestAlertOccurrence implements AlertOccurrence {
  const _TestAlertOccurrence({required this.start, required this.end});

  final DateTime start;
  final DateTime end;

  static const List<AlertLeadTime> _leadTimes = [
    AlertLeadTime(Duration.zero, _urgentProfile),
  ];

  @override
  String get id => 'test-alert';

  @override
  DateTime get startUtc => start;

  @override
  DateTime get endUtc => end;

  @override
  List<AlertLeadTime>? get leadTimesOverride => _leadTimes;

  @override
  bool get hasJoinAction => false;
}

// ---------------------------------------------------------------------------
// Onboarding actions
// ---------------------------------------------------------------------------

/// Connect / permission / finish actions shared by the wizard and the
/// settings screen.
final onboardingControllerProvider =
    NotifierProvider<OnboardingController, void>(OnboardingController.new);

/// Executes the wizard and settings connect flows.
class OnboardingController extends Notifier<void> {
  @override
  void build() {}

  /// Stores the Google client id and runs the interactive OAuth flow
  /// (desktop only — on Android, Google calendars arrive via
  /// CalendarContract).
  Future<void> connectGoogle(String clientId) async {
    final settings = ref.read(settingsProvider).value;
    if (settings == null) {
      return;
    }
    await ref
        .read(settingsProvider.notifier)
        .save(settings.copyWith(googleClientId: clientId));
    if (!appIsAndroid) {
      try {
        final registry = await ref.read(registryProvider.future);
        final source = registry.lookup('google:primary');
        if (source is GoogleCalendarSource) {
          await source.authenticate();
        }
      } catch (error) {
        debugPrint('google connect failed: $error');
      }
    }
    ref.read(registryRevisionProvider.notifier).bump();
  }

  /// Persists an ICS feed URL (as a secret: it may embed a bearer parameter)
  /// and re-registers the source.
  Future<void> addIcsUrl(String url) async {
    await ref.read(secretStoreProvider).saveIcsBearerUrl(url);
    final extras = ref.read(settingsExtrasProvider);
    ref
        .read(settingsExtrasProvider.notifier)
        .update(extras.copyWith(icsUrl: url));
    ref.read(registryRevisionProvider.notifier).bump();
  }

  /// Requests calendar permission for [sourceId] in context (never at app
  /// start).
  Future<void> requestPermission(String sourceId) async {
    try {
      final registry = await ref.read(registryProvider.future);
      final source = registry.lookup(sourceId);
      if (source is EventKitSource) {
        await source.requestFullAccess();
      } else if (source is CalendarContractSource) {
        await source.requestPermission();
      }
    } catch (error) {
      debugPrint('permission request failed: $error');
    }
    ref.read(registryRevisionProvider.notifier).bump();
  }

  /// Directs the user to the system privacy settings for a denied source.
  Future<void> openSystemSettings(String sourceId) async {
    try {
      final registry = await ref.read(registryProvider.future);
      final source = registry.lookup(sourceId);
      if (source is EventKitSource) {
        await source.openSystemSettings();
      }
      // Android CalendarContract: the system app-settings deep link needs a
      // native channel (pending native todo); nothing to do here yet.
    } catch (error) {
      debugPrint('open system settings failed: $error');
    }
  }

  /// Completes onboarding: force a registry re-evaluation so the home route
  /// flips from the wizard to the agenda.
  Future<void> finish() async {
    ref.read(registryRevisionProvider.notifier).bump();
  }

  /// Sends the end-to-end test alert.
  Future<void> testAlert() => ref.read(testAlertControllerProvider.notifier).fire();
}

// ---------------------------------------------------------------------------
// Wizard statuses
// ---------------------------------------------------------------------------

/// The wizard's per-source setup statuses, computed from the live registry
/// (permission probes included, so a denied grant shows "Open Settings").
final wizardSourcesProvider =
    FutureProvider<List<WizardCalendarSource>>((ref) async {
  final registry = await ref.watch(registryProvider.future);
  final secrets = ref.watch(secretStoreProvider);

  final sources = <WizardCalendarSource>[];
  for (final source in registry.all) {
    final WizardSourceStatus status;
    if (source is EventKitSource) {
      status = await _eventKitStatus(source);
    } else if (source is CalendarContractSource) {
      status = await source.hasPermission()
          ? const WizardSourceStatus.connected()
          : const WizardSourceStatus.needsPermission();
    } else if (source is GoogleCalendarSource) {
      status = await secrets.readAccessToken() != null
          ? const WizardSourceStatus.connected()
          : const WizardSourceStatus.notConfigured();
    } else {
      // ICS: configured by construction (the registry only holds one once a
      // feed URL exists).
      status = const WizardSourceStatus.connected();
    }
    sources.add(WizardCalendarSource(
      id: source.id,
      displayName: source.displayName,
      status: status,
    ));
  }
  return sources;
});

Future<WizardSourceStatus> _eventKitStatus(EventKitSource source) async {
  try {
    final authorization = await source.checkAuthorization();
    return switch (authorization) {
      EventKitAuthorization.granted => const WizardSourceStatus.connected(),
      EventKitAuthorization.notDetermined =>
        const WizardSourceStatus.needsPermission(),
      EventKitAuthorization.denied ||
      EventKitAuthorization.restricted ||
      EventKitAuthorization.writeOnly =>
        const WizardSourceStatus.permissionDenied(),
      _ => const WizardSourceStatus.error('EventKit unavailable'),
    };
  } on SourcePermissionDeniedException catch (error) {
    return WizardSourceStatus.error(error.toString());
  }
}

// ---------------------------------------------------------------------------
// Diagnostics state
// ---------------------------------------------------------------------------

/// Capability statuses for the diagnostics surface (Android capability
/// ladder; empty on desktop where no OS alarm capability exists yet).
final diagnosticsCapabilitiesProvider =
    Provider<Map<String, diagnostics.Capability>>((ref) {
  final report = ref.watch(androidCapabilityReportProvider);
  if (report == null) {
    return const {};
  }
  return {
    for (final status in report.capabilities)
      status.capability.name: diagnostics.Capability(
        status.granted == true
            ? diagnostics.CapabilityStatus.ok
            : diagnostics.CapabilityStatus.degraded,
        status.granted == true ? null : status.explanation,
      ),
  };
});

diagnostics.SourceDiagnostics _sourceDiagnostics(SourceStatus status) =>
    switch (status.kind) {
      SourceStatusKind.error => diagnostics.SourceDiagnostics(
          diagnostics.SourceStatus.unavailable,
          status.reason,
        ),
      SourceStatusKind.permissionDenied => diagnostics.SourceDiagnostics(
          diagnostics.SourceStatus.degraded,
          status.reason ?? 'permission denied',
        ),
      SourceStatusKind.refreshing || SourceStatusKind.idle =>
        const diagnostics.SourceDiagnostics(diagnostics.SourceStatus.ok),
    };

// ---------------------------------------------------------------------------
// UI: routes + home
// ---------------------------------------------------------------------------

/// The floating Settings entry point overlaying the home screens (the
/// agenda and wizard screens own their app bars; the composition root owns
/// the global navigation affordances).
class HomeHost extends StatelessWidget {
  const HomeHost({super.key, required this.child});

  /// The screen to host (agenda or onboarding wizard).
  final Widget child;

  /// Test/accessibility key of the Settings button.
  static const Key settingsButtonKey = ValueKey('app-settings-button');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: child,
      floatingActionButton: FloatingActionButton(
        key: settingsButtonKey,
        tooltip: 'Settings',
        onPressed: () =>
            Navigator.of(context).pushNamed(SettingsRoute.path),
        child: const Icon(Icons.settings_outlined),
      ),
    );
  }
}

/// The home route: the onboarding wizard while no calendar source is
/// configured, otherwise the today-first agenda.
class HomeRouter extends ConsumerWidget {
  const HomeRouter({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final registry = ref.watch(registryProvider);
    final agenda = ref.watch(agendaStateProvider);
    final settings = ref.watch(settingsProvider);
    final timezone = ref.watch(localTimezoneProvider);

    final registryReady = registry.value;
    final settingsReady = settings.value;
    final timezoneReady = timezone.value;
    if (registryReady == null || settingsReady == null || timezoneReady == null) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(key: ValueKey('app-loading')),
        ),
      );
    }

    if (registryReady.enabledSources.isEmpty) {
      final wizardSources = ref.watch(wizardSourcesProvider);
      return HomeHost(
        child: wizardSources.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(child: Text('Failed to load sources: $error')),
          data: (sources) => _buildWizard(ref, sources),
        ),
      );
    }

    return HomeHost(
      child: agenda.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => AgendaScreen(
          occurrences: const [],
          statuses: const {},
          sourceDisplayNames: _displayNames(registryReady),
          anySourcesEnabled: true,
          lastRefreshedAt: null,
          onRefresh: () => ref.read(agendaStateProvider.notifier).refreshNow(),
          clock: ref.read(clockProvider),
          timezone: timezoneReady,
          onJoinMeeting: ref.read(openUrlProvider),
        ),
        data: (state) => AgendaScreen(
          occurrences: state.occurrences,
          statuses: state.statuses,
          sourceDisplayNames: _displayNames(registryReady),
          anySourcesEnabled: registryReady.enabledSources.isNotEmpty,
          lastRefreshedAt: state.lastRefreshedAt,
          onRefresh: () => ref.read(agendaStateProvider.notifier).refreshNow(),
          clock: ref.read(clockProvider),
          timezone: timezoneReady,
          onJoinMeeting: ref.read(openUrlProvider),
        ),
      ),
    );
  }

  Widget _buildWizard(WidgetRef ref, List<WizardCalendarSource> sources) {
    return OnboardingWizard(
      sources: sources,
      onTestAlert: () => ref.read(onboardingControllerProvider.notifier).testAlert(),
      onFinish: () => ref.read(onboardingControllerProvider.notifier).finish(),
      onConnectGoogle: (clientId) => unawaited(
        ref.read(onboardingControllerProvider.notifier).connectGoogle(clientId),
      ),
      onAddIcsUrl: (url) => unawaited(
        ref.read(onboardingControllerProvider.notifier).addIcsUrl(url),
      ),
      onRequestPermission: (sourceId) => unawaited(
        ref.read(onboardingControllerProvider.notifier).requestPermission(sourceId),
      ),
      onOpenSettings: (sourceId) => unawaited(
        ref.read(onboardingControllerProvider.notifier).openSystemSettings(sourceId),
      ),
    );
  }

  static Map<String, String> _displayNames(CalendarSourceRegistry registry) => {
        for (final source in registry.all) source.id: source.displayName,
      };
}

/// The settings route: renders [SettingsScreen] over the live providers and
/// applies every change back into the stores and the OS integrations.
class SettingsRoute extends ConsumerWidget {
  const SettingsRoute({super.key});

  /// Route path (also used by the tray "Settings" action).
  static const String path = '/settings';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final extras = ref.watch(settingsExtrasProvider);
    final onboarding = ref.read(onboardingControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: settings.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Failed to load settings: $error')),
        data: (value) => SettingsScreen(
          settings: value,
          onSettingsChanged: (next) => unawaited(
            ref.read(settingsProvider.notifier).save(next),
          ),
          extras: extras,
          onExtrasChanged: (next) {
            ref.read(settingsExtrasProvider.notifier).update(next);
            unawaited(_applyExtras(ref, next));
          },
          onTestAlert: () =>
              unawaited(ref.read(testAlertControllerProvider.notifier).fire()),
          onGoogleConnect: (clientId) =>
              unawaited(onboarding.connectGoogle(clientId)),
          onGoogleDisconnect: () => unawaited(_disconnectGoogle(ref)),
          onIcsConnect: (url) => unawaited(onboarding.addIcsUrl(url)),
          onIcsDisconnect: () => unawaited(_disconnectIcs(ref)),
          onOpenDiagnostics: () => unawaited(
            Navigator.of(context).pushNamed(DiagnosticsRoute.path),
          ),
        ),
      ),
    );
  }

  /// Applies the tray/autostart extras to the OS after a settings change.
  Future<void> _applyExtras(WidgetRef ref, SettingsExtras extras) async {
    final autostart = ref.read(autostartControllerProvider);
    if (autostart != null) {
      await autostart.setEnabled(extras.autostartEnabled);
    }
    final tray = ref.read(trayControllerProvider);
    final platform = ref.read(trayPlatformProvider);
    if (tray == null || platform == null) {
      return;
    }
    if (extras.trayEnabled &&
        tray.state.status == TrayAvailabilityStatus.initializing) {
      await tray.initialize(platform);
    } else if (!extras.trayEnabled &&
        tray.state.status == TrayAvailabilityStatus.available) {
      await tray.dispose();
    }
  }

  Future<void> _disconnectGoogle(WidgetRef ref) async {
    await ref.read(secretStoreProvider).clearAuth();
    ref.read(registryRevisionProvider.notifier).bump();
  }

  Future<void> _disconnectIcs(WidgetRef ref) async {
    await ref.read(secretStoreProvider).saveIcsBearerUrl(null);
    ref.read(registryRevisionProvider.notifier).bump();
  }
}

/// The diagnostics route: a live snapshot of the engine's departure records,
/// per-source statuses, presence, capabilities and the next trigger.
class DiagnosticsRoute extends ConsumerWidget {
  const DiagnosticsRoute({super.key});

  /// Route path.
  static const String path = '/diagnostics';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = ref.watch(alertEngineProvider).value;
    final agenda = ref.watch(agendaStateProvider).value;
    final registry = ref.watch(registryProvider).value;
    final pending = engine?.pendingTriggers ?? const <AlertTrigger>[];

    final sources = <String, diagnostics.SourceDiagnostics>{
      for (final entry in agenda?.statuses.entries ??
          const <MapEntry<String, SourceStatus>>[])
        registry?.lookup(entry.key)?.displayName ?? entry.key:
            _sourceDiagnostics(entry.value),
    };

    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostics')),
      body: diagnostics.DiagnosticsView(
        records: engine?.records ?? const <AlertEngineRecord>[],
        sources: sources,
        presence: ref.watch(latestPresenceProvider),
        capabilities: ref.watch(diagnosticsCapabilitiesProvider),
        nextTrigger: pending.isEmpty ? null : pending.first.instant,
        onCopyReport: (report) =>
            unawaited(Clipboard.setData(ClipboardData(text: report))),
        now: ref.watch(clockProvider)(),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Android ringing surface (AlertActivity)
// ---------------------------------------------------------------------------

/// Boots the full-screen ringing content for the Android `AlertActivity`.
///
/// The activity runs its own isolate, so this builds a fresh provider
/// container. The currently ringing alert comes from [ringingAlarmProvider]
/// when this isolate fired it, or — after a process restart — from the
/// persisted pending set (a `fired` record without a later `acknowledged`).
/// Reading the intent payload from `AlertActivity.alertPayload` needs the
/// native channel of the alert-activity todo; the persisted fallback covers
/// the restart case today.
class RingingAlertActivityRoot extends ConsumerWidget {
  const RingingAlertActivityRoot({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alarm = ref.watch(ringingAlarmProvider) ?? _restoredRinging(ref);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: alarm == null
          ? const Scaffold(body: Center(child: Text('No active alert')))
          : RingingAlertView(
              title: alarm.title,
              startUtc: alarm.startUtc,
              nowUtc: ref.watch(clockProvider)(),
              joinInfo: alarm.joinInfo,
              accent: alarm.accent,
              onAcknowledgement: (action) {
                ref
                    .watch(alertEngineProvider)
                    .value
                    ?.acknowledge(alarm.alarmId);
              },
            ),
    );
  }

  /// Derives the alert still ringing after a restart from the persisted
  /// records: the last `fired` departure without a later `acknowledged`.
  RingingAlarm? _restoredRinging(WidgetRef ref) {
    final engine = ref.watch(alertEngineProvider).value;
    if (engine == null) {
      return null;
    }
    final acknowledged = <String>{};
    AlertEngineRecord? fired;
    for (final record in engine.records) {
      switch (record.reason) {
        case AlertRecordReason.fired:
          fired = record;
        case AlertRecordReason.acknowledged:
          acknowledged.add(record.alarmId);
        case AlertRecordReason.deferredLocked ||
              AlertRecordReason.deferredAway ||
              AlertRecordReason.meetingEnded ||
              AlertRecordReason.occurrenceRemoved:
          break;
      }
    }
    if (fired == null || acknowledged.contains(fired.alarmId)) {
      return null;
    }
    AlertTrigger? trigger;
    for (final pending in engine.pendingTriggers) {
      if (pending.alarmId == fired.alarmId) {
        trigger = pending;
        break;
      }
    }
    if (trigger == null) {
      return null;
    }
    final occurrence = ref
        .watch(agendaStateProvider)
        .value
        ?.occurrences
        .where((o) => o.id == trigger!.occurrenceId)
        .firstOrNull;
    return RingingAlarm(
      alarmId: trigger.alarmId,
      occurrenceId: trigger.occurrenceId,
      startUtc: trigger.instant,
      title: occurrence?.title ?? 'Meeting alert',
      accent: trigger.lead.profile.accent,
      joinInfo: occurrence?.joinInfo,
    );
  }
}

/// Boots the `AlertActivity` ringing surface as its own app root.
Future<void> runRingingAlertActivity() async {
  WidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  runApp(const ProviderScope(child: RingingAlertActivityRoot()));
}
