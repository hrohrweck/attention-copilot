import 'package:attention_copilot/domain/agenda.dart';
import 'package:attention_copilot/domain/models/calendar_event.dart';
import 'package:attention_copilot/domain/models/calendar_source_id.dart';
import 'package:attention_copilot/domain/models/event_occurrence.dart';
import 'package:attention_copilot/domain/models/meeting_join_info.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Test suite for the pure-Dart agenda domain: occurrence sorting,
/// next-meeting selection and the today agenda window.
///
/// Times are built from real IANA zones (Europe/Berlin, America/New_York) so
/// that local-day membership and DST behaviour are exercised for real. All
/// `now` values and occurrence instants are absolute UTC `DateTime`s.
void main() {
  late tz.Location berlin;
  late tz.Location newYork;

  setUpAll(() {
    tzdata.initializeTimeZones();
    berlin = tz.getLocation('Europe/Berlin');
    newYork = tz.getLocation('America/New_York');
  });

  // 2026-09-17T08:00Z == 10:00 Europe/Berlin (CEST, UTC+2) == 04:00 America/New_York (EDT, UTC-4).
  final now = DateTime.utc(2026, 9, 17, 8, 0);

  DateTime at(tz.Location location, int year, int month, int day, int hour,
          [int minute = 0]) =>
      tz.TZDateTime(location, year, month, day, hour, minute).toUtc();

  CalendarSourceId source(String id, {int priority = 10}) =>
      CalendarSourceId(id: id, displayName: 'Source $id', priority: priority);

  EventOccurrence occurrence({
    String id = 'occ-1',
    String eventId = 'evt-1',
    String title = 'Standup',
    required DateTime start,
    required DateTime end,
    bool allDay = false,
    CalendarSourceId? source,
    String? location,
    String? originalTimezoneId,
    MeetingJoinInfo? joinInfo,
  }) {
    return EventOccurrence(
      id: id,
      event: CalendarEvent(
        id: eventId,
        title: title,
        location: location,
        originalTimezoneId: originalTimezoneId,
        joinInfo: joinInfo,
      ),
      source: source ?? CalendarSourceId(id: 'src-1', displayName: 'Work', priority: 10),
      startUtc: start,
      endUtc: end,
      isAllDay: allDay,
    );
  }

  void expectSameInstant(DateTime actual, DateTime expected) {
    expect(actual.isUtc, isTrue, reason: 'instant must be UTC');
    expect(actual.millisecondsSinceEpoch, expected.millisecondsSinceEpoch);
  }

  group('sortOccurrences', () {
    test('orders by earliest start', () {
      final a = occurrence(id: 'a', start: at(berlin, 2026, 9, 17, 14), end: at(berlin, 2026, 9, 17, 15));
      final b = occurrence(id: 'b', start: at(berlin, 2026, 9, 17, 9), end: at(berlin, 2026, 9, 17, 10));
      final c = occurrence(id: 'c', start: at(berlin, 2026, 9, 17, 11), end: at(berlin, 2026, 9, 17, 12));

      final sorted = sortOccurrences([a, b, c]);

      expect(sorted.map((o) => o.id), ['b', 'c', 'a']);
    });

    test('breaks start ties by source priority, lower number first', () {
      final start = at(berlin, 2026, 9, 17, 11);
      final low = occurrence(id: 'low', source: source('low', priority: 30), start: start, end: at(berlin, 2026, 9, 17, 12));
      final high = occurrence(id: 'high', source: source('high', priority: 5), start: start, end: at(berlin, 2026, 9, 17, 12));

      final sorted = sortOccurrences([low, high]);

      expect(sorted.map((o) => o.id), ['high', 'low']);
    });

    test('breaks priority ties by stable id', () {
      final start = at(berlin, 2026, 9, 17, 11);
      final zed = occurrence(id: 'zed', source: source('s', priority: 10), start: start, end: at(berlin, 2026, 9, 17, 12));
      final alpha = occurrence(id: 'alpha', source: source('s', priority: 10), start: start, end: at(berlin, 2026, 9, 17, 12));

      final sorted = sortOccurrences([zed, alpha]);

      expect(sorted.map((o) => o.id), ['alpha', 'zed']);
    });

    test('does not mutate the input list', () {
      final a = occurrence(id: 'a', start: at(berlin, 2026, 9, 17, 14), end: at(berlin, 2026, 9, 17, 15));
      final b = occurrence(id: 'b', start: at(berlin, 2026, 9, 17, 9), end: at(berlin, 2026, 9, 17, 10));
      final input = [a, b];

      sortOccurrences(input);

      expect(input.map((o) => o.id), ['a', 'b']);
    });
  });

  group('selectNextMeeting', () {
    test('returns null for an empty day', () {
      expect(selectNextMeeting([], now), isNull);
    });

    test('returns null when every occurrence has ended', () {
      final past = occurrence(id: 'past', start: at(berlin, 2026, 9, 17, 7), end: at(berlin, 2026, 9, 17, 8));

      expect(selectNextMeeting([past], now), isNull);
    });

    test('selects the single future meeting', () {
      final future = occurrence(id: 'future', start: at(berlin, 2026, 9, 17, 11), end: at(berlin, 2026, 9, 17, 12));

      expect(selectNextMeeting([future], now)?.id, 'future');
    });

    test('selects the earliest of several future meetings', () {
      final lateOne = occurrence(id: 'late', start: at(berlin, 2026, 9, 17, 15), end: at(berlin, 2026, 9, 17, 16));
      final earlyOne = occurrence(id: 'early', start: at(berlin, 2026, 9, 17, 10, 30), end: at(berlin, 2026, 9, 17, 11));

      expect(selectNextMeeting([lateOne, earlyOne], now)?.id, 'early');
    });

    test('selects a meeting that starts exactly at now', () {
      final startingNow = occurrence(id: 'now', start: at(berlin, 2026, 9, 17, 10), end: at(berlin, 2026, 9, 17, 11));

      expect(selectNextMeeting([startingNow], now)?.id, 'now');
    });

    test('surfaces a meeting in progress when nothing future exists', () {
      final inProgress = occurrence(id: 'in-progress', start: at(berlin, 2026, 9, 17, 9), end: at(berlin, 2026, 9, 17, 11));

      expect(selectNextMeeting([inProgress], now)?.id, 'in-progress');
    });

    test('prefers a future meeting over one in progress', () {
      final inProgress = occurrence(id: 'in-progress', start: at(berlin, 2026, 9, 17, 9), end: at(berlin, 2026, 9, 17, 11));
      final future = occurrence(id: 'future', start: at(berlin, 2026, 9, 17, 14), end: at(berlin, 2026, 9, 17, 15));

      expect(selectNextMeeting([inProgress, future], now)?.id, 'future');
    });

    test('keeps a meeting that started five minutes ago as next when alone', () {
      final startedFiveMinutesAgo = occurrence(
        id: 'started-5m-ago',
        start: at(berlin, 2026, 9, 17, 9, 55),
        end: at(berlin, 2026, 9, 17, 11),
      );

      expect(selectNextMeeting([startedFiveMinutesAgo], now)?.id, 'started-5m-ago');
    });

    test('meeting that started five minutes ago loses to a later meeting', () {
      final startedFiveMinutesAgo = occurrence(
        id: 'started-5m-ago',
        start: at(berlin, 2026, 9, 17, 9, 55),
        end: at(berlin, 2026, 9, 17, 11),
      );
      final future = occurrence(id: 'future', start: at(berlin, 2026, 9, 17, 12), end: at(berlin, 2026, 9, 17, 13));

      expect(selectNextMeeting([startedFiveMinutesAgo, future], now)?.id, 'future');
    });

    test('excludes an event ending one second before now', () {
      final almostEnded = occurrence(
        id: 'almost-ended',
        start: at(berlin, 2026, 9, 17, 9),
        end: at(berlin, 2026, 9, 17, 9, 59).subtract(const Duration(seconds: 1)),
      );

      expect(selectNextMeeting([almostEnded], now), isNull);
    });

    test('excludes an event ending exactly at now (end is exclusive)', () {
      final endingNow = occurrence(id: 'ending-now', start: at(berlin, 2026, 9, 17, 9), end: at(berlin, 2026, 9, 17, 10));

      expect(selectNextMeeting([endingNow], now), isNull);
    });

    test('never selects an all-day occurrence, even the only one', () {
      final allDay = occurrence(
        id: 'allday',
        allDay: true,
        start: at(berlin, 2026, 9, 17, 0),
        end: at(berlin, 2026, 9, 18, 0),
      );

      expect(selectNextMeeting([allDay], now), isNull);
    });

    test('ignores all-day occurrences when choosing among timed ones', () {
      final allDay = occurrence(
        id: 'allday',
        allDay: true,
        start: at(berlin, 2026, 9, 17, 0),
        end: at(berlin, 2026, 9, 18, 0),
      );
      final timed = occurrence(id: 'timed', start: at(berlin, 2026, 9, 17, 12), end: at(berlin, 2026, 9, 17, 13));

      expect(selectNextMeeting([allDay, timed], now)?.id, 'timed');
    });

    test('breaks equal-start ties by source priority', () {
      final start = at(berlin, 2026, 9, 17, 11);
      final lowPriority = occurrence(
        id: 'low-priority',
        source: source('low', priority: 30),
        start: start,
        end: at(berlin, 2026, 9, 17, 12),
      );
      final highPriority = occurrence(
        id: 'high-priority',
        source: source('high', priority: 5),
        start: start,
        end: at(berlin, 2026, 9, 17, 12),
      );

      expect(selectNextMeeting([lowPriority, highPriority], now)?.id, 'high-priority');
    });

    test('breaks equal-start, equal-priority ties by stable id', () {
      final start = at(berlin, 2026, 9, 17, 11);
      final zed = occurrence(
        id: 'zed',
        source: source('same', priority: 10),
        start: start,
        end: at(berlin, 2026, 9, 17, 12),
      );
      final alpha = occurrence(
        id: 'alpha',
        source: source('same', priority: 10),
        start: start,
        end: at(berlin, 2026, 9, 17, 12),
      );

      expect(selectNextMeeting([zed, alpha], now)?.id, 'alpha');
    });

    test('picks the earliest-started among two overlapping in-progress meetings', () {
      final older = occurrence(id: 'older', start: at(berlin, 2026, 9, 17, 8), end: at(berlin, 2026, 9, 17, 12));
      final newer = occurrence(id: 'newer', start: at(berlin, 2026, 9, 17, 9), end: at(berlin, 2026, 9, 17, 10, 30));

      expect(selectNextMeeting([newer, older], now)?.id, 'older');
    });

    test('exposes conference join info of the selected meeting', () {
      final joinInfo = MeetingJoinInfo(url: 'https://meet.example.com/abc-defg-hij');
      final withJoin = occurrence(
        id: 'with-join',
        start: at(berlin, 2026, 9, 17, 11),
        end: at(berlin, 2026, 9, 17, 12),
        joinInfo: joinInfo,
      );

      expect(selectNextMeeting([withJoin], now)?.joinInfo, joinInfo);
    });

    test('does not mutate the input list', () {
      final a = occurrence(id: 'a', start: at(berlin, 2026, 9, 17, 11), end: at(berlin, 2026, 9, 17, 12));
      final b = occurrence(id: 'b', start: at(berlin, 2026, 9, 17, 14), end: at(berlin, 2026, 9, 17, 15));
      final input = [b, a];

      selectNextMeeting(input, now);

      expect(input.map((o) => o.id), ['b', 'a']);
    });
  });

  group('buildTodayAgenda', () {
    test('empty day yields empty lists and the correct UTC window', () {
      final agenda = buildTodayAgenda([], now, berlin);

      expect(agenda.allDayOccurrences, isEmpty);
      expect(agenda.timedOccurrences, isEmpty);
      expectSameInstant(agenda.dayStartUtc, DateTime.utc(2026, 9, 16, 22, 0));
      expectSameInstant(agenda.dayEndUtc, DateTime.utc(2026, 9, 17, 22, 0));
    });

    test('includes a single future meeting in the timed list', () {
      final meeting = occurrence(id: 'm', start: at(berlin, 2026, 9, 17, 11), end: at(berlin, 2026, 9, 17, 12));

      final agenda = buildTodayAgenda([meeting], now, berlin);

      expect(agenda.timedOccurrences.map((o) => o.id), ['m']);
      expect(agenda.allDayOccurrences, isEmpty);
    });

    test('includes a meeting in progress in the timed list', () {
      final inProgress = occurrence(id: 'm', start: at(berlin, 2026, 9, 17, 9), end: at(berlin, 2026, 9, 17, 11));

      final agenda = buildTodayAgenda([inProgress], now, berlin);

      expect(agenda.timedOccurrences.map((o) => o.id), ['m']);
    });

    test('excludes events entirely outside the local day', () {
      final yesterday = occurrence(id: 'yesterday', start: at(berlin, 2026, 9, 16, 9), end: at(berlin, 2026, 9, 16, 10));
      final tomorrow = occurrence(id: 'tomorrow', start: at(berlin, 2026, 9, 18, 9), end: at(berlin, 2026, 9, 18, 10));

      final agenda = buildTodayAgenda([yesterday, tomorrow], now, berlin);

      expect(agenda.timedOccurrences, isEmpty);
      expect(agenda.allDayOccurrences, isEmpty);
    });

    test('includes an event that crosses midnight into today', () {
      final crossingMidnight = occurrence(
        id: 'crossing',
        start: at(berlin, 2026, 9, 16, 23, 30),
        end: at(berlin, 2026, 9, 17, 0, 30),
      );

      final agenda = buildTodayAgenda([crossingMidnight], now, berlin);

      expect(agenda.timedOccurrences.map((o) => o.id), ['crossing']);
    });

    test('separates an all-day event from timed events and excludes it from next selection', () {
      final allDay = occurrence(
        id: 'allday',
        allDay: true,
        start: at(berlin, 2026, 9, 17, 0),
        end: at(berlin, 2026, 9, 18, 0),
      );
      final timed = occurrence(id: 'timed', start: at(berlin, 2026, 9, 17, 12), end: at(berlin, 2026, 9, 17, 13));

      final agenda = buildTodayAgenda([timed, allDay], now, berlin);

      expect(agenda.allDayOccurrences.map((o) => o.id), ['allday']);
      expect(agenda.timedOccurrences.map((o) => o.id), ['timed']);
      expect(selectNextMeeting(agenda.timedOccurrences, now)?.id, 'timed');
    });

    test('excludes an all-day event from tomorrow', () {
      final tomorrowAllDay = occurrence(
        id: 'tomorrow-allday',
        allDay: true,
        start: at(berlin, 2026, 9, 18, 0),
        end: at(berlin, 2026, 9, 19, 0),
      );

      final agenda = buildTodayAgenda([tomorrowAllDay], now, berlin);

      expect(agenda.allDayOccurrences, isEmpty);
    });

    test('places an event from another timezone on the user local day', () {
      // 08:00 in New York == 14:00 in Berlin: same instant, same local day.
      final newYorkMorning = occurrence(
        id: 'ny-morning',
        originalTimezoneId: 'America/New_York',
        start: at(newYork, 2026, 9, 17, 8),
        end: at(newYork, 2026, 9, 17, 9),
      );

      final berlinAgenda = buildTodayAgenda([newYorkMorning], now, berlin);
      expect(berlinAgenda.timedOccurrences.map((o) => o.id), ['ny-morning']);

      final newYorkNow = DateTime.utc(2026, 9, 17, 12, 0); // 08:00 in New York
      final newYorkAgenda = buildTodayAgenda([newYorkMorning], newYorkNow, newYork);
      expect(newYorkAgenda.timedOccurrences.map((o) => o.id), ['ny-morning']);
    });

    test('assigns an early-morning Berlin event to the previous day in New York', () {
      // 01:00 in Berlin on Sep 17 == 19:00 in New York on Sep 16:
      // for a New York user it belongs to the agenda of Sep 16, not Sep 17.
      final berlinEarly = occurrence(
        id: 'berlin-early',
        originalTimezoneId: 'Europe/Berlin',
        start: at(berlin, 2026, 9, 17, 1),
        end: at(berlin, 2026, 9, 17, 2),
      );

      final newYorkNow = DateTime.utc(2026, 9, 16, 12, 0); // 08:00 in New York on Sep 16
      final sep16 = buildTodayAgenda([berlinEarly], newYorkNow, newYork);
      expect(sep16.timedOccurrences.map((o) => o.id), ['berlin-early']);

      final sep17 = buildTodayAgenda([berlinEarly], now, newYork);
      expect(sep17.timedOccurrences, isEmpty);
    });

    test('preserves the original timezone id through the agenda', () {
      final meeting = occurrence(
        id: 'tz-preserved',
        originalTimezoneId: 'America/New_York',
        start: at(newYork, 2026, 9, 17, 15),
        end: at(newYork, 2026, 9, 17, 16),
      );

      final agenda = buildTodayAgenda([meeting], now, berlin);

      expect(agenda.timedOccurrences.single.originalTimezoneId, 'America/New_York');
    });

    test('builds a 25-hour window on the DST fall-back day', () {
      final dstNow = at(berlin, 2026, 10, 25, 12, 0); // inside the 25-hour day

      final agenda = buildTodayAgenda([], dstNow, berlin);

      expectSameInstant(agenda.dayStartUtc, DateTime.utc(2026, 10, 24, 22, 0));
      expectSameInstant(agenda.dayEndUtc, DateTime.utc(2026, 10, 25, 23, 0));
      expect(agenda.dayEndUtc.difference(agenda.dayStartUtc), const Duration(hours: 25));
    });

    test('sorts both output lists by start time', () {
      final late = occurrence(id: 'late', start: at(berlin, 2026, 9, 17, 16), end: at(berlin, 2026, 9, 17, 17));
      final early = occurrence(id: 'early', start: at(berlin, 2026, 9, 17, 9), end: at(berlin, 2026, 9, 17, 10));
      final mid = occurrence(id: 'mid', start: at(berlin, 2026, 9, 17, 12), end: at(berlin, 2026, 9, 17, 13));

      final agenda = buildTodayAgenda([mid, late, early], now, berlin);

      expect(agenda.timedOccurrences.map((o) => o.id), ['early', 'mid', 'late']);
    });

    test('does not mutate the input list', () {
      final a = occurrence(id: 'a', start: at(berlin, 2026, 9, 17, 11), end: at(berlin, 2026, 9, 17, 12));
      final b = occurrence(id: 'b', start: at(berlin, 2026, 9, 17, 14), end: at(berlin, 2026, 9, 17, 15));
      final input = [b, a];

      buildTodayAgenda(input, now, berlin);

      expect(input.map((o) => o.id), ['b', 'a']);
    });
  });
}
