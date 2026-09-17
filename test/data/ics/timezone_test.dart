import 'dart:io';

import 'package:attention_copilot/data/ics/ics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

String fixture(String name) =>
    File('test/data/ics/fixtures/$name').readAsStringSync();

void main() {
  setUpAll(tzdata.initializeTimeZones);

  group('custom VTIMEZONE with DST transitions (Europe/Berlin)', () {
    late IcsCalendar cal;
    late List<IcsOccurrence> occs;

    setUp(() {
      cal = IcsParser().parse(fixture('berlin_dst.ics'));
      occs = cal.expandOccurrences(
        DateTime.utc(2026, 3, 28),
        DateTime.utc(2026, 10, 30),
      );
    });

    test('builds an embedded location from the VTIMEZONE block', () {
      expect(cal.embeddedTimezones.containsKey('Europe/Berlin'), isTrue);
    });

    test('an event before the spring transition lands on CET', () {
      // 2026-03-29 01:30 Berlin, still CET (+01:00) -> 00:30 UTC.
      final before = occs.firstWhere((o) => o.uid == 'dst-before@ac.test');
      expect(before.startUtc, DateTime.utc(2026, 3, 29, 0, 30));
      expect(before.timezoneName, 'Europe/Berlin');
    });

    test('an event after the spring transition lands on CEST', () {
      // The DST-change weekend event: 09:00 local on 2026-03-29 is CEST
      // (+02:00) -> 07:00 UTC, not 08:00.
      final after = occs.firstWhere((o) => o.uid == 'dst-after@ac.test');
      expect(after.startUtc, DateTime.utc(2026, 3, 29, 7));
      expect(after.endUtc, DateTime.utc(2026, 3, 29, 7, 30));
    });

    test('a winter event lands back on CET', () {
      final winter = occs.firstWhere((o) => o.uid == 'dst-winter@ac.test');
      expect(winter.startUtc, DateTime.utc(2026, 10, 26, 8));
    });
  });

  test('a VTIMEZONE with a TZID absent from the IANA database still resolves',
      () {
    final cal = IcsParser().parse(fixture('custom_zone.ics'));
    final occs = cal.expandOccurrences(
      DateTime.utc(2026, 9, 16),
      DateTime.utc(2026, 9, 18),
    );
    // Custom/Atlantis: +03:00 in September 2026 (DST until last Sunday of
    // October) -> 09:00 local = 06:00 UTC.
    final atlantis = occs.firstWhere((o) => o.uid == 'atlantis@ac.test');
    expect(atlantis.startUtc, DateTime.utc(2026, 9, 17, 6));
    expect(atlantis.timezoneName, 'Custom/Atlantis');
    expect(cal.diagnostics, isEmpty);
  });

  test('an unknown TZID falls back to the IANA database', () {
    final cal = IcsParser().parse(fixture('iana_fallback.ics'));
    expect(cal.embeddedTimezones, isEmpty);
    final occs = cal.expandOccurrences(
      DateTime.utc(2026, 9, 16),
      DateTime.utc(2026, 9, 18),
    );
    final ev = occs.single;
    // September 2026 in Europe/Berlin is CEST (+02:00).
    expect(ev.startUtc, DateTime.utc(2026, 9, 17, 7));
    expect(ev.timezoneName, 'Europe/Berlin');
    expect(cal.diagnostics, isEmpty);
  });

  test('an unresolvable TZID is recorded as a diagnostic and resolved '
      'against the floating zone, never silently trusted', () {
    final body = 'BEGIN:VCALENDAR\n'
        'VERSION:2.0\n'
        'BEGIN:VEVENT\n'
        'UID:mars@ac.test\n'
        'SUMMARY:Mars time\n'
        'DTSTART;TZID=Mars/Olympus:20260917T090000\n'
        'DTEND;TZID=Mars/Olympus:20260917T093000\n'
        'END:VEVENT\n'
        'END:VCALENDAR\n';
    final cal = IcsParser().parse(body);
    final occs = cal.expandOccurrences(
      DateTime.utc(2026, 9, 16),
      DateTime.utc(2026, 9, 18),
    );
    expect(occs, hasLength(1));
    // Floating zone defaults to UTC: wall time kept as-is.
    expect(occs.single.startUtc, DateTime.utc(2026, 9, 17, 9));
    expect(cal.diagnostics.any((d) => d.message.contains('Mars/Olympus')),
        isTrue);
  });

  group('floating time (no TZID, no Z)', () {
    test('resolves against the supplied floating zone', () {
      final vienna = tz.getLocation('Europe/Vienna');
      final cal =
          IcsParser(floatingZone: vienna).parse(fixture('floating_time.ics'));
      final occs = cal.expandOccurrences(
        DateTime.utc(2026, 9, 16),
        DateTime.utc(2026, 9, 20),
      );
      final timed = occs.firstWhere((o) => o.uid == 'floating@ac.test');
      // 14:00 wall in Europe/Vienna (CEST, +02:00) -> 12:00 UTC.
      expect(timed.startUtc, DateTime.utc(2026, 9, 17, 12));
      expect(timed.timezoneName, isNull);
      expect(timed.isAllDay, isFalse);
    });

    test('defaults to UTC when no floating zone is configured', () {
      final cal = IcsParser().parse(fixture('floating_time.ics'));
      final occs = cal.expandOccurrences(
        DateTime.utc(2026, 9, 16),
        DateTime.utc(2026, 9, 20),
      );
      final timed = occs.firstWhere((o) => o.uid == 'floating@ac.test');
      expect(timed.startUtc, DateTime.utc(2026, 9, 17, 14));
    });
  });
}
