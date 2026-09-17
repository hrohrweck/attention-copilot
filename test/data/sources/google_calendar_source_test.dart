import 'dart:convert';

import 'package:attention_copilot/data/sources/google_calendar_source.dart';
import 'package:attention_copilot/data/sources/source.dart';
import 'package:attention_copilot/data/storage/secret_store.dart';
import 'package:attention_copilot/domain/models/meeting_join_info.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// In-memory [SecureKeyValueBackend] so tests observe exactly what the source
/// stores without touching the platform keychain.
class _InMemoryBackend implements SecureKeyValueBackend {
  final Map<String, String> stored = {};

  @override
  Future<String?> read(String key) async => stored[key];

  @override
  Future<void> write(String key, String value) async => stored[key] = value;

  @override
  Future<void> delete(String key) async => stored.remove(key);
}

/// Scripted HTTP client: every request is recorded and answered by the next
/// handler in [script]. Requests beyond the script get a 400 so an unexpected
/// network round-trip can never silently pass.
class _ScriptedClient extends http.BaseClient {
  final List<http.Request> requests = [];
  final List<http.Response Function(http.Request request)> script = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest baseRequest) async {
    final request = http.Request(baseRequest.method, baseRequest.url);
    request.headers.addAll(baseRequest.headers);
    request.bodyBytes = await baseRequest.finalize().toBytes();
    requests.add(request);
    final handler = script.isEmpty
        ? (http.Request _) => http.Response('unexpected request', 400)
        : script.removeAt(0);
    final response = handler(request);
    return http.StreamedResponse(
      Stream.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
      reasonPhrase: response.reasonPhrase,
      contentLength: response.bodyBytes.length,
      request: request,
    );
  }
}

http.Response _json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

// ── fixtures ───────────────────────────────────────────────────────────────

Map<String, Object?> _event({
  required String id,
  required String summary,
  String startIso = '2026-09-18T09:00:00+02:00',
  String endIso = '2026-09-18T10:00:00+02:00',
  String timeZone = 'Europe/Berlin',
  Map<String, Object?>? conferenceData,
  String? status = 'confirmed',
  String? location,
}) =>
    {
      'id': id,
      'summary': summary,
      'status': status,
      'start': {'dateTime': startIso, 'timeZone': timeZone},
      'end': {'dateTime': endIso, 'timeZone': timeZone},
      'location': ?location,
      'conferenceData': ?conferenceData,
    };

const Map<String, Object?> _meetConference = {
  'conferenceId': 'abcd-efgh',
  'entryPoints': [
    {
      'entryPointType': 'video',
      'uri': 'https://meet.google.com/abc-defg-hij',
      'label': 'meet.google.com/abc-defg-hij',
    },
    {
      'entryPointType': 'phone',
      'uri': 'tel:+1-234-555-0199',
      'label': '+1 234-555-0199',
    },
  ],
};

Map<String, Object?> _allDayEvent({
  required String id,
  required String summary,
}) =>
    {
      'id': id,
      'summary': summary,
      'status': 'confirmed',
      'start': {'date': '2026-09-19'},
      'end': {'date': '2026-09-20'},
    };

Map<String, Object?> _page({
  List<Map<String, Object?>> items = const [],
  String? nextPageToken,
  String? nextSyncToken,
}) =>
    {
      'kind': 'calendar#events',
      if (items.isNotEmpty) 'items': items,
      'nextPageToken': ?nextPageToken,
      'nextSyncToken': ?nextSyncToken,
    };

const Map<String, Object?> _tokenResponse = {
  'access_token': 'at-123',
  'token_type': 'Bearer',
  'expires_in': 3599,
  'refresh_token': 'rt-456',
};

