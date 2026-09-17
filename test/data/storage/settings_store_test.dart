import 'dart:convert';

import 'package:attention_copilot/data/storage/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppSettings', () {
    test('toJson emits a JSON document with an explicit schemaVersion', () {
      const settings = AppSettings(
        schemaVersion: AppSettings.currentSchemaVersion,
        alertLeadMinutes: [10, 1],
        snoozeEnabled: false,
        googleClientId: '12345-example.apps.googleusercontent.com',
      );

      final json = settings.toJson();

      expect(json['schemaVersion'], AppSettings.currentSchemaVersion);
      expect(json['alertLeadMinutes'], [10, 1]);
      expect(json['snoozeEnabled'], isFalse);
      expect(json['googleClientId'], '12345-example.apps.googleusercontent.com');
    });

    test('fromJson preserves unknown future keys and they survive a rewrite',
        () {
      final doc = jsonDecode('''
      {
        "schemaVersion": 1,
        "alertLeadMinutes": [10, 1],
        "snoozeEnabled": false,
        "futureFeatureFlag": true,
        "futureNested": {"a": 1, "b": [2, 3]}
      }
      ''') as Map<String, dynamic>;

      final settings = AppSettings.fromJson(doc);

      expect(settings.unknown.containsKey('futureFeatureFlag'), isTrue);
      expect(settings.unknown['futureNested'], {'a': 1, 'b': [2, 3]});

      final rewritten = settings.toJson();
      expect(rewritten['futureFeatureFlag'], isTrue);
      expect(rewritten['futureNested'], {'a': 1, 'b': [2, 3]});
    });

    test('fromJson tolerates missing and malformed fields', () {
      final settings = AppSettings.fromJson({
        'schemaVersion': 1,
        'alertLeadMinutes': 'not-a-list',
      });

      expect(settings.alertLeadMinutes, AppSettings.defaults().alertLeadMinutes);
      expect(settings.snoozeEnabled, isFalse);
      expect(settings.googleClientId, isNull);
    });
  });

  group('SettingsStore', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('returns defaults when nothing has been saved yet', () async {
      final store = SettingsStore();

      final result = await store.load();

      expect(result.loadIssue, isNull);
      expect(result.settings.schemaVersion, AppSettings.currentSchemaVersion);
      expect(result.settings.alertLeadMinutes, [10, 1]);
      expect(result.settings.snoozeEnabled, isFalse);
    });

    test('round-trips a settings object through shared_preferences', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SettingsStore();

      await store.save(const AppSettings(
        schemaVersion: AppSettings.currentSchemaVersion,
        alertLeadMinutes: [30, 5],
        snoozeEnabled: true,
        googleClientId: 'abc.apps.googleusercontent.com',
      ));

      final result = await store.load();

      expect(result.loadIssue, isNull);
      expect(result.settings.alertLeadMinutes, [30, 5]);
      expect(result.settings.snoozeEnabled, isTrue);
      expect(result.settings.googleClientId,
          'abc.apps.googleusercontent.com');
    });

    test('unknown extra keys in the stored document are preserved on rewrite',
        () async {
      SharedPreferences.setMockInitialValues({
        SettingsStore.storageKey: jsonEncode({
          'schemaVersion': 1,
          'alertLeadMinutes': [15],
          'snoozeEnabled': false,
          'someFutureKey': 'keep-me',
        }),
      });
      final store = SettingsStore();

      final result = await store.load();
      expect(result.settings.alertLeadMinutes, [15]);

      await store.save(result.settings);

      final prefs = await SharedPreferences.getInstance();
      final rawOnDisk = prefs.getString(SettingsStore.storageKey)!;
      final decoded = jsonDecode(rawOnDisk) as Map<String, dynamic>;
      expect(decoded['someFutureKey'], 'keep-me');
      expect(decoded['alertLeadMinutes'], [15]);
      expect(decoded['schemaVersion'], AppSettings.currentSchemaVersion);
    });

    test('runs the migration hook when the stored schema is older', () async {
      SharedPreferences.setMockInitialValues({
        SettingsStore.storageKey: jsonEncode({
          // Version 0 document: the old field name `leadTimesMinutes`.
          'schemaVersion': 0,
          'leadTimesMinutes': [20, 2],
          'snoozeEnabled': false,
        }),
      });
      final store = SettingsStore(migrations: {
        1: (json) => {
              ...json,
              'alertLeadMinutes':
                  json['leadTimesMinutes'] ?? AppSettings.defaults().alertLeadMinutes,
            },
      });

      final result = await store.load();

      expect(result.loadIssue, isNull);
      expect(result.settings.alertLeadMinutes, [20, 2]);
      expect(result.settings.schemaVersion, AppSettings.currentSchemaVersion);
    });

    test('migrations that would overshoot are not run', () async {
      SharedPreferences.setMockInitialValues({
        SettingsStore.storageKey: jsonEncode({
          'schemaVersion': 99,
          'alertLeadMinutes': [10, 1],
        }),
      });
      var migrationRan = false;
      final store = SettingsStore(migrations: {
        100: (json) {
          migrationRan = true;
          return json;
        },
      });

      final result = await store.load();

      expect(result.settings.schemaVersion, AppSettings.currentSchemaVersion);
      expect(migrationRan, isFalse);
    });

    test('a corrupt settings document yields defaults plus a recorded reason',
        () async {
      SharedPreferences.setMockInitialValues({
        SettingsStore.storageKey: '{ this is not valid json',
      });
      final store = SettingsStore();

      final result = await store.load();

      expect(result.settings.alertLeadMinutes, [10, 1]);
      expect(result.loadIssue, 'corrupt-settings');
    });

    test('a JSON document that is not an object is treated as corrupt',
        () async {
      SharedPreferences.setMockInitialValues({
        SettingsStore.storageKey: '[1, 2, 3]',
      });
      final store = SettingsStore();

      final result = await store.load();

      expect(result.loadIssue, 'corrupt-settings');
    });
  });
}
