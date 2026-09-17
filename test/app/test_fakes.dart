/// Shared fakes for the composition-root smoke tests: everything the app
/// touches that would hit a plugin, a native channel or real IO is
/// substituted here, so the composed app boots under `flutter test` with
/// only in-memory, pure-Dart doubles.
library;

import 'dart:io';

import 'package:attention_copilot/alert/alert_surface.dart';
import 'package:attention_copilot/app/composition_root.dart';
import 'package:attention_copilot/data/sources/registry.dart';
import 'package:attention_copilot/data/sources/source.dart';
import 'package:attention_copilot/data/storage/agenda_cache.dart';
import 'package:attention_copilot/data/storage/secret_store.dart';
import 'package:attention_copilot/data/storage/settings_store.dart';
import 'package:attention_copilot/domain/alert_engine.dart';
import 'package:attention_copilot/domain/models/calendar_event.dart';
import 'package:attention_copilot/domain/models/calendar_source_id.dart';
import 'package:attention_copilot/domain/models/event_occurrence.dart';
import 'package:attention_copilot/presence/presence_service.dart';
import 'package:attention_copilot/ui/onboarding_wizard.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

/// The fixed "now" every clock in the smoke tests reads.
final DateTime fixedNow = DateTime.utc(2026, 9, 17, 10, 0, 0);

/// In-memory settings store (never touches shared_preferences).
class MemorySettingsStore extends SettingsStore {
  MemorySettingsStore([AppSettings? initial])
      : _current = initial ?? AppSettings.defaults(),
        super(prefsProvider: _neverCalledPrefs);

  AppSettings _current;

  static Future<SharedPreferences> _neverCalledPrefs() async =>
      throw UnsupportedError('memory settings store: prefs never used');

  /// The document that would be persisted right now.
  AppSettings get current => _current;

  @override
  Future<SettingsLoadResult> load() async => SettingsLoadResult(_current, null);

  @override
  Future<void> save(AppSettings settings) async => _current = settings;
}

/// In-memory secret backend (never touches the platform keychain).
class MemorySecretBackend implements SecureKeyValueBackend {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// In-memory agenda cache (never touches the file system).
class MemoryAgendaCache extends AgendaCache {
  MemoryAgendaCache() : super(directoryProvider: _NeverUsedDirectory());

  AgendaCacheData data = const AgendaCacheData.empty();

  @override
  Future<CacheLoadResult> load() async => CacheLoadResult(data, null);

  @override
  Future<void> save(AgendaCacheData value) async => data = value;
}

class _NeverUsedDirectory implements CacheDirectoryProvider {
  @override
  Future<Directory> getDirectory() async =>
      throw UnsupportedError('memory agenda cache: directory never used');
}

/// Recording [AlertPersistencePort]: pure memory.
class MemoryEnginePersistence implements AlertPersistencePort {
  List<PendingTriggerRecord> records = [];

  @override
  Future<void> savePending(List<PendingTriggerRecord> value) async =>
      records = List.of(value);

  @override
  Future<List<PendingTriggerRecord>> loadPending() async => List.of(records);
}

/// Recording [AlertSchedulerPort].
class RecordingSchedulerPort implements AlertSchedulerPort {
  final Map<String, DateTime> scheduled = {};
  final List<String> cancelled = [];

  @override
  void schedule(DateTime instantUtc, String alarmId) =>
      scheduled[alarmId] = instantUtc;

  @override
  void cancel(String alarmId) => cancelled.add(alarmId);
}

/// A calendar source that returns one future meeting and a cursor, with no
/// platform calls.
class FakeAgendaSource extends CalendarSource {
  FakeAgendaSource({DateTime Function()? clock})
      : _clock = clock ?? (() => fixedNow);

  static const CalendarSourceId _sourceId = CalendarSourceId(
    id: 'fake:agenda',
    displayName: 'Fake agenda',
    priority: 0,
  );

  final DateTime Function() _clock;

  @override
  CalendarSourceId get sourceId => _sourceId;

  @override
  SourcePermissionState get permissionState => SourcePermissionState.granted;

  @override
  Future<SourceSnapshot> fetch(SourceCursor? cursor) async {
    final start = _clock().toUtc().add(const Duration(hours: 2));
    final end = start.add(const Duration(hours: 1));
    return SourceSnapshot(
      occurrences: [
        EventOccurrence(
          id: 'fake-occurrence-1',
          event: const CalendarEvent(
            id: 'fake-event',
            title: 'Smoke test meeting',
          ),
          source: _sourceId,
          startUtc: start,
          endUtc: end,
        ),
      ],
      nextCursor: const SourceCursor('fake-cursor'),
    );
  }
}

/// A bootstrapper that does nothing: the smoke tests boot the widget graph,
/// not the platform side effects.
class NoopBootstrapper extends AppBootstrapper {
  @override
  void build() {}
}

/// Everything the smoke test overrides, plus handles for asserting on the
/// wiring after the boot.
class SmokeHarness {
  SmokeHarness({required this.anySourceConfigured}) {
    final registry = CalendarSourceRegistry();
    if (anySourceConfigured) {
      registry.register(FakeAgendaSource(), enabled: true);
    }
    overrides = [
      clockProvider.overrideWithValue(() => fixedNow),
      localTimezoneProvider.overrideWith((ref) => tz.UTC),
      settingsStoreProvider.overrideWithValue(settingsStore),
      secretStoreProvider.overrideWithValue(
        SecretStore(backend: MemorySecretBackend()),
      ),
      agendaCacheProvider.overrideWithValue(agendaCache),
      registryProvider.overrideWith((ref) async => registry),
      wizardSourcesProvider.overrideWith(
        (ref) async => const [
          WizardCalendarSource(
            id: 'google:primary',
            displayName: 'Google Calendar',
            status: WizardSourceStatus.notConfigured(),
          ),
        ],
      ),
      presenceServiceProvider.overrideWithValue(presence),
      alertSchedulerPortProvider.overrideWithValue(scheduler),
      alertSurfaceProvider.overrideWithValue(surface),
      alertPersistencePortProvider.overrideWithValue(persistence),
      androidResilienceProvider.overrideWith((ref) async => null),
      bootstrapperProvider.overrideWith(NoopBootstrapper.new),
      heartbeatEnabledProvider.overrideWithValue(false),
      openUrlProvider.overrideWithValue(openedUrls.add),
    ];
  }

  /// Whether the fake registry has an enabled source (agenda path) or not
  /// (onboarding path).
  final bool anySourceConfigured;

  final MemorySettingsStore settingsStore = MemorySettingsStore();
  final MemoryAgendaCache agendaCache = MemoryAgendaCache();
  final MemoryEnginePersistence persistence = MemoryEnginePersistence();
  final RecordingSchedulerPort scheduler = RecordingSchedulerPort();
  final FakeAlertSurface surface = FakeAlertSurface();
  final FakePresenceService presence = FakePresenceService();
  final List<String> openedUrls = [];

  /// The provider overrides built from the fakes above.
  late final List<Override> overrides;
}
