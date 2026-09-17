import 'package:attention_copilot/data/sources/eventkit_source.dart';
import 'package:attention_copilot/data/sources/source.dart';
import 'package:attention_copilot/domain/models/meeting_join_info.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel(kEventKitMethodChannel);
  const eventChannel = EventChannel(kEventKitEventChannel);

  late TestDefaultBinaryMessengerBinding binding;

  void clearChannels() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      methodChannel,
      null,
    );
    binding.defaultBinaryMessenger.setMockStreamHandler(eventChannel, null);
  }

  setUp(() {
    binding = TestDefaultBinaryMessengerBinding.instance;
    clearChannels();
  });

  tearDown(clearChannels);

  /// Stubs `authorizationStatus` and `requestFullAccess` with [status].
  void stubAuthorization(String status) {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(methodChannel, (
      call,
    ) async {
      if (call.method == 'authorizationStatus') {
        return status;
      }
      if (call.method == 'requestFullAccess') {
        return status;
      }
      return null;
    });
  }

  /// Stubs the full granted fetch path with [occurrences] and records every
  /// `listOccurrences` call in [listCalls].
  void stubGrantedFetch(List<Object?> occurrences, List<MethodCall> listCalls) {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(methodChannel, (
      call,
    ) async {
      switch (call.method) {
        case 'authorizationStatus':
          return 'fullAccess';
        case 'listOccurrences':
          listCalls.add(call);
          return occurrences;
        default:
          return null;
      }
    });
  }

  Map<String, Object?> occurrenceJson({
    String id = 'INSTANCE-1',
    String masterId = 'MASTER-1',
    String title = 'Standup',
    String calendarTitle = 'Work',
    String start = '2026-09-18T09:00:00Z',
    String end = '2026-09-18T09:30:00Z',
    bool allDay = false,
    String? location,
    String? timeZone,
    String? conferenceUrl,
    String? conferenceProvider,
  }) {
    return <String, Object?>{
      'id': id,
      'calendarItemIdentifier': masterId,
      'calendarTitle': calendarTitle,
      'title': title,
      'start': start,
      'end': end,
      'allDay': allDay,
      'location': ?location,
      'timeZone': ?timeZone,
      'conferenceUrl': ?conferenceUrl,
      'conferenceProvider': ?conferenceProvider,
    };
  }

  group('authorization', () {
    test('fromNative maps every native posture', () {
      expect(
        EventKitAuthorization.fromNative('notDetermined'),
        EventKitAuthorization.notDetermined,
      );
      expect(
        EventKitAuthorization.fromNative('fullAccess'),
        EventKitAuthorization.granted,
      );
      expect(
        EventKitAuthorization.fromNative('authorized'),
        EventKitAuthorization.granted,
      );
      expect(
        EventKitAuthorization.fromNative('writeOnly'),
        EventKitAuthorization.writeOnly,
      );
      expect(
        EventKitAuthorization.fromNative('denied'),
        EventKitAuthorization.denied,
      );
      expect(
        EventKitAuthorization.fromNative('restricted'),
        EventKitAuthorization.restricted,
      );
      expect(
        EventKitAuthorization.fromNative('unsupported'),
        EventKitAuthorization.unsupported,
      );
      expect(
        EventKitAuthorization.fromNative('something-new'),
        EventKitAuthorization.unknown,
      );
    });

    test(
      'checkAuthorization caches the posture into permissionState',
      () async {
        stubAuthorization('denied');
        final source = EventKitSource();
        // Unknown until the first native check: only a confirmed denial may
        // skip fetches.
        expect(source.permissionState, SourcePermissionState.granted);
        expect(await source.checkAuthorization(), EventKitAuthorization.denied);
        expect(source.permissionState, SourcePermissionState.denied);
      },
    );

    test('restricted is reported as denied, not as a generic state', () async {
      stubAuthorization('restricted');
      final source = EventKitSource();
      expect(
        await source.checkAuthorization(),
        EventKitAuthorization.restricted,
      );
      expect(source.permissionState, SourcePermissionState.denied);
    });

    test('requestFullAccess reports the grant and updates the cache', () async {
      stubAuthorization('fullAccess');
      final source = EventKitSource();
      expect(await source.requestFullAccess(), isTrue);
      expect(source.permissionState, SourcePermissionState.granted);
    });

    test('requestFullAccess reports a declined prompt', () async {
      stubAuthorization('denied');
      final source = EventKitSource();
      expect(await source.requestFullAccess(), isFalse);
      expect(source.permissionState, SourcePermissionState.denied);
    });

    test('openSystemSettings invokes the native method', () async {
      final calls = <String>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(methodChannel, (
        call,
      ) async {
        calls.add(call.method);
        return null;
      });
      final source = EventKitSource();
      await source.openSystemSettings();
      expect(calls, ['openSystemSettings']);
    });
  });

  group('fetch', () {
    test('maps occurrences returned by the plugin', () async {
      final listCalls = <MethodCall>[];
      stubGrantedFetch(<Object?>[
        occurrenceJson(
          id: 'E1-1',
          masterId: 'MASTER-1',
          title: 'Standup',
          calendarTitle: 'Work',
          start: '2026-09-18T09:00:00Z',
          end: '2026-09-18T09:30:00Z',
          location: 'Room 3',
          timeZone: 'Europe/Berlin',
          conferenceUrl: 'https://meet.google.com/abc-defg-hij',
          conferenceProvider: 'google_meet',
        ),
      ], listCalls);
      final source = EventKitSource();

      final snapshot = await source.fetch(null);

      // Full read: no incremental cursor.
      expect(snapshot.nextCursor, isNull);
      expect(snapshot.occurrences, hasLength(1));
      final occurrence = snapshot.occurrences.single;
      expect(occurrence.id, 'E1-1');
      expect(occurrence.event.id, 'MASTER-1');
      expect(occurrence.title, 'Standup');
      expect(occurrence.location, 'Room 3');
      expect(occurrence.originalTimezoneId, 'Europe/Berlin');
      expect(occurrence.startUtc, DateTime.utc(2026, 9, 18, 9));
      expect(occurrence.endUtc, DateTime.utc(2026, 9, 18, 9, 30));
      expect(occurrence.startUtc.isUtc, isTrue);
      expect(occurrence.endUtc.isUtc, isTrue);
      expect(occurrence.isAllDay, isFalse);
      expect(
        occurrence.joinInfo,
        const MeetingJoinInfo(
          url: 'https://meet.google.com/abc-defg-hij',
          provider: 'google_meet',
        ),
      );
      expect(occurrence.source.id, 'eventkit');

      // The fetch window is passed to the plugin as UTC ISO-8601 instants.
      expect(listCalls, hasLength(1));
      final arguments = Map<String, Object?>.from(
        listCalls.single.arguments! as Map,
      );
      expect(arguments['fromIso'], isA<String>());
      expect(arguments['toIso'], isA<String>());
      expect(DateTime.tryParse(arguments['fromIso']! as String)?.isUtc, isTrue);
    });

    test('all-day occurrences keep their UTC instants and flag', () async {
      stubGrantedFetch(<Object?>[
        occurrenceJson(
          start: '2026-09-17T22:00:00Z',
          end: '2026-09-18T22:00:00Z',
          allDay: true,
          title: 'Holiday',
        ),
      ], <MethodCall>[]);
      final source = EventKitSource();

      final snapshot = await source.fetch(null);

      final occurrence = snapshot.occurrences.single;
      expect(occurrence.isAllDay, isTrue);
      expect(occurrence.startUtc, DateTime.utc(2026, 9, 17, 22));
      expect(occurrence.endUtc, DateTime.utc(2026, 9, 18, 22));
    });

    test('an untitled event falls back to the calendar title', () async {
      stubGrantedFetch(<Object?>[
        occurrenceJson(title: '', calendarTitle: 'Holidays'),
      ], <MethodCall>[]);
      final source = EventKitSource();

      final snapshot = await source.fetch(null);

      expect(snapshot.occurrences.single.title, 'Holidays');
    });

    test(
      'a granted empty calendar returns an empty snapshot, not an error',
      () async {
        stubGrantedFetch(<Object?>[], <MethodCall>[]);
        final source = EventKitSource();

        final snapshot = await source.fetch(null);

        expect(snapshot.occurrences, isEmpty);
        expect(snapshot.nextCursor, isNull);
      },
    );

    test(
      'reports needs-permission when the prompt was never answered',
      () async {
        stubAuthorization('notDetermined');
        final listCalls = <MethodCall>[];
        binding.defaultBinaryMessenger.setMockMethodCallHandler(methodChannel, (
          call,
        ) async {
          if (call.method == 'listOccurrences') {
            listCalls.add(call);
            return <Object?>[];
          }
          if (call.method == 'authorizationStatus') {
            return 'notDetermined';
          }
          return null;
        });
        final source = EventKitSource();

        await expectLater(
          source.fetch(null),
          throwsA(
            isA<SourcePermissionDeniedException>().having(
              (error) => error.toString(),
              'message',
              contains('needs-permission'),
            ),
          ),
        );
        // The list call is never attempted before the grant exists.
        expect(listCalls, isEmpty);
      },
    );

    test('reports permission-denied when access was declined', () async {
      stubAuthorization('denied');
      final source = EventKitSource();

      await expectLater(
        source.fetch(null),
        throwsA(
          isA<SourcePermissionDeniedException>().having(
            (error) => error.toString(),
            'message',
            contains('permission-denied'),
          ),
        ),
      );
    });

    test('reports permission-denied when the native list call hits a '
        'revoked grant', () async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(methodChannel, (
        call,
      ) async {
        if (call.method == 'authorizationStatus') {
          return 'fullAccess';
        }
        if (call.method == 'listOccurrences') {
          throw PlatformException(code: 'permission-denied', message: 'denied');
        }
        return null;
      });
      final source = EventKitSource();

      await expectLater(
        source.fetch(null),
        throwsA(
          isA<SourcePermissionDeniedException>().having(
            (error) => error.toString(),
            'message',
            contains('permission-denied'),
          ),
        ),
      );
    });
  });

  group('conference heuristic', () {
    test('providerForUrl labels recognised providers', () {
      expect(providerForUrl('https://us02web.zoom.us/j/123?pwd=x'), 'zoom');
      expect(
        providerForUrl('https://meet.google.com/abc-defg-hij'),
        'google_meet',
      );
      expect(
        providerForUrl(
          'https://teams.microsoft.com/l/meetup-join/19:abc@thread.v2/0',
        ),
        'teams',
      );
      expect(providerForUrl('https://teams.live.com/meet/123'), 'teams');
      expect(providerForUrl('https://acme.webex.com/meet/alice'), 'webex');
      expect(providerForUrl('https://example.com/notes'), isNull);
      expect(providerForUrl('not a url'), isNull);
    });

    test('meetingLinkFromText extracts the first recognised provider link', () {
      final info = meetingLinkFromText(
        'Join https://zoom.us/j/123?pwd=abc or stay on slack',
      );
      expect(
        info,
        const MeetingJoinInfo(
          url: 'https://zoom.us/j/123?pwd=abc',
          provider: 'zoom',
        ),
      );
      expect(meetingLinkFromText('no links here'), isNull);
      expect(meetingLinkFromText(null), isNull);
      expect(meetingLinkFromText(''), isNull);
    });

    test('strips trailing punctuation from an embedded link', () {
      final info = meetingLinkFromText('(https://meet.google.com/abc-123).');
      expect(info?.url, 'https://meet.google.com/abc-123');
      expect(info?.provider, 'google_meet');
    });

    test(
      'a location link becomes join info when conferenceUrl is absent',
      () async {
        stubGrantedFetch(<Object?>[
          occurrenceJson(
            location:
                'Call: https://teams.microsoft.com/l/meetup-join/19:xyz/0',
          ),
        ], <MethodCall>[]);
        final source = EventKitSource();

        final snapshot = await source.fetch(null);

        expect(
          snapshot.occurrences.single.joinInfo,
          const MeetingJoinInfo(
            url: 'https://teams.microsoft.com/l/meetup-join/19:xyz/0',
            provider: 'teams',
          ),
        );
      },
    );

    test(
      'a conference URL without a provider label infers the provider',
      () async {
        stubGrantedFetch(<Object?>[
          occurrenceJson(conferenceUrl: 'https://us02web.zoom.us/j/42'),
        ], <MethodCall>[]);
        final source = EventKitSource();

        final snapshot = await source.fetch(null);

        expect(
          snapshot.occurrences.single.joinInfo,
          const MeetingJoinInfo(
            url: 'https://us02web.zoom.us/j/42',
            provider: 'zoom',
          ),
        );
      },
    );

    test('a non-meeting location yields no join info', () async {
      stubGrantedFetch(<Object?>[
        occurrenceJson(location: 'Room 3, floor 2'),
      ], <MethodCall>[]);
      final source = EventKitSource();

      final snapshot = await source.fetch(null);

      expect(snapshot.occurrences.single.joinInfo, isNull);
    });
  });

  group('external changes', () {
    test('externalChanges emits native change pushes', () async {
      binding.defaultBinaryMessenger.setMockStreamHandler(
        eventChannel,
        MockStreamHandler.inline(
          onListen: (arguments, events) => events.success('changed'),
          onCancel: (arguments) {},
        ),
      );
      final source = EventKitSource();

      final received = <String>[];
      final subscription = source.externalChanges.listen(received.add);
      await Future<void>.delayed(Duration.zero);

      expect(received, ['changed']);

      await subscription.cancel();
    });
  });
}
