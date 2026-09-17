import 'dart:io';

import 'package:attention_copilot/data/ics/ics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;

String fixture(String name) =>
    File('test/data/ics/fixtures/$name').readAsStringSync();

void main() {
  setUpAll(tzdata.initializeTimeZones);

  group('unfolding and content-line tokenising', () {
    test('unfolds CRLF+space and LF+tab continuations', () {
      // RFC 5545 section 3.1: a fold is CRLF + one linear whitespace
      // character, and unfolding removes both - so text producers keep the
      // separating space at the end of the first physical line.
      final body = 'BEGIN:VCALENDAR\r\n'
          'VERSION:2.0\r\n'
          'BEGIN:VEVENT\r\n'
          'UID:folded@ac.test\r\n'
          'SUMMARY:Line one \r\n'
          ' continues here\r\n'
          'DESCRIPTION:Tabbed \r\n'
          '\tcontinuation\r\n'
          'DTSTART:20260917T090000Z\r\n'
          'DTEND:20260917T093000Z\r\n'
          'END:VEVENT\r\n'
          'END:VCALENDAR\r\n';
      final cal = IcsParser().parse(body);
      expect(cal.events, hasLength(1));
      expect(cal.events.single.summary, 'Line one continues here');
      expect(cal.events.single.description, 'Tabbed continuation');
      expect(cal.diagnostics, isEmpty);
    });

    test('accepts bare LF line endings', () {
      final body = 'BEGIN:VCALENDAR\n'
          'VERSION:2.0\n'
          'BEGIN:VEVENT\n'
          'UID:lf@ac.test\n'
          'SUMMARY:Unix newlines\n'
          'DTSTART:20260917T090000Z\n'
          'DTEND:20260917T093000Z\n'
          'END:VEVENT\n'
          'END:VCALENDAR\n';
      final cal = IcsParser().parse(body);
      expect(cal.events.single.summary, 'Unix newlines');
    });

    test('parses quoted parameter values containing colons and commas', () {
      final line = IcsContentLine.parse('X-TEST;FOO="a:b,c";BAR=plain:value');
      expect(line.name, 'X-TEST');
      expect(line.params['FOO'], ['a:b,c']);
      expect(line.params['BAR'], ['plain']);
      expect(line.value, 'value');
    });

    test('parses multi-value parameters', () {
      final line = IcsContentLine.parse('RDATE;TZID=Europe/Vienna:'
          '20260917T090000,20260918T090000');
      expect(line.name, 'RDATE');
      expect(line.params['TZID'], ['Europe/Vienna']);
      expect(line.value, '20260917T090000,20260918T090000');
    });
  });

  group('google secret-address export', () {
    test('parses header, events, reminders and defaults the poll interval',
        () {
      final cal = IcsParser().parse(fixture('google_secret_address.ics'));
      expect(cal.prodId, startsWith('-//Google Inc//Google Calendar'));
      expect(cal.calendarName, 'Horst Rohrweck');
      expect(cal.refreshInterval, isNull);
      expect(cal.publishedTtl, isNull);
      expect(cal.pollInterval, const Duration(minutes: 30));
      expect(cal.events, hasLength(2));
      expect(cal.diagnostics, isEmpty);

      final standup = cal.events.firstWhere(
        (e) => e.uid == '1a2b3c4d5e6f7a8b@google.com',
      );
      expect(standup.summary, 'Team standup');
      expect(standup.description, contains('\n'));
      expect(standup.location, 'Meeting room 3');
      expect(standup.url, 'https://meet.google.com/abc-defg-hij');
      expect(standup.isAllDay, isFalse);
      expect(standup.timezoneName, 'Europe/Vienna');
      expect(standup.status, 'CONFIRMED');

      // VALARM surfaced as provider reminders, never as our scheduling source.
      expect(standup.reminders, hasLength(2));
      final display = standup.reminders.firstWhere(
        (r) => r.action == 'DISPLAY',
      );
      expect(display.trigger, const Duration(minutes: -10));
      expect(display.relativeToEnd, isFalse);
      expect(display.description, 'This is an event reminder');
      final audio = standup.reminders.firstWhere(
        (r) => r.action == 'AUDIO',
      );
      expect(audio.trigger, const Duration(minutes: -1));
      expect(audio.repeatCount, 2);
      expect(audio.repeatInterval, const Duration(minutes: 5));
    });

    test('resolves Vienna TZID through the embedded VTIMEZONE', () {
      final cal = IcsParser().parse(fixture('google_secret_address.ics'));
      expect(cal.embeddedTimezones.containsKey('Europe/Vienna'), isTrue);
      final occs = cal.expandOccurrences(
        DateTime.utc(2026, 9, 16),
        DateTime.utc(2026, 9, 18),
      );
      final standup = occs.firstWhere(
        (o) => o.uid == '1a2b3c4d5e6f7a8b@google.com',
      );
      // 2026-09-17 09:00 Europe/Vienna is CEST (+02:00) -> 07:00 UTC.
      expect(standup.startUtc, DateTime.utc(2026, 9, 17, 7));
      expect(standup.endUtc, DateTime.utc(2026, 9, 17, 8));
      expect(standup.timezoneName, 'Europe/Vienna');
      expect(standup.reminders, isNotEmpty);
    });
  });

  group('refresh hints', () {
    test('X-PUBLISHED-TTL drives the poll interval (Outlook fixture)',
        () {
      final cal = IcsParser().parse(fixture('outlook_sharepoint.ics'));
      expect(cal.publishedTtl, const Duration(minutes: 90));
      expect(cal.pollInterval, const Duration(minutes: 90));
      expect(cal.calendarName, 'Project Calendar');
      expect(cal.events, hasLength(1));
      expect(cal.events.single.uid,
          '040000008200E00074C5B7101A82E00800000000ABCDEF0123456789ABCDEF01234567');
    });

    test('REFRESH-INTERVAL below 15 minutes is clamped', () {
      final cal = IcsParser().parse(fixture('refresh_clamp.ics'));
      expect(cal.refreshInterval, const Duration(minutes: 1));
      expect(cal.pollInterval, const Duration(minutes: 15));
    });

    test('REFRESH-INTERVAL wins over X-PUBLISHED-TTL', () {
      final cal = IcsParser().parse(fixture('refresh_precedence.ics'));
      expect(cal.refreshInterval, const Duration(minutes: 60));
      expect(cal.publishedTtl, const Duration(minutes: 30));
      expect(cal.pollInterval, const Duration(minutes: 60));
    });
  });

  group('malformed input never throws into the agenda', () {
    test('truncated mid-VEVENT yields partial results plus diagnostics', () {
      final body = fixture('google_secret_address.ics');
      final cut = body.lastIndexOf('SUMMARY:Lunch');
      final truncated = body.substring(0, cut);
      final cal = IcsParser().parse(truncated);
      // The standup VEVENT was complete: it must survive.
      expect(
        cal.events.map((e) => e.uid),
        contains('1a2b3c4d5e6f7a8b@google.com'),
      );
      expect(cal.diagnostics, isNotEmpty);
    });

    test('garbage and empty input produce an empty calendar, no throw', () {
      final empty = IcsParser().parse('');
      expect(empty.events, isEmpty);
      expect(empty.pollInterval, const Duration(minutes: 30));

      final garbage = IcsParser().parse('THIS IS NOT AN ICS AT ALL\n'
          'RANDOM;KEY=value:stuff\n');
      expect(garbage.events, isEmpty);
      expect(garbage.diagnostics, isNotEmpty);
    });

    test('a VEVENT without DTSTART is skipped with a diagnostic', () {
      final body = 'BEGIN:VCALENDAR\n'
          'VERSION:2.0\n'
          'BEGIN:VEVENT\n'
          'UID:nostart@ac.test\n'
          'SUMMARY:Broken\n'
          'END:VEVENT\n'
          'BEGIN:VEVENT\n'
          'UID:ok@ac.test\n'
          'DTSTART:20260917T090000Z\n'
          'DTEND:20260917T093000Z\n'
          'SUMMARY:Fine\n'
          'END:VEVENT\n'
          'END:VCALENDAR\n';
      final cal = IcsParser().parse(body);
      expect(cal.events.map((e) => e.uid), ['ok@ac.test']);
      expect(cal.diagnostics, isNotEmpty);
    });
  });
}
