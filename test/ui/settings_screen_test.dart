import 'package:attention_copilot/data/storage/settings_store.dart';
import 'package:attention_copilot/ui/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Test double that owns the current settings/extras and forwards the
/// widget's change callbacks into mutable fields so tests can assert on
/// what the screen would have persisted.
class SettingsHarness {
  SettingsHarness({
    required this.settings,
    this.extras = SettingsExtras.defaults,
  });

  AppSettings settings;
  SettingsExtras extras;

  int testAlertCalls = 0;
  String? previewedAudioSource;
  String? googleConnectId;
  int googleDisconnectCalls = 0;
  String? icsConnectUrl;
  int icsDisconnectCalls = 0;
  int diagnosticsCalls = 0;

  /// Makes the default test viewport tall enough that every row of the
  /// settings list is mounted without scrolling.
  static void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(900, 3400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> pump(WidgetTester tester) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsScreen(
            settings: settings,
            onSettingsChanged: (next) => settings = next,
            extras: extras,
            onExtrasChanged: (next) => extras = next,
            onTestAlert: () => testAlertCalls++,
            onPreviewAudio: (source) => previewedAudioSource = source,
            onGoogleConnect: (id) => googleConnectId = id,
            onGoogleDisconnect: () => googleDisconnectCalls++,
            onIcsConnect: (url) => icsConnectUrl = url,
            onIcsDisconnect: () => icsDisconnectCalls++,
            onOpenDiagnostics: () => diagnosticsCalls++,
          ),
        ),
      ),
    );
  }
}

