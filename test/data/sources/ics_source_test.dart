import 'dart:convert';

import 'package:attention_copilot/data/ics/ics.dart';
import 'package:attention_copilot/data/sources/ics_source.dart';
import 'package:attention_copilot/data/sources/source.dart';
import 'package:attention_copilot/data/storage/agenda_cache.dart';
import 'package:attention_copilot/data/storage/secret_store.dart';
import 'package:attention_copilot/domain/models/meeting_join_info.dart';
import 'package:flutter_test/flutter_test.dart';

/// Scripted HTTP client: serves the queued responses in order and records
/// every request URL and header map for assertions.
class FakeIcsHttpClient implements IcsHttpClient {
  FakeIcsHttpClient(this._responses);

  final List<IcsHttpResponse> _responses;
  final List<({Uri url, Map<String, String> headers})> requests = [];

  @override
  Future<IcsHttpResponse> get(Uri url, {Map<String, String>? headers}) async {
    requests.add((url: url, headers: Map.of(headers ?? const {})));
    if (_responses.isEmpty) {
      throw StateError('No scripted response left for $url');
    }
    return _responses.removeAt(0);
  }
}

/// Counts parser invocations so tests can prove a 304 (or an unchanged body)
/// never reparses the feed.
class CountingIcsParser extends IcsParser {
  int parseCount = 0;

  @override
  IcsCalendar parse(String body) {
    parseCount++;
    return super.parse(body);
  }
}

/// In-memory secret backend for assertions about the bearer URL.
class MemorySecretBackend implements SecureKeyValueBackend {
  final Map<String, String> store = {};

  @override
  Future<String?> read(String key) async => store[key];

  @override
  Future<void> write(String key, String value) async => store[key] = value;

  @override
  Future<void> delete(String key) async => store.remove(key);
}

IcsHttpResponse ok(
  String body, {
  String? etag,
  String? lastModified,
}) {
  final headers = <String, String>{'content-type': 'text/calendar'};
  if (etag != null) {
    headers['etag'] = etag;
  }
  if (lastModified != null) {
    headers['last-modified'] = lastModified;
  }
  return IcsHttpResponse(statusCode: 200, body: body, headers: headers);
}

const IcsHttpResponse notModified =
    IcsHttpResponse(statusCode: 304, body: '');

/// Fixture: one simple UTC event inside the test window
/// ([2026-09-17T08:00Z, +24h)).
const String basicFeed = '''
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//attention-copilot//test//EN
BEGIN:VEVENT
UID:standup@ics.test
SUMMARY:Standup
LOCATION:Room 1
DTSTART:20260917T090000Z
DTEND:20260917T093000Z
END:VEVENT
END:VCALENDAR
''';

/// Fixture exercising the join-URL heuristic: X-GOOGLE-CONFERENCE, a `URL`
/// property, a Zoom link in LOCATION, a Teams link in DESCRIPTION and one
/// event without any join information.
const String joinFeed = '''
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//attention-copilot//test//EN
BEGIN:VEVENT
UID:conference@ics.test
SUMMARY:Google meet
DTSTART:20260917T090000Z
DTEND:20260917T093000Z
X-GOOGLE-CONFERENCE:https://meet.google.com/xyz-uvw-rst
END:VEVENT
BEGIN:VEVENT
UID:urlprop@ics.test
SUMMARY:Has URL property
DTSTART:20260917T100000Z
DTEND:20260917T103000Z
URL:https://meet.google.com/abc-defg-hij
END:VEVENT
BEGIN:VEVENT
UID:zoom@ics.test
SUMMARY:Zoom event
DTSTART:20260917T110000Z
DTEND:20260917T113000Z
LOCATION:Room B - join https://us02web.zoom.us/j/123456789
END:VEVENT
BEGIN:VEVENT
UID:teams@ics.test
SUMMARY:Teams event
DTSTART:20260917T120000Z
DTEND:20260917T123000Z
DESCRIPTION:Call details https://teams.microsoft.com/l/meetup-join/xyz
END:VEVENT
BEGIN:VEVENT
UID:plain@ics.test
SUMMARY:Plain event
DTSTART:20260917T130000Z
DTEND:20260917T133000Z
DESCRIPTION:no link here
END:VEVENT
END:VCALENDAR
''';

