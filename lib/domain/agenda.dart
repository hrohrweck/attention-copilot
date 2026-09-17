import 'package:timezone/timezone.dart' as tz;

import 'models/agenda_day.dart';
import 'models/event_occurrence.dart';

/// Pure agenda functions over the occurrence model.
///
/// This file is side-effect free: no I/O, no platform calls, no wall clock.
/// `now` is always injected and `timezone` is always injected - the domain
/// never resolves "today" from the machine clock on its own.

/// Deterministic total order over occurrences:
///  1. earliest [EventOccurrence.startUtc],
///  2. highest source priority ([CalendarSourceId.priority], lower number wins),
///  3. stable [EventOccurrence.id] (ascending).
///
/// Used both for display sorting and for tie-breaking in [selectNextMeeting].
int compareOccurrences(EventOccurrence a, EventOccurrence b) {
  final byStart = a.startUtc.compareTo(b.startUtc);
  if (byStart != 0) return byStart;
  final byPriority = a.source.priority.compareTo(b.source.priority);
  if (byPriority != 0) return byPriority;
  return a.id.compareTo(b.id);
}

/// Returns a new list sorted by [compareOccurrences]. Never mutates the input.
List<EventOccurrence> sortOccurrences(List<EventOccurrence> occurrences) =>
    List.unmodifiable(List<EventOccurrence>.of(occurrences)..sort(compareOccurrences));

/// Selects the next meeting from [occurrences] at the absolute instant [now].
///
/// Rules:
///  * All-day occurrences are never selected.
///  * Occurrences that have already ended (`endUtc <= now`) are ignored;
///    `endUtc` is exclusive, so an occurrence ending exactly at `now` is over.
///  * The next meeting is the earliest occurrence that has not started yet
///    (`startUtc >= now`).
///  * Only when no such future occurrence exists is an occurrence currently
///    in progress (`startUtc < now < endUtc`) surfaced as next.
///  * Ties break by [compareOccurrences]: earliest start, then source
///    priority, then stable id.
///
/// Returns `null` when there is nothing to attend. Never mutates the input.
EventOccurrence? selectNextMeeting(List<EventOccurrence> occurrences, DateTime now) {
  EventOccurrence? bestFuture;
  EventOccurrence? bestInProgress;
  for (final occurrence in occurrences) {
    if (occurrence.isAllDay) continue;
    if (!occurrence.endUtc.isAfter(now)) continue; // ended
    if (occurrence.startUtc.isBefore(now)) {
      bestInProgress = _better(bestInProgress, occurrence);
    } else {
      bestFuture = _better(bestFuture, occurrence);
    }
  }
  return bestFuture ?? bestInProgress;
}

/// Builds today's agenda: the window `[local midnight, next local midnight)`
/// of [timezone] at [now], converted to absolute UTC instants, containing
/// every occurrence that overlaps it (Google `timeMin`/`timeMax` semantics:
/// end exclusive of the lower bound, start exclusive of the upper bound).
///
/// Occurrences are split into all-day and timed lists, each sorted by
/// [sortOccurrences]. Never mutates the input.
AgendaDay buildTodayAgenda(
  List<EventOccurrence> occurrences,
  DateTime now,
  tz.Location timezone,
) {
  final localNow = tz.TZDateTime.from(now, timezone);
  final dayStart = tz.TZDateTime(timezone, localNow.year, localNow.month, localNow.day);
  final dayEnd = tz.TZDateTime(timezone, localNow.year, localNow.month, localNow.day + 1);
  final dayStartUtc = dayStart.toUtc();
  final dayEndUtc = dayEnd.toUtc();

  final allDay = <EventOccurrence>[];
  final timed = <EventOccurrence>[];
  for (final occurrence in occurrences) {
    final overlapsDay =
        occurrence.startUtc.isBefore(dayEndUtc) &&
        occurrence.endUtc.isAfter(dayStartUtc);
    if (!overlapsDay) continue;
    (occurrence.isAllDay ? allDay : timed).add(occurrence);
  }

  return AgendaDay(
    dayStartUtc: dayStartUtc,
    dayEndUtc: dayEndUtc,
    allDayOccurrences: sortOccurrences(allDay),
    timedOccurrences: sortOccurrences(timed),
  );
}

/// Keeps the occurrence that sorts earlier per [compareOccurrences].
EventOccurrence? _better(EventOccurrence? current, EventOccurrence candidate) {
  if (current == null) return candidate;
  return compareOccurrences(candidate, current) < 0 ? candidate : current;
}