void main() {
  group('lead-time validation', () {
    test('rejects duplicate lead times', () {
      expect(SettingsScreen.validateAlertLeadMinutes([10, 10]), isNotNull);
      expect(SettingsScreen.validateAlertLeadMinutes([1, 5, 1]), isNotNull);
    });

    test('rejects lead-time lists that are not longest-first', () {
      // Canonical order is longest lead time first, earliest alert last
      // (the persisted default is [10, 1]).
      expect(SettingsScreen.validateAlertLeadMinutes([1, 10]), isNotNull);
      expect(SettingsScreen.validateAlertLeadMinutes([5, 10, 1]), isNotNull);
    });

    test('accepts the canonical strictly-descending order', () {
      expect(SettingsScreen.validateAlertLeadMinutes([10, 1]), isNull);
      expect(SettingsScreen.validateAlertLeadMinutes([30, 5, 1]), isNull);
    });

    test('rejects non-positive lead-time additions', () {
      expect(SettingsScreen.validateLeadTimeAddition([10, 1], 0), isNotNull);
      expect(SettingsScreen.validateLeadTimeAddition([10, 1], -5), isNotNull);
    });

    test('rejects adding an already-present lead time', () {
      expect(SettingsScreen.validateLeadTimeAddition([10, 1], 10), isNotNull);
      expect(SettingsScreen.validateLeadTimeAddition([10, 1], 5), isNull);
    });
  });

  group('client id and ICS validation', () {
    test('google client ids must be *.apps.googleusercontent.com', () {
      expect(
        SettingsScreen.validateGoogleClientId(
            '1234-abcd.apps.googleusercontent.com'),
        isNull,
      );
      expect(SettingsScreen.validateGoogleClientId('not-a-client-id'),
          isNotNull);
      expect(SettingsScreen.validateGoogleClientId(''), isNotNull);
      expect(
        SettingsScreen.validateGoogleClientId('.apps.googleusercontent.com'),
        isNotNull,
      );
    });

    test('ics urls must be absolute http(s)/webcal/file urls', () {
      expect(SettingsScreen.validateIcsUrl('https://example.com/team.ics'),
          isNull);
      expect(SettingsScreen.validateIcsUrl('webcal://example.com/team.ics'),
          isNull);
      expect(SettingsScreen.validateIcsUrl('not a url'), isNotNull);
    });
  });

  testWidgets('Test Alert invokes the onTestAlert callback', (tester) async {
    SettingsHarness.useTallViewport(tester);
    final harness = SettingsHarness(settings: AppSettings.defaults());
    await harness.pump(tester);

    expect(harness.testAlertCalls, 0);
    await tester.tap(find.byKey(const Key('settings.testAlert')));
    await tester.pump();
    expect(harness.testAlertCalls, 1);
  });

  testWidgets('controls render current settings and extras values',
      (tester) async {
    SettingsHarness.useTallViewport(tester);
    final harness = SettingsHarness(
      settings: AppSettings(
        schemaVersion: AppSettings.currentSchemaVersion,
        alertLeadMinutes: const [30, 5],
        snoozeEnabled: true,
        googleClientId: 'client123.apps.googleusercontent.com',
        deviceCalendarsEnabled: true,
      ),
      extras: const SettingsExtras(
        repeatIntervalSeconds: 60,
        volumeRampEnabled: false,
        maxAlertDurationMinutes: 10,
        quietWhenAwayMinutes: 2,
        alertWhileLockedOrAway: true,
        audioSourceId: 'chime',
        icsUrl: 'https://example.com/team.ics',
        macCalendarsEnabled: true,
        trayEnabled: false,
        residentEnabled: true,
        autostartEnabled: true,
      ),
    );
    await harness.pump(tester);

    // (a) lead times render in canonical order
    expect(find.text('30 minutes before'), findsOneWidget);
    expect(find.text('5 minutes before'), findsOneWidget);
    expect(find.text('10 minutes before'), findsNothing);

    // (b) escalation settings
    expect(find.text('Repeat: 60 s'), findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const Key('settings.volumeRamp')))
          .value,
      isFalse,
    );
    expect(find.text('Stop after 10 min'), findsOneWidget);

    // (c) quiet-when-away threshold + override
    expect(find.text('After 2 min away'), findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(
              find.byKey(const Key('settings.alertWhileLocked')))
          .value,
      isTrue,
    );

    // (d) snooze reflects the stored setting
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const Key('settings.snoozeSwitch')))
          .value,
      isTrue,
    );

    // (e) audio source selection
    expect(find.text('Chime'), findsOneWidget);

    // (f) per-source config: Google connected, ICS configured, native toggles
    expect(find.byKey(const Key('settings.googleDisconnect')), findsOneWidget);
    expect(find.byKey(const Key('settings.googleConnect')), findsNothing);
    expect(find.textContaining('client123.apps.googleusercontent.com'),
        findsOneWidget);
    expect(find.byKey(const Key('settings.icsDisconnect')), findsOneWidget);
    expect(find.text('https://example.com/team.ics'), findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(
              find.byKey(const Key('settings.macCalendars')))
          .value,
      isTrue,
    );
    expect(
      tester
          .widget<SwitchListTile>(
              find.byKey(const Key('settings.deviceCalendars')))
          .value,
      isTrue,
    );

    // (g) tray/resident/autostart toggles
    expect(
      tester.widget<SwitchListTile>(find.byKey(const Key('settings.tray'))).value,
      isFalse,
    );
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const Key('settings.resident')))
          .value,
      isTrue,
    );
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const Key('settings.autostart')))
          .value,
      isTrue,
    );
  });

  testWidgets('adding a duplicate lead time is rejected in the dialog',
      (tester) async {
    SettingsHarness.useTallViewport(tester);
    final harness = SettingsHarness(settings: AppSettings.defaults());
    await harness.pump(tester);

    await tester.tap(find.byKey(const Key('settings.addLeadTime')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('settings.addLeadDialogField')), '10');
    await tester.tap(find.byKey(const Key('settings.addLeadDialogAdd')));
    await tester.pumpAndSettle();

    expect(find.textContaining('already exists'), findsOneWidget);
    expect(harness.settings.alertLeadMinutes, [10, 1]);

    // Dialog stays open; cancel out of it.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings.addLeadDialogField')), findsNothing);
  });

  testWidgets('lead times can be added, removed and restored to defaults',
      (tester) async {
    SettingsHarness.useTallViewport(tester);
    final harness = SettingsHarness(
      settings: AppSettings(
        schemaVersion: AppSettings.currentSchemaVersion,
        alertLeadMinutes: const [30, 5, 1],
        snoozeEnabled: false,
        googleClientId: null,
      ),
    );
    await harness.pump(tester);
    expect(find.text('30 minutes before'), findsOneWidget);

    // Add 10 → inserted in canonical (longest-first) position.
    await tester.tap(find.byKey(const Key('settings.addLeadTime')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('settings.addLeadDialogField')), '10');
    await tester.tap(find.byKey(const Key('settings.addLeadDialogAdd')));
    await tester.pumpAndSettle();
    expect(harness.settings.alertLeadMinutes, [30, 10, 5, 1]);

    // Remove the 5-minute entry.
    await tester.tap(find.byKey(const Key('settings.deleteLead-5')));
    await tester.pump();
    expect(harness.settings.alertLeadMinutes, [30, 10, 1]);

    // Restore defaults.
    await tester.tap(find.byKey(const Key('settings.restoreDefaults')));
    await tester.pump();
    expect(harness.settings.alertLeadMinutes, [10, 1]);
    expect(find.text('10 minutes before'), findsOneWidget);
    expect(find.text('1 minute before'), findsOneWidget);
  });

  testWidgets('malformed Google client ids are rejected in the UI',
      (tester) async {
    SettingsHarness.useTallViewport(tester);
    final harness = SettingsHarness(settings: AppSettings.defaults());
    await harness.pump(tester);

    await tester.enterText(
        find.byKey(const Key('settings.googleClientIdField')), 'not-a-client');
    await tester.tap(find.byKey(const Key('settings.googleConnect')));
    await tester.pump();

    expect(find.text('Client ID must end with .apps.googleusercontent.com'),
        findsOneWidget);
    expect(harness.googleConnectId, isNull);
    expect(harness.settings.googleClientId, isNull);

    // Correcting the input clears the error and connects.
    await tester.enterText(
        find.byKey(const Key('settings.googleClientIdField')),
        'abcd-1234.apps.googleusercontent.com');
    await tester.tap(find.byKey(const Key('settings.googleConnect')));
    await tester.pump();

    expect(harness.googleConnectId, 'abcd-1234.apps.googleusercontent.com');
    expect(harness.settings.googleClientId,
        'abcd-1234.apps.googleusercontent.com');
    expect(find.byKey(const Key('settings.googleDisconnect')), findsOneWidget);
  });

  testWidgets('settings round-trip through a real store and render again',
      (tester) async {
    SettingsHarness.useTallViewport(tester);
    SharedPreferences.setMockInitialValues({});
    final store = SettingsStore();

    final harness = SettingsHarness(settings: AppSettings.defaults());
    await harness.pump(tester);

    // Toggle snooze.
    await tester.tap(find.byKey(const Key('settings.snoozeSwitch')));
    await tester.pump();
    expect(harness.settings.snoozeEnabled, isTrue);

    // Add a lead time.
    await tester.tap(find.byKey(const Key('settings.addLeadTime')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('settings.addLeadDialogField')), '5');
    await tester.tap(find.byKey(const Key('settings.addLeadDialogAdd')));
    await tester.pumpAndSettle();
    expect(harness.settings.alertLeadMinutes, [10, 5, 1]);

    // Enter a valid client id and connect.
    await tester.enterText(
        find.byKey(const Key('settings.googleClientIdField')),
        '1234-abcd.apps.googleusercontent.com');
    await tester.tap(find.byKey(const Key('settings.googleConnect')));
    await tester.pump();
    expect(harness.settings.googleClientId,
        '1234-abcd.apps.googleusercontent.com');

    // Enable the Android device-calendar source.
    await tester.tap(find.byKey(const Key('settings.deviceCalendars')));
    await tester.pump();
    expect(harness.settings.deviceCalendarsEnabled, isTrue);

    // Persist through the real SettingsStore and load a fresh copy.
    await store.save(harness.settings);
    final loaded = await store.load();
    expect(loaded.loadIssue, isNull);
    expect(loaded.settings.snoozeEnabled, isTrue);
    expect(loaded.settings.alertLeadMinutes, [10, 5, 1]);
    expect(loaded.settings.googleClientId, '1234-abcd.apps.googleusercontent.com');
    expect(loaded.settings.deviceCalendarsEnabled, isTrue);

    // A fresh screen built from the reloaded settings shows the same state.
    final reloaded = SettingsHarness(settings: loaded.settings);
    await reloaded.pump(tester);
    expect(find.text('10 minutes before'), findsOneWidget);
    expect(find.text('5 minutes before'), findsOneWidget);
    expect(find.text('1 minute before'), findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const Key('settings.snoozeSwitch')))
          .value,
      isTrue,
    );
    expect(
      tester
          .widget<SwitchListTile>(
              find.byKey(const Key('settings.deviceCalendars')))
          .value,
      isTrue,
    );
    expect(find.byKey(const Key('settings.googleDisconnect')), findsOneWidget);
  });

  testWidgets('extras controls emit changes and audio preview reports source',
      (tester) async {
    SettingsHarness.useTallViewport(tester);
    final harness = SettingsHarness(settings: AppSettings.defaults());
    await harness.pump(tester);

    await tester.tap(find.byKey(const Key('settings.volumeRamp')));
    await tester.pump();
    expect(harness.extras.volumeRampEnabled, isFalse);

    await tester.tap(find.byKey(const Key('settings.repeatInterval')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Repeat: 60 s').last);
    await tester.pumpAndSettle();
    expect(harness.extras.repeatIntervalSeconds, 60);

    await tester.tap(find.byKey(const Key('settings.quietAway')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('After 10 min away').last);
    await tester.pumpAndSettle();
    expect(harness.extras.quietWhenAwayMinutes, 10);

    await tester.tap(find.byKey(const Key('settings.alertWhileLocked')));
    await tester.pump();
    expect(harness.extras.alertWhileLockedOrAway, isTrue);

    await tester.tap(find.byKey(const Key('settings.audioSource')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chime').last);
    await tester.pumpAndSettle();
    expect(harness.extras.audioSourceId, 'chime');

    await tester.tap(find.byKey(const Key('settings.audioPreview')));
    await tester.pump();
    expect(harness.previewedAudioSource, 'chime');
  });

  testWidgets('google/ics disconnect callbacks fire and diagnostics opens',
      (tester) async {
    SettingsHarness.useTallViewport(tester);
    final harness = SettingsHarness(
      settings: AppSettings(
        schemaVersion: AppSettings.currentSchemaVersion,
        alertLeadMinutes: AppSettings.defaultAlertLeadMinutes,
        snoozeEnabled: false,
        googleClientId: 'client123.apps.googleusercontent.com',
      ),
      extras: const SettingsExtras(icsUrl: 'https://example.com/team.ics'),
    );
    await harness.pump(tester);

    await tester.tap(find.byKey(const Key('settings.googleDisconnect')));
    await tester.pump();
    expect(harness.googleDisconnectCalls, 1);
    expect(harness.settings.googleClientId, isNull);
    expect(find.byKey(const Key('settings.googleConnect')), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings.icsDisconnect')));
    await tester.pump();
    expect(harness.icsDisconnectCalls, 1);
    expect(harness.extras.icsUrl, isNull);

    await tester.tap(find.byKey(const Key('settings.diagnostics')));
    await tester.pump();
    expect(harness.diagnosticsCalls, 1);
  });
}