/// A calendar whose only purpose is to carry a refresh hint.
String refreshFeed(String hintLine) => '''
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//attention-copilot//test//EN
$hintLine
END:VCALENDAR
''';

IcsSource buildSource({
  required FakeIcsHttpClient client,
  String url = 'https://cal.example.com/feed.ics',
  IcsParser? parser,
  SecretStore? secretStore,
  double Function()? jitter,
  List<String>? logLines,
}) {
  return IcsSource(
    url: url,
    httpClient: client,
    parser: parser ?? IcsParser(),
    secretStore: secretStore ?? SecretStore(backend: MemorySecretBackend()),
    clock: () => DateTime.utc(2026, 9, 17, 8),
    jitter: jitter ?? () => 0,
    logger: logLines == null ? (_) {} : logLines.add,
  );
}

void main() {
  group('webcal URL normalisation', () {
    test('normalizeFeedUrl maps webcal and webcals to https', () {
      expect(
        normalizeFeedUrl('webcal://cal.example.com/team.ics').toString(),
        'https://cal.example.com/team.ics',
      );
      expect(
        normalizeFeedUrl('webcals://cal.example.com/team.ics').toString(),
        'https://cal.example.com/team.ics',
      );
      // A plain https URL is untouched.
      expect(
        normalizeFeedUrl('https://cal.example.com/team.ics').toString(),
        'https://cal.example.com/team.ics',
      );
    });

    test('fetch requests the normalised https URL', () async {
      final client = FakeIcsHttpClient([ok(basicFeed)]);
      final source = buildSource(
        client: client,
        url: 'webcal://cal.example.com/feed.ics',
      );
      await source.fetch(null);
      expect(client.requests, hasLength(1));
      expect(client.requests.single.url.scheme, 'https');
      expect(client.requests.single.url.host, 'cal.example.com');
    });
  });

  group('conditional requests', () {
    test('a cursor with ETag and Last-Modified sends both validators',
        () async {
      final client = FakeIcsHttpClient([
        ok(basicFeed, etag: '"v1"', lastModified: 'Wed, 17 Sep 2026 07:00:00 GMT'),
        notModified,
      ]);
      final source = buildSource(client: client);
      final first = await source.fetch(null);
      final cursorValue = first.nextCursor!.value;
      expect(cursorValue, isA<IcsSourceCursor>());
      final cursor = cursorValue as IcsSourceCursor;
      expect(cursor.etag, '"v1"');
      expect(cursor.lastModified, 'Wed, 17 Sep 2026 07:00:00 GMT');
      expect(cursor.contentHash, isNotEmpty);

      await source.fetch(first.nextCursor);
      expect(client.requests, hasLength(2));
      expect(client.requests[1].headers['if-none-match'], '"v1"');
      expect(
        client.requests[1].headers['if-modified-since'],
        'Wed, 17 Sep 2026 07:00:00 GMT',
      );
    });

    test('a 304 reparses nothing, returns no occurrences and keeps the cursor',
        () async {
      final client = FakeIcsHttpClient([
        ok(basicFeed, etag: '"v1"'),
        notModified,
      ]);
      final parser = CountingIcsParser();
      final source = buildSource(client: client, parser: parser);

      final first = await source.fetch(null);
      expect(first.occurrences, hasLength(1));

      final second = await source.fetch(first.nextCursor);
      expect(second.occurrences, isEmpty);
      expect(second.nextCursor, isNotNull);
      expect(second.nextCursor!.value, first.nextCursor!.value);
      expect(parser.parseCount, 1, reason: '304 must not trigger a reparse');
    });

    test('an unchanged 200 body reparses nothing and yields no occurrences',
        () async {
      final client = FakeIcsHttpClient([
        ok(basicFeed, etag: '"v1"'),
        // Server ignored the validators and returned the same body again.
        ok(basicFeed, etag: '"v1"'),
      ]);
      final parser = CountingIcsParser();
      final source = buildSource(client: client, parser: parser);

      final first = await source.fetch(null);
      expect(first.occurrences, hasLength(1));

      final second = await source.fetch(first.nextCursor);
      expect(second.occurrences, isEmpty);
      expect(parser.parseCount, 1,
          reason: 'identical content must not be reparsed');
    });
  });

  group('refresh cadence', () {
    Future<Duration> pollIntervalFor(String hintLine) async {
      final client = FakeIcsHttpClient([ok(refreshFeed(hintLine))]);
      final source = buildSource(client: client);
      await source.fetch(null);
      return source.pollInterval;
    }

    test('REFRESH-INTERVAL:PT1H yields a 60-minute interval', () async {
      expect(
        await pollIntervalFor('REFRESH-INTERVAL;VALUE=DURATION:PT1H'),
        const Duration(minutes: 60),
      );
    });

    test('REFRESH-INTERVAL:PT1M is clamped to the 15-minute floor', () async {
      expect(
        await pollIntervalFor('REFRESH-INTERVAL;VALUE=DURATION:PT1M'),
        const Duration(minutes: 15),
      );
    });

    test('X-PUBLISHED-TTL is used when REFRESH-INTERVAL is absent', () async {
      expect(
        await pollIntervalFor('X-PUBLISHED-TTL:PT2H'),
        const Duration(minutes: 120),
      );
    });

    test('no hint falls back to the 30-minute default', () async {
      expect(await pollIntervalFor(''), const Duration(minutes: 30));
    });

    test('jitter scales the cadence up but never below the clamped base',
        () async {
      final client = FakeIcsHttpClient([
        ok(refreshFeed('REFRESH-INTERVAL;VALUE=DURATION:PT1M')),
      ]);
      final source = buildSource(
        client: client,
        jitter: () => 0.5,
      );
      await source.fetch(null);
      // Base is clamped to 15 min; jitter multiplies by (1 + 0.5).
      expect(source.pollInterval, const Duration(minutes: 15));
      expect(source.nextPollInterval, const Duration(minutes: 22, seconds: 30));
      // No jitter -> cadence equals the base exactly.
      final zeroJitter = buildSource(
        client: FakeIcsHttpClient([
          ok(refreshFeed('REFRESH-INTERVAL;VALUE=DURATION:PT1M')),
        ]),
        jitter: () => 0,
      );
      await zeroJitter.fetch(null);
      expect(zeroJitter.nextPollInterval, zeroJitter.pollInterval);
    });
  });

  group('occurrence conversion', () {
    test('occurrences carry title, instants, uid identity and source', () async {
      final client = FakeIcsHttpClient([ok(basicFeed)]);
      final source = buildSource(client: client);
      final snapshot = await source.fetch(null);

      expect(snapshot.occurrences, hasLength(1));
      final occurrence = snapshot.occurrences.single;
      expect(occurrence.title, 'Standup');
      expect(occurrence.location, 'Room 1');
      expect(occurrence.startUtc, DateTime.utc(2026, 9, 17, 9));
      expect(occurrence.endUtc, DateTime.utc(2026, 9, 17, 9, 30));
      expect(occurrence.isAllDay, isFalse);
      expect(occurrence.event.id, 'standup@ics.test');
      expect(occurrence.id, contains('standup@ics.test'));
      expect(occurrence.source.id, startsWith('ics:'));
    });
  });

  group('join URL mapping', () {
    test('maps URL, X-GOOGLE-CONFERENCE and recognised provider links',
        () async {
      final client = FakeIcsHttpClient([ok(joinFeed)]);
      final source = buildSource(client: client);
      final snapshot = await source.fetch(null);

      MeetingJoinInfo? joinFor(String eventId) => snapshot.occurrences
          .firstWhere((o) => o.event.id == eventId)
          .joinInfo;

      final conference = joinFor('conference@ics.test');
      expect(conference, isNotNull);
      expect(conference!.url, 'https://meet.google.com/xyz-uvw-rst');
      expect(conference.provider, 'google_meet');

      final urlProp = joinFor('urlprop@ics.test');
      expect(urlProp, isNotNull);
      expect(urlProp!.url, 'https://meet.google.com/abc-defg-hij');
      expect(urlProp.provider, 'google_meet');

      final zoom = joinFor('zoom@ics.test');
      expect(zoom, isNotNull);
      expect(zoom!.url, 'https://us02web.zoom.us/j/123456789');
      expect(zoom.provider, 'zoom');

      final teams = joinFor('teams@ics.test');
      expect(teams, isNotNull);
      expect(teams!.url, 'https://teams.microsoft.com/l/meetup-join/xyz');
      expect(teams.provider, 'teams');

      expect(joinFor('plain@ics.test'), isNull);
    });
  });

  group('bearer URL hygiene', () {
    const secretUrl =
        'https://calendar.google.com/calendar/ical/team%40example.com/'
        'private-S3CR3T-bearer-token/basic.ics';

    test('the bearer URL is stored in SecretStore, never logged and never '
        'serialised into cursor or cache', () async {
      final client = FakeIcsHttpClient([ok(basicFeed, etag: '"v1"')]);
      final backend = MemorySecretBackend();
      final secretStore = SecretStore(backend: backend);
      final logLines = <String>[];
      final source = buildSource(
        client: client,
        url: secretUrl,
        secretStore: secretStore,
        logLines: logLines,
      );

      final snapshot = await source.fetch(null);

      // The URL (with its bearer token) lives in the SecretStore seam.
      expect(backend.store[SecretStore.icsBearerUrlKey], secretUrl);
      expect(await secretStore.readIcsBearerUrl(), secretUrl);

      // The request did go to the full secret URL - but nothing logged it.
      expect(client.requests.single.url.toString(), secretUrl);

      // No log line may contain the bearer URL or any recognisable part of it.
      final forbiddenFragments = ['S3CR3T', 'private-', secretUrl];
      for (final line in logLines) {
        for (final fragment in forbiddenFragments) {
          expect(line, isNot(contains(fragment)),
              reason: 'log line leaks the bearer URL: $line');
        }
      }
      expect(logLines, isNotEmpty);

      // The cursor payload serialises without the URL.
      final cursor = snapshot.nextCursor!.value as IcsSourceCursor;
      final cursorJson = jsonEncode(cursor.toJson());
      expect(cursorJson, isNot(contains('S3CR3T')));
      expect(cursorJson, isNot(contains('calendar.google.com')));

      // The persisted cache cursor shape is URL-free as well.
      final cacheData = AgendaCacheData(
        schemaVersion: AgendaCacheData.currentSchemaVersion,
        fetchedAt: DateTime.utc(2026, 9, 17, 8),
        cursors: {
          source.id: cursor.toAgendaCursor(),
        },
      );
      final cacheJson = jsonEncode(cacheData.toJson());
      expect(cacheJson, isNot(contains('S3CR3T')));
      expect(cacheJson, isNot(contains('calendar.google.com')));
      expect(cacheJson, contains('"etag":"\\"v1\\""'));
    });

    test('a cursor restored from the agenda cache still sends validators',
        () async {
      final client = FakeIcsHttpClient([notModified]);
      final source = buildSource(client: client);
      final snapshot = await source.fetch(
        const SourceCursor(AgendaSourceCursor(
          etag: '"cached-etag"',
          lastModified: 'Wed, 17 Sep 2026 06:00:00 GMT',
        )),
      );
      expect(snapshot.occurrences, isEmpty);
      expect(client.requests.single.headers['if-none-match'], '"cached-etag"');
      expect(
        client.requests.single.headers['if-modified-since'],
        'Wed, 17 Sep 2026 06:00:00 GMT',
      );
    });
  });
}
