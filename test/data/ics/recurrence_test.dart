import 'dart:io';

import 'package:attention_copilot/data/ics/ics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;

String fixture(String name) =>
    File('test/data/ics/fixtures/$name').readAsStringSync();

String calendarWith(String eventBlock) => 'BEGIN:VCALENDAR\n'
    'VERSION:2.0\n'
    'PRODID:-//attention-copilot//tests//EN\n'
    '$eventBlock\n'
    'END:VCALENDAR\n';

void main() {
  setUpAll(tzdata.initializeTimeZones);

  group('RRULE expansion with RECURRENCE-ID overrides', () {
    late IcsCalendar cal;
    late List<IcsOccurrence> occs;

    setUp(() {
      cal = IcsParser().parse(fixture('rrule_override.ics'));
      occs = cal.expandOccurrences(
        DateTime.utc(2026, 1, 1),
        DateTime.utc(2026, 3, 1),
      );
    });

    test('a single-instance override replaces the master instance', () {
      final mo = occs
          .where((o) => o.uid == 'weekly-mo@ac.test')
          .toList()
        ..sort((a, b) => a.startUtc.compareTo(b.startUtc));
      expect(mo, hasLength(8)); // 8 Mondays, no duplicate
      final replaced = mo[2];
      expect(replaced.startUtc, DateTime.utc(2026, 1, 19, 14));
      expect(replaced.endUtc, DateTime.utc(2026, 1, 19, 15));
      expect(replaced.summary, 'Monday standup (moved)');
      expect(replaced.fromOverride, isTrue);
      expect(replaced.recurrenceId, DateTime.utc(2026, 1, 19, 10));
      // The master 10:00 instance must not appear.
      expect(
        mo.where((o) => o.startUtc == DateTime.utc(2026, 1, 19, 10)),
        isEmpty,
      );
      // Neighbouring master instances are untouched.
      expect(mo[1].startUtc, DateTime.utc(2026, 1, 12, 10));
      expect(mo[1].summary, 'Monday standup');
      expect(mo[1].fromOverride, isFalse);
    });

    test('RANGE=THISANDFUTURE starts a new series at the override', () {
      final tu = occs
          .where((o) => o.uid == 'weekly-tu@ac.test')
          .toList()
        ..sort((a, b) => a.startUtc.compareTo(b.startUtc));
      expect(tu, hasLength(8)); // 5 before + 3 after the cutoff
      final before = tu.where((o) => o.startUtc.isBefore(
          DateTime.utc(2026, 2, 10))).toList();
      expect(before, hasLength(5));
      for (final o in before) {
        expect(o.startUtc.hour, 9);
        expect(o.summary, 'Tuesday workshop');
      }
      final after = tu.where((o) =>
          !o.startUtc.isBefore(DateTime.utc(2026, 2, 10))).toList();
      expect(after, hasLength(3));
      expect(after.map((o) => o.startUtc), [
        DateTime.utc(2026, 2, 10, 11),
        DateTime.utc(2026, 2, 17, 11),
        DateTime.utc(2026, 2, 24, 11),
      ]);
      for (final o in after) {
        expect(o.summary, 'Tuesday workshop (new time)');
      }
    });

    test('a CANCELLED override removes the instance', () {
      final we = occs
          .where((o) => o.uid == 'weekly-we@ac.test')
          .toList()
        ..sort((a, b) => a.startUtc.compareTo(b.startUtc));
      expect(we, hasLength(7));
      expect(
        we.where((o) => o.startUtc == DateTime.utc(2026, 1, 21, 16)),
        isEmpty,
      );
    });

    test('expansion honours the window bounds', () {
      final narrow = cal.expandOccurrences(
        DateTime.utc(2026, 1, 10),
        DateTime.utc(2026, 1, 20),
      );
      final mo = narrow.where((o) => o.uid == 'weekly-mo@ac.test').toList();
      expect(mo.map((o) => o.startUtc), [
        DateTime.utc(2026, 1, 12, 10),
        DateTime.utc(2026, 1, 19, 14), // still replaced inside the window
      ]);
    });

    test('an orphan override without a master instance is still surfaced',
        () {
      final body = calendarWith('BEGIN:VEVENT\n'
          'UID:orphan@ac.test\n'
          'SUMMARY:Master\n'
          'DTSTART:20260105T100000Z\n'
          'DTEND:20260105T110000Z\n'
          'RRULE:FREQ=WEEKLY;BYDAY=MO\n'
          'END:VEVENT\n'
          'BEGIN:VEVENT\n'
          'UID:orphan@ac.test\n'
          'SUMMARY:Orphan move\n'
          'RECURRENCE-ID:20260107T100000Z\n'
          'DTSTART:20260107T140000Z\n'
          'DTEND:20260107T150000Z\n'
          'END:VEVENT\n');
      final orphanCal = IcsParser().parse(body);
      final orphanOccs = orphanCal.expandOccurrences(
        DateTime.utc(2026, 1, 1),
        DateTime.utc(2026, 2, 1),
      );
      final orphan = orphanOccs.firstWhere(
        (o) => o.summary == 'Orphan move',
      );
      expect(orphan.startUtc, DateTime.utc(2026, 1, 7, 14));
      expect(orphan.fromOverride, isTrue);
      // Masters keep coming (4 Mondays inside the window).
      expect(
        orphanOccs.where((o) => o.uid == 'orphan@ac.test'),
        hasLength(5),
      );
    });
  });

  group('all-day recurring events', () {
    test('weekly and counted daily all-day rules expand as dates', () {
      final cal = IcsParser().parse(fixture('allday_recurring.ics'));
      final occs = cal.expandOccurrences(
        DateTime.utc(2026, 9, 1),
        DateTime.utc(2026, 11, 1),
      );
      final weekly = occs
          .where((o) => o.uid == 'allday-weekly@ac.test')
          .toList()
        ..sort((a, b) => a.startUtc.compareTo(b.startUtc));
      expect(weekly, hasLength(7));
      expect(weekly.first.startUtc, DateTime.utc(2026, 9, 14));
      expect(weekly.first.endUtc, DateTime.utc(2026, 9, 15)); // exclusive
      expect(weekly.last.startUtc, DateTime.utc(2026, 10, 26));
      for (final o in weekly) {
        expect(o.isAllDay, isTrue);
      }

      final daily = occs
          .where((o) => o.uid == 'allday-daily-count@ac.test')
          .toList()
        ..sort((a, b) => a.startUtc.compareTo(b.startUtc));
      expect(daily.map((o) => o.startUtc), [
        DateTime.utc(2026, 10, 1),
        DateTime.utc(2026, 10, 2),
        DateTime.utc(2026, 10, 3),
      ]);
    });
  });

  group('RRULE forms', () {
    List<IcsOccurrence> expand(String eventBlock,
        {DateTime? from, DateTime? to}) {
      final cal = IcsParser().parse(calendarWith(eventBlock));
      return cal.expandOccurrences(
        from ?? DateTime.utc(2025, 1, 1),
        to ?? DateTime.utc(2028, 1, 1),
      );
    }

    test('MONTHLY with BYDAY ordinal picks the nth weekday', () {
      final occs = expand('BEGIN:VEVENT\n'
          'UID:m@ac.test\n'
          'DTSTART:20260105T100000Z\n'
          'DTEND:20260105T110000Z\n'
          'RRULE:FREQ=MONTHLY;BYDAY=2MO;COUNT=3\n'
          'END:VEVENT\n');
      expect(occs.map((o) => o.startUtc), [
        DateTime.utc(2026, 1, 12, 10),
        DateTime.utc(2026, 2, 9, 10),
        DateTime.utc(2026, 3, 9, 10),
      ]);
    });

    test('YEARLY with BYMONTH and negative BYDAY ordinal (DST-rule style)',
        () {
      final occs = expand('BEGIN:VEVENT\n'
          'UID:y@ac.test\n'
          'DTSTART:20251026T020000Z\n'
          'DTEND:20251026T030000Z\n'
          'RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU;COUNT=3\n'
          'END:VEVENT\n');
      expect(occs.map((o) => o.startUtc), [
        DateTime.utc(2025, 10, 26, 2),
        DateTime.utc(2026, 10, 25, 2),
        DateTime.utc(2027, 10, 31, 2),
      ]);
    });

    test('UNTIL is inclusive', () {
      final occs = expand('BEGIN:VEVENT\n'
          'UID:u@ac.test\n'
          'DTSTART:20260101T000000Z\n'
          'DTEND:20260101T010000Z\n'
          'RRULE:FREQ=DAILY;UNTIL=20260105T000000Z\n'
          'END:VEVENT\n');
      expect(occs, hasLength(5));
      expect(occs.last.startUtc, DateTime.utc(2026, 1, 5));
    });

    test('EXDATE removes instances from the set', () {
      final occs = expand('BEGIN:VEVENT\n'
          'UID:x@ac.test\n'
          'DTSTART:20260101T000000Z\n'
          'DTEND:20260101T010000Z\n'
          'RRULE:FREQ=DAILY;COUNT=4\n'
          'EXDATE:20260102T000000Z\n'
          'END:VEVENT\n');
      expect(occs.map((o) => o.startUtc), [
        DateTime.utc(2026, 1, 1),
        DateTime.utc(2026, 1, 3),
        DateTime.utc(2026, 1, 4),
      ]);
    });

    test('RDATE adds instances and deduplicates overlaps', () {
      final occs = expand('BEGIN:VEVENT\n'
          'UID:r@ac.test\n'
          'DTSTART:20260917T090000Z\n'
          'DTEND:20260917T100000Z\n'
          'RDATE:20260917T090000Z,20260918T090000Z,20260919T090000Z\n'
          'END:VEVENT\n');
      expect(occs.map((o) => o.startUtc), [
        DateTime.utc(2026, 9, 17, 9),
        DateTime.utc(2026, 9, 18, 9),
        DateTime.utc(2026, 9, 19, 9),
      ]);
    });

    test('INTERVAL steps the frequency', () {
      final occs = expand('BEGIN:VEVENT\n'
          'UID:i@ac.test\n'
          'DTSTART:20260105T100000Z\n'
          'DTEND:20260105T110000Z\n'
          'RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO\n'
          'END:VEVENT\n',
          from: DateTime.utc(2026, 1, 1), to: DateTime.utc(2026, 3, 5));
      expect(occs.map((o) => o.startUtc), [
        DateTime.utc(2026, 1, 5, 10),
        DateTime.utc(2026, 1, 19, 10),
        DateTime.utc(2026, 2, 2, 10),
        DateTime.utc(2026, 2, 16, 10),
        DateTime.utc(2026, 3, 2, 10),
      ]);
    });

    test('DURATION supplies the end time', () {
      final occs = expand('BEGIN:VEVENT\n'
          'UID:d@ac.test\n'
          'DTSTART:20260917T090000Z\n'
          'DURATION:PT1H30M\n'
          'END:VEVENT\n');
      final o = occs.single;
      expect(o.startUtc, DateTime.utc(2026, 9, 17, 9));
      expect(o.endUtc, DateTime.utc(2026, 9, 17, 10, 30));
    });

    test('a timed event without DTEND or DURATION is zero-length', () {
      final occs = expand('BEGIN:VEVENT\n'
          'UID:z@ac.test\n'
          'DTSTART:20260917T090000Z\n'
          'END:VEVENT\n');
      expect(occs.single.endUtc, occs.single.startUtc);
    });

    test('an all-day event without DTEND lasts one day', () {
      final occs = expand('BEGIN:VEVENT\n'
          'UID:ad@ac.test\n'
          'DTSTART;VALUE=DATE:20260917\n'
          'END:VEVENT\n');
      expect(occs.single.isAllDay, isTrue);
      expect(occs.single.startUtc, DateTime.utc(2026, 9, 17));
      expect(occs.single.endUtc, DateTime.utc(2026, 9, 18));
    });

    test('occurrences are sorted by start', () {
      final occs = expand('BEGIN:VEVENT\n'
          'UID:s1@ac.test\n'
          'DTSTART:20260110T100000Z\n'
          'DTEND:20260110T110000Z\n'
          'END:VEVENT\n'
          'BEGIN:VEVENT\n'
          'UID:s2@ac.test\n'
          'DTSTART:20260105T090000Z\n'
          'DTEND:20260105T100000Z\n'
          'END:VEVENT\n');
      expect(occs.map((o) => o.uid), ['s2@ac.test', 's1@ac.test']);
    });
  });
}
