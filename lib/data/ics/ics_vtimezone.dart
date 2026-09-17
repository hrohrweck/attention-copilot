part of 'ics.dart';

/// One STANDARD or DAYLIGHT observance inside a VTIMEZONE.
class VtzObservance {
  const VtzObservance({
    required this.isDaylight,
    required this.dtStart,
    required this.offsetFrom,
    required this.offsetTo,
    required this.rrule,
    required this.rdates,
    this.abbreviation,
  });

  final bool isDaylight;

  /// Local wall time at which the transition occurs.
  final DateTime dtStart;

  /// Offset in effect *before* the transition.
  final Duration offsetFrom;

  /// Offset that goes into effect *at* the transition.
  final Duration offsetTo;

  /// Yearly recurrence rule (`FREQ=YEARLY;BYMONTH=...;BYDAY=...`).
  final String? rrule;

  /// Explicit one-off transition wall times (RDATE).
  final List<String> rdates;

  final String? abbreviation;
}

/// Builds a resolvable [tz.Location] from VTIMEZONE observances.
///
/// Transition instants are computed for every year in
/// [kEmbeddedTimezoneYearRange] so event resolution works regardless of the
/// feed's event years. The location is self-contained: it needs no IANA
/// database entry.
tz.Location buildVTimezoneLocation(
  String name,
  List<VtzObservance> observances,
) {
  if (observances.isEmpty) {
    throw FormatException('no STANDARD/DAYLIGHT observances');
  }

  // (instantUtc, offsetTo, isDst, abbreviation) - one per transition.
  final transitions = <_VtzTransition>[];
  for (final observance in observances) {
    final wallTimes = <DateTime>[];
    if (observance.rrule != null) {
      final rule = Rrule.parse(observance.rrule!);
      if (rule.freq == 'YEARLY' && rule.byMonth.isNotEmpty) {
        for (var year = kEmbeddedTimezoneRangeStart;
            year <= kEmbeddedTimezoneRangeEnd;
            year++) {
          final day = _observanceDayInYear(year, rule);
          if (day == null) continue;
          wallTimes.add(_withTime(day, observance.dtStart));
        }
      } else {
        // Unusual rule: fall back to the DTSTART wall time itself.
        wallTimes.add(observance.dtStart);
      }
    }
    for (final rdate in observance.rdates) {
      try {
        wallTimes.add(parseIcsDateTime(rdate));
      } on FormatException {
        // A malformed RDATE must not kill the whole zone.
      }
    }
    if (wallTimes.isEmpty) {
      wallTimes.add(observance.dtStart);
    }

    for (final wall in wallTimes) {
      // The wall time is expressed in the zone *before* the transition.
      final instantMs = wall.millisecondsSinceEpoch -
          observance.offsetFrom.inMilliseconds;
      transitions.add(_VtzTransition(
        instantMs,
        observance.offsetTo,
        observance.isDaylight,
        observance.abbreviation ?? name,
      ));
    }
  }
  transitions.sort((a, b) => a.instantMs.compareTo(b.instantMs));

  // Zones: index 0 is the pre-first-transition zone and must never be
  // referenced by transitionZone, so Location._firstZone picks it up.
  final zones = <tz.TimeZone>[
    _initialZone(observances),
  ];
  final zoneIndex = <String, int>{};
  final transitionAt = <int>[];
  final transitionZone = <int>[];

  for (final transition in transitions) {
    final key = '${transition.offset.inMilliseconds}|'
        '${transition.isDst}|'
        '${transition.abbreviation}';
    final index = zoneIndex.putIfAbsent(key, () {
      zones.add(tz.TimeZone(
        transition.offset,
        isDst: transition.isDst,
        abbreviation: transition.abbreviation,
      ));
      return zones.length - 1;
    });
    transitionAt.add(transition.instantMs);
    transitionZone.add(index);
  }

  return tz.Location(name, transitionAt, transitionZone, zones);
}

/// The zone in effect before the first transition: the STANDARD observance's
/// offset, else the earliest observance's FROM offset.
tz.TimeZone _initialZone(List<VtzObservance> observances) {
  for (final observance in observances) {
    if (!observance.isDaylight) {
      return tz.TimeZone(
        observance.offsetTo,
        isDst: false,
        abbreviation: observance.abbreviation ?? 'STD',
      );
    }
  }
  final earliest = observances.reduce(
    (a, b) => a.dtStart.isBefore(b.dtStart) ? a : b,
  );
  return tz.TimeZone(
    earliest.offsetFrom,
    isDst: false,
    abbreviation: earliest.abbreviation ?? 'STD',
  );
}

/// Resolves a `FREQ=YEARLY;BYMONTH=m;BYDAY=nD` rule to the transition day
/// of [year] (DST-rule style), or null when the rule does not fit.
DateTime? _observanceDayInYear(int year, Rrule rule) {
  for (final month in rule.byMonth) {
    if (rule.byDay.isNotEmpty) {
      final byDay = rule.byDay.first;
      final ordinal = byDay.ordinal ?? 1;
      final day = _nthWeekdayOfMonth(year, month, byDay.weekday, ordinal);
      if (day != null) return day;
    } else {
      final day = _dayOfMonth(year, month, rule.byMonthDay.firstOrNull ?? 1);
      if (day != null) return day;
    }
  }
  return null;
}

DateTime _withTime(DateTime day, DateTime time) =>
    DateTime.utc(day.year, day.month, day.day, time.hour, time.minute,
        time.second);

/// The [monthDay]-th day of the month (negative counts from the end);
/// null when the month has no such day.
DateTime? _dayOfMonth(int year, int month, int monthDay) {
  final days = _daysInMonth(year, month);
  final day = monthDay > 0 ? monthDay : days + monthDay + 1;
  if (day < 1 || day > days) return null;
  return DateTime.utc(year, month, day);
}

int _daysInMonth(int year, int month) =>
    DateTime.utc(year, month + 1, 0).day;

/// The date of the `ordinal`-th [weekday] (1=Mon..7=Sun) in the month;
/// negative ordinals count from the end of the month.
DateTime? _nthWeekdayOfMonth(int year, int month, int weekday, int ordinal) {
  final days = _daysInMonth(year, month);
  final first = DateTime.utc(year, month, 1);
  final offset = (weekday - first.weekday + 7) % 7;
  if (ordinal > 0) {
    final day = 1 + offset + (ordinal - 1) * 7;
    return day <= days ? DateTime.utc(year, month, day) : null;
  }
  final last = DateTime.utc(year, month, days);
  final lastOffset = (last.weekday - weekday + 7) % 7;
  final day = days - lastOffset + (ordinal + 1) * 7;
  return day >= 1 ? DateTime.utc(year, month, day) : null;
}

class _VtzTransition {
  const _VtzTransition(
      this.instantMs, this.offset, this.isDst, this.abbreviation);

  final int instantMs;
  final Duration offset;
  final bool isDst;
  final String abbreviation;
}

/// Embedded VTIMEZONE transitions are materialised for every year in this
/// range, so event resolution is deterministic and needs no wall clock.
const int kEmbeddedTimezoneRangeStart = 1970;
const int kEmbeddedTimezoneRangeEnd = 2099;
