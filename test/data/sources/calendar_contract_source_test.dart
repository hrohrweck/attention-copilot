import 'package:attention_copilot/data/sources/calendar_contract_source.dart';
import 'package:attention_copilot/data/sources/source.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const MethodChannel _channel =
    MethodChannel(kCalendarContractMethodChannel);

/// Scriptable stand-in for the native `CalendarPlugin` channel.
class _FakeCalendarChannel {
  _FakeCalendarChannel() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, _handle);
  }

  final List<MethodCall> calls = [];
  Future<Object?> Function(MethodCall call)? handler;

  Future<Object?> _handle(MethodCall call) {
    calls.add(call);
    final handle = handler;
    return handle != null ? handle(call) : Future<Object?>.value(null);
  }

  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }
}

Map<String, Object?> instanceRow({
  int eventId = 42,
  String? title = 'Standup',
  int begin = 1_700_000_000_000,
  int? end,
  int allDay = 0,
  String? location,
  int calendarId = 7,
  String calendarName = 'Work',
  String? accountName = 'me@example.com',
}) {
  return <String, Object?>{
    'eventId': eventId,
    'calendarId': calendarId,
    'title': title,
    'beginMillis': begin,
    'endMillis': end ?? begin + 3_600_000,
    'allDay': allDay,
    'location': location,
    'organizer': 'organizer@example.com',
    'accessLevel': 3,
    'calendarName': calendarName,
    'accountName': accountName,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeCalendarChannel fake;
  late CalendarContractSource source;
  late DateTime now;

  setUp(() {
    fake = _FakeCalendarChannel();
    addTearDown(fake.dispose);
    now = DateTime.utc(2026, 9, 18, 9);
    source = CalendarContractSource(clock: () => now);
  });

  group('identity and capabilities', () {
    test('exposes the calendarcontract source id', () {
      expect(source.id, 'calendarcontract');
      expect(source.displayName, 'Android calendars');
      expect(source.isReadOnly, isTrue);
      expect(source.needsAuthentication, isFalse);
    });

    test('permissionState defaults to denied until a native check ran', () {
      expect(source.permissionState, SourcePermissionState.denied);
    });
  });

  group('hasPermission', () {
    test('maps a native true to granted and caches it', () async {
      fake.handler = (call) async => true;
      expect(await source.hasPermission(), isTrue);
      expect(source.permissionState, SourcePermissionState.granted);
      expect(fake.calls.single.method, 'hasPermission');
    });

    test('maps a native false to denied', () async {
      fake.handler = (call) async => false;
      expect(await source.hasPermission(), isFalse);
      expect(source.permissionState, SourcePermissionState.denied);
    });

    test('a missing plugin is reported as denied, not thrown', () async {
      fake.handler = (call) async => throw MissingPluginException();
      expect(await source.hasPermission(), isFalse);
      expect(source.permissionState, SourcePermissionState.denied);
    });

    test('a null native reply counts as denied', () async {
      fake.handler = (call) async => null;
      expect(await source.hasPermission(), isFalse);
      expect(source.permissionState, SourcePermissionState.denied);
    });
  });

  group('requestPermission', () {
    test('delegates to the native plugin and caches a grant', () async {
      fake.handler = (call) async => true;
      expect(await source.requestPermission(), isTrue);
      expect(source.permissionState, SourcePermissionState.granted);
      expect(fake.calls.single.method, 'requestPermission');
    });

    test('caches a denial', () async {
      fake.handler = (call) async => false;
      expect(await source.requestPermission(), isFalse);
      expect(source.permissionState, SourcePermissionState.denied);
    });

    test('a platform error degrades to denied instead of throwing', () async {
      fake.handler = (call) async => throw PlatformException(code: 'no_activity');
      expect(await source.requestPermission(), isFalse);
      expect(source.permissionState, SourcePermissionState.denied);
    });
  });

  group('fetch', () {
    test('throws permission denied without querying when not granted', () async {
      fake.handler = (call) async => false;
      await expectLater(
        source.fetch(null),
        throwsA(isA<SourcePermissionDeniedException>()),
      );
      expect(
        fake.calls.map((call) => call.method),
        isNot(contains('listInstances')),
      );
      expect(source.permissionState, SourcePermissionState.denied);
    });

    test('maps instance rows into occurrences', () async {
      fake.handler = (call) {
        if (call.method == 'hasPermission') {
          return Future<Object?>.value(true);
        }
        return Future<Object?>.value(<Object?>[
          instanceRow(
            eventId: 42,
            title: 'Standup',
            begin: 1_700_000_000_000,
            end: 1_700_003_600_000,
            location: 'Room 4',
          ),
          instanceRow(
            eventId: 43,
            title: 'Offsite',
            begin: 1_700_100_000_000,
            allDay: 1,
          ),
        ]);
      };

      final snapshot = await source.fetch(null);

      expect(snapshot.occurrences, hasLength(2));
      final first = snapshot.occurrences[0];
      expect(first.id, '42/1700000000000');
      expect(first.event.id, '42');
      expect(first.title, 'Standup');
      expect(first.location, 'Room 4');
      expect(first.startUtc, DateTime.fromMillisecondsSinceEpoch(
          1_700_000_000_000, isUtc: true));
      expect(first.endUtc, DateTime.fromMillisecondsSinceEpoch(
          1_700_003_600_000, isUtc: true));
      expect(first.startUtc.isUtc, isTrue);
      expect(first.isAllDay, isFalse);
      expect(first.source.id, 'calendarcontract');

      final second = snapshot.occurrences[1];
      expect(second.isAllDay, isTrue);
      expect(second.event.id, '43');
      expect(snapshot.nextCursor, isNotNull);
    });

    test('uses a private-event title fallback', () async {
      fake.handler = (call) {
        if (call.method == 'hasPermission') {
          return Future<Object?>.value(true);
        }
        return Future<Object?>.value(<Object?>[
          instanceRow(title: null),
        ]);
      };

      final snapshot = await source.fetch(null);
      expect(snapshot.occurrences.single.title, '(no title)');
    });

    test('requests the full window on the first fetch', () async {
      fake.handler = (call) {
        if (call.method == 'hasPermission') {
          return Future<Object?>.value(true);
        }
        return Future<Object?>.value(const <Object?>[]);
      };

      await source.fetch(null);

      final listCall = fake.calls.firstWhere(
        (call) => call.method == 'listInstances',
      );
      final args = listCall.arguments as Map<Object?, Object?>;
      expect(args['fromMillis'], DateTime.utc(2026, 9, 17, 9).millisecondsSinceEpoch);
      expect(args['toMillis'], DateTime.utc(2026, 9, 25, 9).millisecondsSinceEpoch);
    });

    test('expands the window from the previous cursor end', () async {
      fake.handler = (call) {
        if (call.method == 'hasPermission') {
          return Future<Object?>.value(true);
        }
        return Future<Object?>.value(const <Object?>[]);
      };

      final first = await source.fetch(null);
      await source.fetch(first.nextCursor);

      final listCalls = fake.calls
          .where((call) => call.method == 'listInstances')
          .toList();
      expect(listCalls, hasLength(2));
      final args = listCalls[1].arguments as Map<Object?, Object?>;
      expect(args['fromMillis'], DateTime.utc(2026, 9, 25, 9).millisecondsSinceEpoch);
      expect(args['toMillis'], DateTime.utc(2026, 9, 25, 9).millisecondsSinceEpoch);
    });

    test('clamps the cursor end when the clock moved backwards', () async {
      fake.handler = (call) {
        if (call.method == 'hasPermission') {
          return Future<Object?>.value(true);
        }
        return Future<Object?>.value(const <Object?>[]);
      };

      final first = await source.fetch(null);
      now = DateTime.utc(2026, 9, 10, 9);
      await source.fetch(first.nextCursor);

      final listCalls = fake.calls
          .where((call) => call.method == 'listInstances')
          .toList();
      final args = listCalls[1].arguments as Map<Object?, Object?>;
      expect(args['fromMillis'], DateTime.utc(2026, 9, 17, 9).millisecondsSinceEpoch);
      expect(args['toMillis'], DateTime.utc(2026, 9, 17, 9).millisecondsSinceEpoch);
    });

    test('skips malformed rows without failing the fetch', () async {
      fake.handler = (call) {
        if (call.method == 'hasPermission') {
          return Future<Object?>.value(true);
        }
        return Future<Object?>.value(<Object?>[
          'not-a-map',
          instanceRow(eventId: 42),
          instanceRow(eventId: 43, end: 1_700_000_000_000), // end == begin
          instanceRow(eventId: 44, begin: 1_700_000_000_000, end: 1_699_999_999_999),
          <Object?, Object?>{'eventId': 45, 'title': 'no times'},
        ]);
      };

      final snapshot = await source.fetch(null);
      expect(snapshot.occurrences, hasLength(1));
      expect(snapshot.occurrences.single.event.id, '42');
    });

    test('maps a native permission_denied error to the typed exception', () async {
      fake.handler = (call) {
        if (call.method == 'hasPermission') {
          return Future<Object?>.value(true);
        }
        return Future<Object?>.error(PlatformException(code: 'permission_denied'));
      };

      await expectLater(
        source.fetch(null),
        throwsA(isA<SourcePermissionDeniedException>()),
      );
    });

    test('propagates unexpected platform errors as plain errors', () async {
      fake.handler = (call) {
        if (call.method == 'hasPermission') {
          return Future<Object?>.value(true);
        }
        return Future<Object?>.error(PlatformException(code: 'query_failed'));
      };

      await expectLater(source.fetch(null), throwsA(isA<PlatformException>()));
    });

    test('a missing plugin surfaces as permission denied', () async {
      fake.handler = (call) async => throw MissingPluginException();
      await expectLater(
        source.fetch(null),
        throwsA(isA<SourcePermissionDeniedException>()),
      );
    });

    test('an empty provider reply yields an empty snapshot with a cursor', () async {
      fake.handler = (call) {
        if (call.method == 'hasPermission') {
          return Future<Object?>.value(true);
        }
        return Future<Object?>.value(null);
      };

      final snapshot = await source.fetch(null);
      expect(snapshot.occurrences, isEmpty);
      expect(snapshot.nextCursor, isNotNull);
    });
  });

  group('listCalendars', () {
    test('maps calendar rows and skips malformed entries', () async {
      fake.handler = (call) async => <Object?>[
        <String, Object?>{
          'id': 7,
          'displayName': 'Work',
          'accountName': 'me@example.com',
          'visible': 1,
        },
        'not-a-map',
        <String, Object?>{'displayName': 'missing id', 'visible': 1},
        <String, Object?>{
          'id': 8,
          'displayName': 'Personal',
          'accountName': null,
          'visible': true,
        },
      ];

      final calendars = await source.listCalendars();

      expect(calendars, hasLength(2));
      expect(calendars[0].id, 7);
      expect(calendars[0].displayName, 'Work');
      expect(calendars[0].accountName, 'me@example.com');
      expect(calendars[0].visible, isTrue);
      expect(calendars[1].accountName, isNull);
      expect(calendars[1].visible, isTrue);
      expect(fake.calls.single.method, 'listCalendars');
    });
  });
}
