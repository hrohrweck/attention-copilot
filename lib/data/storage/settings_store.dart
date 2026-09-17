import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A migration takes the raw settings document and returns the next version
/// of it. Migrations are keyed by the schema version they produce: the
/// migration registered for version N upgrades a document from N-1 to N.
typedef SettingsMigration = Map<String, dynamic> Function(
    Map<String, dynamic> json);

/// Immutable, plain-data view of the persisted application settings.
///
/// The document schema is versioned: [schemaVersion] is written on every save
/// and used to decide which [SettingsMigration]s to run on load. Keys this
/// class does not know about are kept in [unknown] and written back verbatim,
/// so a document written by a newer app version survives a round-trip through
/// this one.
class AppSettings {
  static const int currentSchemaVersion = 1;

  /// Default alert lead times in minutes, ascending.
  static const List<int> defaultAlertLeadMinutes = [10, 1];

  const AppSettings({
    required this.schemaVersion,
    required this.alertLeadMinutes,
    required this.snoozeEnabled,
    required this.googleClientId,
    this.deviceCalendarsEnabled = false,
    this.enabledDeviceCalendarIds,
    this.unknown = const {},
  });

  /// Alert lead times in minutes, ascending, earliest last.
  final List<int> alertLeadMinutes;

  /// Whether the snooze action is offered at all (off by default).
  final bool snoozeEnabled;

  /// User-supplied OAuth 2.0 client ID ("bring your own client"). A client
  /// ID is a public identifier, not a secret, so it lives in plain settings.
  /// Tokens and bearer URLs must NOT be stored here - see SecretStore.
  final String? googleClientId;

  /// Whether the Android CalendarContract source ("use this device's
  /// calendars") is switched on. The READ_CALENDAR permission is only ever
  /// requested in context when the user flips this to true, never at app
  /// start.
  final bool deviceCalendarsEnabled;

  /// CalendarContract calendar ids the user enabled, or null when the user
  /// has not configured a selection yet (all visible calendars are used).
  final List<int>? enabledDeviceCalendarIds;

  /// Unknown top-level keys from the stored document, preserved on rewrite.
  final Map<String, dynamic> unknown;

  /// The schema version this object was deserialised from (or the current
  /// version when freshly created).
  final int schemaVersion;

  factory AppSettings.defaults() => const AppSettings(
        schemaVersion: currentSchemaVersion,
        alertLeadMinutes: defaultAlertLeadMinutes,
        snoozeEnabled: false,
        googleClientId: null,
        unknown: {},
      );

  /// Parses [json] tolerantly: missing or malformed fields fall back to the
  /// defaults, and every unrecognised key is preserved in [unknown].
  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      schemaVersion: currentSchemaVersion,
      alertLeadMinutes: _readIntList(json['alertLeadMinutes']) ??
          defaultAlertLeadMinutes,
      snoozeEnabled: json['snoozeEnabled'] is bool
          ? json['snoozeEnabled'] as bool
          : false,
      googleClientId: json['googleClientId'] is String
          ? json['googleClientId'] as String
          : null,
      deviceCalendarsEnabled: json['deviceCalendarsEnabled'] is bool
          ? json['deviceCalendarsEnabled'] as bool
          : false,
      enabledDeviceCalendarIds: _readIntList(json['enabledDeviceCalendarIds']),
      unknown: _unknownKeys(json),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      ...unknown,
      'schemaVersion': currentSchemaVersion,
      'alertLeadMinutes': alertLeadMinutes,
      'snoozeEnabled': snoozeEnabled,
      if (googleClientId != null) 'googleClientId': googleClientId,
      'deviceCalendarsEnabled': deviceCalendarsEnabled,
      if (enabledDeviceCalendarIds != null)
        'enabledDeviceCalendarIds': enabledDeviceCalendarIds,
    };
  }

  /// Returns a copy with the given fields replaced; omitted fields keep the
  /// current value.
  AppSettings copyWith({
    List<int>? alertLeadMinutes,
    bool? snoozeEnabled,
    String? googleClientId,
    bool? deviceCalendarsEnabled,
    List<int>? enabledDeviceCalendarIds,
  }) {
    return AppSettings(
      schemaVersion: schemaVersion,
      alertLeadMinutes: alertLeadMinutes ?? this.alertLeadMinutes,
      snoozeEnabled: snoozeEnabled ?? this.snoozeEnabled,
      googleClientId: googleClientId ?? this.googleClientId,
      deviceCalendarsEnabled:
          deviceCalendarsEnabled ?? this.deviceCalendarsEnabled,
      enabledDeviceCalendarIds:
          enabledDeviceCalendarIds ?? this.enabledDeviceCalendarIds,
      unknown: unknown,
    );
  }

  static List<int>? _readIntList(Object? value) {
    if (value is! List) return null;
    return List<int>.unmodifiable(
        value.whereType<int>());
  }

  static Map<String, dynamic> _unknownKeys(Map<String, dynamic> json) {
    const known = {
      'schemaVersion',
      'alertLeadMinutes',
      'snoozeEnabled',
      'googleClientId',
      'deviceCalendarsEnabled',
      'enabledDeviceCalendarIds',
    };
    return {
      for (final entry in json.entries)
        if (!known.contains(entry.key)) entry.key: entry.value,
    };
  }
}

/// Result of loading settings: [settings] is always usable, and [loadIssue]
/// carries a machine-readable reason when something had to be recovered
/// (e.g. `corrupt-settings`).
class SettingsLoadResult {
  const SettingsLoadResult(this.settings, this.loadIssue);

  final AppSettings settings;
  final String? loadIssue;
}

/// Versioned JSON settings document persisted over shared_preferences.
///
/// Secret material (OAuth tokens, ICS bearer URLs) must never go through this
/// store - it is plaintext. See SecretStore for secrets.
class SettingsStore {
  SettingsStore({
    Future<SharedPreferences> Function()? prefsProvider,
    this.migrations = const {},
  }) : _prefsProvider = prefsProvider ?? SharedPreferences.getInstance;

  /// Storage key used inside shared_preferences.
  static const String storageKey = 'attention_copilot.settings';

  /// Migrations keyed by the schema version they produce.
  final Map<int, SettingsMigration> migrations;

  final Future<SharedPreferences> Function() _prefsProvider;

  Future<SettingsLoadResult> load() async {
    final prefs = await _prefsProvider();
    final raw = prefs.getString(storageKey);
    if (raw == null) {
      return SettingsLoadResult(AppSettings.defaults(), null);
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return SettingsLoadResult(AppSettings.defaults(), 'corrupt-settings');
    }
    if (decoded is! Map<String, dynamic>) {
      return SettingsLoadResult(AppSettings.defaults(), 'corrupt-settings');
    }
    return SettingsLoadResult(
        AppSettings.fromJson(_applyMigrations(decoded)), null);
  }

  Map<String, dynamic> _applyMigrations(Map<String, dynamic> json) {
    var document = Map<String, dynamic>.of(json);
    final stored = document['schemaVersion'];
    var version = stored is int ? stored : 0;
    while (version < AppSettings.currentSchemaVersion) {
      final migration = migrations[version + 1];
      if (migration == null) {
        // No handler for the next step: stop instead of guessing.
        break;
      }
      document = Map<String, dynamic>.of(migration(document));
      version += 1;
    }
    return document;
  }

  Future<void> save(AppSettings settings) async {
    final prefs = await _prefsProvider();
    await prefs.setString(storageKey, jsonEncode(settings.toJson()));
  }
}