void main() {
  const clientId = 'byo-client-id';
  const calendarId = 'primary';

  late _ScriptedClient client;
  late _InMemoryBackend backend;
  late SecretStore secretStore;

  GoogleCalendarSource buildSource({Future<void> Function(Uri)? openBrowser}) {
    return GoogleCalendarSource(
      clientId: clientId,
      calendarId: calendarId,
      secretStore: secretStore,
      httpClient: client,
      openBrowser: openBrowser,
    );
  }

  /// Test double for the system browser: records the authorization URL and
  /// completes the redirect against the real loopback server, exactly like a
  /// browser following the `redirect_uri`.
  Future<void> Function(Uri) completingBrowser({
    required List<Uri> opened,
    String? code = 'test-auth-code',
    String? error,
  }) {
    return (Uri url) async {
      opened.add(url);
      final redirect = Uri.parse(url.queryParameters['redirect_uri']!);
      final target = redirect.replace(
        queryParameters: {
          ...redirect.queryParameters,
          'error': ?error,
          'code': ?code,
        },
      );
      await http.get(target);
    };
  }

  http.Request singleEventsListRequest() =>
      client.requests.firstWhere((request) =>
          request.method == 'GET' &&
          request.url.path.endsWith('/calendars/primary/events'));

  setUp(() {
    client = _ScriptedClient();
    backend = _InMemoryBackend();
    secretStore = SecretStore(backend: backend);
  });

  group('authentication', () {
    test(
        'loopback URL carries code_challenge + S256 and the exchange is a '
        'PKCE public client with no secret', () async {
      final opened = <Uri>[];
      client.script.add((_) => _json(_tokenResponse));
      final source =
          buildSource(openBrowser: completingBrowser(opened: opened));

      expect(source.needsAuthentication, isTrue);
      expect(source.permissionState, SourcePermissionState.notRequired);

      await source.authenticate();

      expect(opened, hasLength(1));
      final authUrl = opened.single;
      expect(authUrl.host, 'accounts.google.com');
      expect(authUrl.queryParameters['client_id'], clientId);
      expect(
        authUrl.queryParameters['code_challenge'],
        allOf(isNotNull, isNotEmpty),
      );
      expect(authUrl.queryParameters['code_challenge_method'], 'S256');
      expect(
        authUrl.queryParameters['redirect_uri'],
        startsWith('http://127.0.0.1:'),
      );
      final scope = authUrl.queryParameters['scope'] ?? '';
      expect(
        scope,
        contains(
            'https://www.googleapis.com/auth/calendar.events.readonly'),
      );
      expect(
        scope,
        contains(
            'https://www.googleapis.com/auth/calendar.calendarlist.readonly'),
      );
      expect(scope, isNot(contains('calendar.readonly')));

      // The token exchange must be a public client: code_verifier in, no
      // client_secret ever.
      final tokenRequest =
          client.requests.singleWhere((r) => r.method == 'POST');
      expect(tokenRequest.url, GoogleCalendarSource.tokenEndpoint);
      expect(tokenRequest.bodyFields['grant_type'], 'authorization_code');
      expect(tokenRequest.bodyFields['code'], 'test-auth-code');
      expect(tokenRequest.bodyFields['code_verifier'], allOf(isNotNull, isNotEmpty));
      expect(tokenRequest.bodyFields.containsKey('client_secret'), isFalse);
      expect(tokenRequest.bodyFields.containsKey('client_id'), isTrue);

      expect(backend.stored[SecretStore.accessTokenKey], 'at-123');
      expect(backend.stored[SecretStore.refreshTokenKey], 'rt-456');
      expect(source.permissionState, SourcePermissionState.granted);
    });

    test('an authorization error surfaces and stores nothing', () async {
      final opened = <Uri>[];
      final source = buildSource(
        openBrowser: completingBrowser(opened: opened, error: 'access_denied'),
      );

      await expectLater(
        source.authenticate(),
        throwsA(isA<GoogleAuthorizationException>()),
      );
      expect(backend.stored, isEmpty);
      expect(source.permissionState, SourcePermissionState.notRequired);
    });
  });

  group('fetch', () {
    test(
        'full sync pages through nextPageToken and persists only the final '
        'nextSyncToken', () async {
      await secretStore.saveAccessToken('tok-A');
      client.script.addAll([
        (_) => _json(_page(
              items: [_event(id: 'e1@google', summary: 'First')],
              // Defensive fixture: a stray sync token on a non-final page must
              // never win over the last page's token.
              nextPageToken: 'PAGE-1',
              nextSyncToken: 'STALE-SYNC',
            )),
        (_) => _json(_page(
              items: [_event(id: 'e2@google', summary: 'Second')],
              nextSyncToken: 'FINAL-SYNC',
            )),
      ]);
      final source = buildSource();

      final snapshot = await source.fetch(null);

      expect(snapshot.occurrences, hasLength(2));
      expect(
        snapshot.occurrences.map((o) => o.title),
        containsAll(['First', 'Second']),
      );
      expect(snapshot.nextCursor?.value, 'FINAL-SYNC');

      expect(client.requests, hasLength(2));
      final first = singleEventsListRequest();
      expect(first.url.queryParameters['singleEvents'], 'true');
      expect(first.url.queryParameters['orderBy'], 'startTime');
      expect(first.url.queryParameters['maxResults'], '250');
      expect(first.url.queryParameters['conferenceDataVersion'], '1');
      expect(first.url.queryParameters['timeMin'], isNotNull);
      expect(first.url.queryParameters['timeMax'], isNotNull);
      expect(first.url.queryParameters.containsKey('pageToken'), isFalse);
      expect(first.url.queryParameters.containsKey('syncToken'), isFalse);

      final second = client.requests[1];
      expect(second.url.queryParameters['pageToken'], 'PAGE-1');
    });

    test(
        'incremental sync sends singleEvents=true and never orderBy together '
        'with a syncToken', () async {
      await secretStore.saveAccessToken('tok-A');
      client.script.add((_) => _json(_page(
            items: [_event(id: 'e1@google', summary: 'Changed')],
            nextSyncToken: 'SYNC-2',
          )));
      final source = buildSource();

      final snapshot = await source.fetch(const SourceCursor('SYNC-1'));

      expect(snapshot.occurrences, hasLength(1));
      expect(snapshot.nextCursor?.value, 'SYNC-2');

      final request = singleEventsListRequest();
      expect(request.url.queryParameters['syncToken'], 'SYNC-1');
      expect(request.url.queryParameters['singleEvents'], 'true');
      expect(request.url.queryParameters.containsKey('orderBy'), isFalse);
      expect(request.url.queryParameters.containsKey('timeMin'), isFalse);
      expect(request.url.queryParameters.containsKey('timeMax'), isFalse);
    });

    test('a 410 drops the cursor and performs exactly one full resync',
        () async {
      await secretStore.saveAccessToken('tok-A');
      client.script.addAll([
        (_) => _json({'error': {'code': 410, 'message': 'Sync token is no longer valid, a full sync is required.'}}, 410),
        (_) => _json(_page(
              items: [_event(id: 'e9@google', summary: 'Fresh')],
              nextSyncToken: 'NEW-SYNC',
            )),
      ]);
      final source = buildSource();

      final snapshot = await source.fetch(const SourceCursor('OLD-SYNC'));

      expect(snapshot.occurrences, hasLength(1));
      expect(snapshot.nextCursor?.value, 'NEW-SYNC');
      expect(client.requests, hasLength(2));

      final first = client.requests[0];
      expect(first.url.queryParameters['syncToken'], 'OLD-SYNC');
      expect(first.url.queryParameters.containsKey('orderBy'), isFalse);

      final second = client.requests[1];
      expect(second.url.queryParameters.containsKey('syncToken'), isFalse);
      expect(second.url.queryParameters['orderBy'], 'startTime');
      expect(second.url.queryParameters['timeMin'], isNotNull);
    });

    test('a 401 refreshes and retries once, then surfaces a reconnect error',
        () async {
      await secretStore.saveAccessToken('expired-token');
      await secretStore.saveRefreshToken('rt-1');
      client.script.addAll([
        (_) => _json(
            {'error': {'code': 401, 'message': 'Invalid Credentials'}}, 401),
        (_) => _json({
              'access_token': 'fresh-token',
              'token_type': 'Bearer',
              'expires_in': 3599,
            }),
        (_) => _json(
            {'error': {'code': 401, 'message': 'Invalid Credentials'}}, 401),
      ]);
      final source = buildSource();

      await expectLater(
        source.fetch(null),
        throwsA(
          isA<GoogleAuthorizationException>().having(
            (e) => e.message,
            'message',
            allOf(contains('authorisation'), contains('reconnect')),
          ),
        ),
      );

      // Exactly one refresh-and-retry: two events.list calls, one token call.
      expect(client.requests, hasLength(3));
      expect(
        client.requests
            .where((r) => r.url.path.endsWith('/events'))
            .length,
        2,
      );
      final refreshRequest =
          client.requests.singleWhere((r) => r.method == 'POST');
      expect(refreshRequest.bodyFields['grant_type'], 'refresh_token');
      expect(refreshRequest.bodyFields['refresh_token'], 'rt-1');
      expect(refreshRequest.bodyFields['client_id'], clientId);
      expect(refreshRequest.bodyFields.containsKey('client_secret'), isFalse);
      // The refreshed token was persisted before the retry.
      expect(backend.stored[SecretStore.accessTokenKey], 'fresh-token');
    });

    test('a failed refresh clears stored credentials and surfaces reconnect',
        () async {
      await secretStore.saveAccessToken('expired-token');
      await secretStore.saveRefreshToken('rt-dead');
      client.script.addAll([
        (_) => _json(
            {'error': {'code': 401, 'message': 'Invalid Credentials'}}, 401),
        (_) => _json({'error': 'invalid_grant'}, 400),
      ]);
      final source = buildSource();

      await expectLater(
        source.fetch(null),
        throwsA(isA<GoogleAuthorizationException>()),
      );
      expect(backend.stored[SecretStore.accessTokenKey], isNull);
      expect(backend.stored[SecretStore.refreshTokenKey], isNull);
    });

    test(
        'maps a video conference entry point into MeetingJoinInfo and a plain '
        'event into none', () async {
      await secretStore.saveAccessToken('tok-A');
      client.script.add((_) => _json(_page(
            items: [
              _event(
                id: 'meet@google',
                summary: 'Video call',
                conferenceData: _meetConference,
              ),
              _event(id: 'plain@google', summary: 'No conference'),
            ],
            nextSyncToken: 'SYNC-CONF',
          )));
      final source = buildSource();

      final snapshot = await source.fetch(null);

      expect(snapshot.occurrences, hasLength(2));
      final meeting = snapshot.occurrences
          .singleWhere((o) => o.event.id == 'meet@google');
      expect(
        meeting.joinInfo,
        const MeetingJoinInfo(
          url: 'https://meet.google.com/abc-defg-hij',
          provider: 'google_meet',
        ),
      );
      final plain = snapshot.occurrences
          .singleWhere((o) => o.event.id == 'plain@google');
      expect(plain.joinInfo, isNull);

      // conferenceData must be requested on the wire.
      final request = singleEventsListRequest();
      expect(request.url.queryParameters['conferenceDataVersion'], '1');
    });

    test('skips cancelled events and maps all-day date bounds', () async {
      await secretStore.saveAccessToken('tok-A');
      client.script.add((_) => _json(_page(
            items: [
              _event(id: 'gone@google', summary: 'Cancelled', status: 'cancelled'),
              _event(id: 'live@google', summary: 'Still on'),
              _allDayEvent(id: 'day@google', summary: 'All day'),
            ],
            nextSyncToken: 'SYNC-SKIP',
          )));
      final source = buildSource();

      final snapshot = await source.fetch(null);

      expect(snapshot.occurrences, hasLength(2));
      expect(
        snapshot.occurrences.map((o) => o.event.id),
        isNot(contains('gone@google')),
      );
      final allDay =
          snapshot.occurrences.singleWhere((o) => o.event.id == 'day@google');
      expect(allDay.isAllDay, isTrue);
      expect(allDay.startUtc, DateTime.utc(2026, 9, 19));
      expect(allDay.endUtc, DateTime.utc(2026, 9, 20));
    });

    test('throws SourcePermissionDeniedException without a stored token',
        () async {
      final source = buildSource();

      await expectLater(
        source.fetch(null),
        throwsA(isA<SourcePermissionDeniedException>()),
      );
      expect(client.requests, isEmpty);
    });
  });
}
