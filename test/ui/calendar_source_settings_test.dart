import 'package:attention_copilot/data/sources/calendar_contract_source.dart';
import 'package:attention_copilot/data/storage/settings_store.dart';
import 'package:attention_copilot/ui/calendar_source_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockCalendarContractSource extends Mock
    implements CalendarContractSource {}

/// In-memory [SettingsStore]: reads and writes the same [AppSettings] object,
/// so a second widget instance ("app restart") sees exactly what the first
/// one saved.
class FakeSettingsStore implements SettingsStore {
  FakeSettingsStore([AppSettings? initial])
      : settings = initial ?? AppSettings.defaults();

  AppSettings settings;
  int saveCount = 0;

  @override
  Map<int, SettingsMigration> get migrations => const {};

  @override
  Future<SettingsLoadResult> load() async => SettingsLoadResult(settings, null);

  @override
  Future<void> save(AppSettings settings) async {
    saveCount++;
    this.settings = settings;
  }
}

const _work = ContractCalendar(
  id: 1,
  displayName: 'Work',
  accountName: 'me@example.com',
  visible: true,
);
const _personal = ContractCalendar(
  id: 2,
  displayName: 'Personal',
  accountName: 'me@gmail.com',
  visible: true,
);

Widget _host({
  required CalendarContractSource source,
  required SettingsStore store,
  Future<void> Function()? openAppSettings,
}) {
  return MaterialApp(
    home: Scaffold(
      body: CalendarSourceSettings(
        source: source,
        settingsStore: store,
        openAppSettings: openAppSettings ?? () async {},
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockCalendarContractSource source;
  late FakeSettingsStore store;

  setUp(() {
    source = MockCalendarContractSource();
    store = FakeSettingsStore();
  });

  testWidgets(
      'does not touch the permission APIs until the source toggle is '
      'switched on', (tester) async {
    await tester.pumpWidget(_host(source: source, store: store));
    await tester.pumpAndSettle();

    expect(find.text("Use this device's calendars"), findsOneWidget);
    final master = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(master.value, isFalse);

    verifyNever(() => source.hasPermission());
    verifyNever(() => source.requestPermission());
    verifyNever(() => source.listCalendars());
  });

  testWidgets(
      'granted: renders the calendar list with account names and '
      'per-calendar toggles', (tester) async {
    when(() => source.requestPermission()).thenAnswer((_) async => true);
    when(() => source.listCalendars())
        .thenAnswer((_) async => const [_work, _personal]);

    await tester.pumpWidget(_host(source: source, store: store));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pumpAndSettle();

    // Master toggle plus one switch per calendar.
    expect(find.byType(SwitchListTile), findsNWidgets(3));

    // Account name is rendered next to each calendar name.
    expect(find.text('Work'), findsOneWidget);
    expect(find.text('me@example.com'), findsOneWidget);
    expect(find.text('Personal'), findsOneWidget);
    expect(find.text('me@gmail.com'), findsOneWidget);

    // Visible calendars default to enabled.
    final values = tester
        .widgetList<SwitchListTile>(find.byType(SwitchListTile))
        .map((tile) => tile.value)
        .toList();
    expect(values, [true, true, true]);

    verify(() => source.requestPermission()).called(1);
  });

  testWidgets(
      'denied: shows a blocking explanatory state with retry and a '
      'settings action that works', (tester) async {
    var settingsOpened = 0;
    when(() => source.requestPermission()).thenAnswer((_) async => false);

    await tester.pumpWidget(_host(
      source: source,
      store: store,
      openAppSettings: () async => settingsOpened++,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pumpAndSettle();

    expect(
      find.textContaining('READ_CALENDAR', findRichText: false),
      findsOneWidget,
    );
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Open system settings'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsOneWidget, // master only
        reason: 'no calendar list while permission is denied');

    await tester.tap(find.text('Open system settings'));
    await tester.pumpAndSettle();
    expect(settingsOpened, 1);

    // Retry with the grant now available recovers into the calendar list.
    when(() => source.requestPermission()).thenAnswer((_) async => true);
    when(() => source.listCalendars())
        .thenAnswer((_) async => const [_work, _personal]);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(find.text('Work'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNWidgets(3));
  });

  testWidgets(
      'per-calendar selection is persisted and survives an app restart',
      (tester) async {
    when(() => source.requestPermission()).thenAnswer((_) async => true);
    when(() => source.listCalendars())
        .thenAnswer((_) async => const [_work, _personal]);

    await tester.pumpWidget(_host(source: source, store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pumpAndSettle();

    // Disable the personal calendar.
    await tester.tap(find.widgetWithText(SwitchListTile, 'Personal'));
    await tester.pumpAndSettle();

    expect(store.settings.deviceCalendarsEnabled, isTrue);
    expect(store.settings.enabledDeviceCalendarIds, [1]);

    // "Restart": unmount the tree, then inflate a fresh widget instance over
    // the same store (a fresh State, like a real process restart).
    final restarted = MockCalendarContractSource();
    when(() => restarted.hasPermission()).thenAnswer((_) async => true);
    when(() => restarted.listCalendars())
        .thenAnswer((_) async => const [_work, _personal]);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(_host(source: restarted, store: store));
    await tester.pumpAndSettle();

    expect(find.text('Work'), findsOneWidget);
    final values = tester
        .widgetList<SwitchListTile>(find.byType(SwitchListTile))
        .map((tile) => tile.value)
        .toList();
    expect(values, [true, true, false]);

    // The restart only checked the grant passively; it never prompted.
    verify(() => restarted.hasPermission()).called(1);
    verifyNever(() => restarted.requestPermission());
  });

  testWidgets(
      'an enabled source with a revoked permission shows the denied state '
      'without prompting at start', (tester) async {
    store = FakeSettingsStore(AppSettings.defaults().copyWith(
      deviceCalendarsEnabled: true,
      enabledDeviceCalendarIds: const [1],
    ));
    when(() => source.hasPermission()).thenAnswer((_) async => false);

    await tester.pumpWidget(_host(source: source, store: store));
    await tester.pumpAndSettle();

    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Open system settings'), findsOneWidget);
    verify(() => source.hasPermission()).called(1);
    verifyNever(() => source.requestPermission());
  });
}
