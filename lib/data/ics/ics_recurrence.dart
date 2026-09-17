part of 'ics.dart';

/// One `BYDAY` entry: an optional ordinal plus a weekday.
class RruleByDay {
  const RruleByDay(this.ordinal, this.weekday);

  /// `n`-th occurrence of the weekday inside the period; 0/null = every
  /// occurrence. Negative counts from the end.
  final int? ordinal;

  /// 1 = Monday .. 7 = Sunday (matches [DateTime.weekday]).
  final int weekday;

  @override
  String toString() => 'RruleByDay($ordinal, $weekday)';
}

/// A parsed RRULE (RFC 5545 section 3.8.5.3) restricted to the subset the
/// app needs: FREQ (SECONDLY..YEARLY), INTERVAL, COUNT, UNTIL, BYMONTH,
/// BYMONTHDAY, BYDAY, BYHOUR, BYMINUTE, BYSECOND, WKST.
class Rrule {
  const Rrule({
    required this.freq,
    required this.interval,
    required this.count,
    required this.until,
    required this.byMonth,
    required this.byMonthDay,
    required this.byDay,
    required this.byHour,
    required this.byMinute,
    required this.bySecond,
    required this.wkst,
    required this.unsupported,
  });

  final String freq;
  final int interval;
  final int? count;
  final IcsDateTime? until;
  final List<int> byMonth;
  final List<int> byMonthDay;
  final List<RruleByDay> byDay;
  final List<int> byHour;
  final List<int> byMinute;
  final List<int> bySecond;

  /// Week start, 1 = Monday .. 7 = Sunday (default MO).
  final int wkst;

  /// Rule parts we recognise but deliberately do not expand
  /// (BYSETPOS, BYWEEKNO, BYYEARDAY); surfaces as diagnostics.
  final List<String> unsupported;

  static const _weekdays = {
    'MO': 1, 'TU': 2, 'WE': 3, 'TH': 4, 'FR': 5, 'SA': 6, 'SU': 7,
  };

  static Rrule parse(String text) {
    var freq = '';
    var interval = 1;
    int? count;
    IcsDateTime? until;
    final byMonth = <int>[];
    final byMonthDay = <int>[];
    final byDay = <RruleByDay>[];
    final byHour = <int>[];
    final byMinute = <int>[];
    final bySecond = <int>[];
    var wkst = 1;
    final unsupported = <String>[];

    for (final part in text.split(';')) {
      final eq = part.indexOf('=');
      if (eq == -1) continue;
      final key = part.substring(0, eq).toUpperCase().trim();
      final value = part.substring(eq + 1).trim();
      switch (key) {
        case 'FREQ':
          freq = value.toUpperCase();
        case 'INTERVAL':
          interval = int.tryParse(value) ?? 1;
        case 'COUNT':
          count = int.tryParse(value);
        case 'UNTIL':
          try {
            until = parseIcsDateTimeValue(value, const {});
          } on FormatException {
            unsupported.add('UNTIL=$value');
          }
        case 'BYMONTH':
          byMonth.addAll(_parseIntList(value));
        case 'BYMONTHDAY':
          byMonthDay.addAll(_parseIntList(value));
        case 'BYDAY':
          for (final entry in value.split(',')) {
            final match = RegExp(r'^([+-]?\d+)?(MO|TU|WE|TH|FR|SA|SU)$')
                .firstMatch(entry.trim());
            if (match == null) {
              unsupported.add('BYDAY=$entry');
              continue;
            }
            final ordinalText = match.group(1);
            final weekday = _weekdays[match.group(2)]!;
            byDay.add(RruleByDay(
              ordinalText == null ? null : int.parse(ordinalText),
              weekday,
            ));
          }
        case 'BYHOUR':
          byHour.addAll(_parseIntList(value));
        case 'BYMINUTE':
          byMinute.addAll(_parseIntList(value));
        case 'BYSECOND':
          bySecond.addAll(_parseIntList(value));
        case 'WKST':
          wkst = _weekdays[value.toUpperCase()] ?? 1;
        case 'BYSETPOS':
        case 'BYWEEKNO':
        case 'BYYEARDAY':
          unsupported.add(key);
        default:
          unsupported.add(key);
      }
    }
    if (freq.isEmpty) {
      throw FormatException('RRULE without FREQ: $text');
    }
    return Rrule(
      freq: freq,
      interval: interval <= 0 ? 1 : interval,
      count: count,
      until: until,
      byMonth: byMonth,
      byMonthDay: byMonthDay,
      byDay: byDay,
      byHour: byHour,
      byMinute: byMinute,
      bySecond: bySecond,
      wkst: wkst,
      unsupported: unsupported,
    );
  }

  static List<int> _parseIntList(String value) => [
        for (final part in value.split(','))
          if (int.tryParse(part.trim()) case final int parsed) parsed,
      ];
}

/// Resolves TZIDs against embedded VTIMEZONEs, then the IANA database via
/// the `timezone` package, then (with a recorded diagnostic) the floating
/// zone - never emitting an unresolved local time silently.
class ZoneResolver {
  ZoneResolver({
    required this.embedded,
    required this.floating,
    required this.iana,
    required this.diagnostics,
  });

  final Map<String, tz.Location> embedded;
  final tz.Location floating;
  final tz.Location? Function(String name) iana;
  final List<IcsDiagnostic> diagnostics;
  final Set<String> _reportedUnknown = {};

  final tz.Location utcLocation =
      tz.Location('UTC', const [], const [], [
    tz.TimeZone(Duration.zero, isDst: false, abbreviation: 'UTC'),
  ]);

  tz.Location resolveLocation(String tzid) {
    final fromEmbedded = embedded[tzid];
    if (fromEmbedded != null) return fromEmbedded;
    try {
      final fromIana = iana(tzid);
      if (fromIana != null) return fromIana;
    } catch (_) {
      // Database not initialised or name unknown: treat as unresolved.
    }
    if (_reportedUnknown.add(tzid)) {
      diagnostics.add(IcsDiagnostic(
        'unknown TZID "$tzid" - resolved against the floating zone',
        context: tzid,
      ));
    }
    return floating;
  }
}

/// Turns parsed events into absolute occurrences inside a UTC window.
class IcsExpander {
  IcsExpander({
    required this.events,
    required this.embeddedTimezones,
    required this.diagnostics,
    required this.floatingZone,
    required this.ianaResolver,
  });

  final List<IcsEvent> events;
  final Map<String, tz.Location> embeddedTimezones;
  final List<IcsDiagnostic> diagnostics;
  final tz.Location floatingZone;
  final tz.Location? Function(String name) ianaResolver;

  List<IcsOccurrence> expand(
    DateTime windowStart,
    DateTime windowEnd, {
    tz.Location? floatingZone,
  }) {
    final start = windowStart.toUtc();
    final end = windowEnd.toUtc();
    final resolver = ZoneResolver(
      embedded: embeddedTimezones,
      floating: floatingZone ?? this.floatingZone,
      iana: ianaResolver,
      diagnostics: diagnostics,
    );

    final groups = <String, List<IcsEvent>>{};
    for (final event in events) {
      groups.putIfAbsent(event.uid, () => <IcsEvent>[]).add(event);
    }

    final occurrences = <IcsOccurrence>[];
    for (final group in groups.values) {
      occurrences.addAll(_expandGroup(group, resolver, start, end));
    }
    occurrences.sort((a, b) {
      final byStart = a.startUtc.compareTo(b.startUtc);
      return byStart != 0 ? byStart : a.uid.compareTo(b.uid);
    });
    return occurrences;
  }

  List<IcsOccurrence> _expandGroup(
    List<IcsEvent> group,
    ZoneResolver resolver,
    DateTime windowStart,
    DateTime windowEnd,
  ) {
    final masters = group
        .where((e) => e.recurrenceId == null && e.status != 'CANCELLED')
        .toList();
    final overrides =
        group.where((e) => e.recurrenceId != null).toList();
    final consumed = <IcsEvent>{};
    final occurrences = <IcsOccurrence>[];

    for (final master in masters) {
      occurrences.addAll(_expandSeries(
        master,
        overrides,
        consumed,
        resolver,
        windowStart,
        windowEnd,
      ));
    }
    // Overrides whose recurrence instant never matched a generated master
    // instance still describe real events: surface them.
    for (final override in overrides) {
      if (consumed.contains(override)) continue;
      occurrences.addAll(_expandSeries(
        override,
        overrides.where((o) => !identical(o, override)).toList(),
        consumed,
        resolver,
        windowStart,
        windowEnd,
        sourceIsOverride: true,
      ));
    }
    return occurrences;
  }

  List<IcsOccurrence> _expandSeries(
    IcsEvent event,
    List<IcsEvent> overrides,
    Set<IcsEvent> consumed,
    ZoneResolver resolver,
    DateTime windowStart,
    DateTime windowEnd, {
    bool sourceIsOverride = false,
  }) {
    if (event.status == 'CANCELLED') return const [];
    final windowStartMs = windowStart.millisecondsSinceEpoch;
    final windowEndMs = windowEnd.millisecondsSinceEpoch;
    final isAllDay = event.isAllDay;
    final zone = _zoneFor(event, resolver);

    // Classify overrides: single-instance replacements vs. a
    // THISANDFUTURE cutover (an override with RANGE=THISANDFUTURE, or a
    // non-cancelled override carrying its own RRULE, acts as a new master).
    final singles = <int, IcsEvent>{};
    IcsEvent? taf;
    int? tafMs;
    for (final override in overrides) {
      if (identical(override, event)) continue;
      final ridMs = _recurrenceIdMs(override, resolver);
      if (ridMs == null) continue;
      final isTaf = override.rangeThisAndFuture ||
          (override.rruleText != null && override.status != 'CANCELLED');
      if (isTaf) {
        if (tafMs == null || ridMs > tafMs) {
          taf = override;
          tafMs = ridMs;
        }
      } else {
        singles[ridMs] = override;
      }
    }

    // Generate wall-clock starts: RRULE expansion plus the anchor plus
    // RDATEs, filtered by EXDATE, capped to the window and the cutover.
    final wallStarts = <DateTime>[];
    final seen = <int>{};
    var generated = 0;

    Rrule? rule;
    if (event.rruleText != null) {
      try {
        rule = Rrule.parse(event.rruleText!);
      } on FormatException catch (e) {
        diagnostics.add(IcsDiagnostic(
          'invalid RRULE: ${e.message}',
          context: event.uid,
        ));
        rule = null;
      }
    } else {
      rule = null;
    }
    if (rule != null && rule.unsupported.isNotEmpty) {
      diagnostics.add(IcsDiagnostic(
        'RRULE parts not expanded: ${rule.unsupported.join(', ')}',
        context: event.uid,
      ));
    }

    if (rule != null) {
      if (isAllDay && _subDailyFreqs.contains(rule.freq)) {
        diagnostics.add(IcsDiagnostic(
          'all-day event with ${rule.freq} RRULE not expanded',
          context: event.uid,
        ));
      } else {
        for (final wall in _iterateRule(rule, event)) {
          generated++;
          if (generated > kMaxRecurrenceInstances) {
            diagnostics.add(IcsDiagnostic(
              'recurrence expansion capped at $kMaxRecurrenceInstances '
              'instances',
              context: event.uid,
            ));
            break;
          }
          if (rule.count != null && generated > rule.count!) break;
          final utcMs = _wallMs(wall, zone, isAllDay);
          if (rule.until != null &&
              utcMs > _untilMs(rule.until!, event, zone, resolver)) {
            break;
          }
          if (tafMs != null && utcMs >= tafMs) break;
          if (utcMs >= windowEndMs) break;
          wallStarts.add(wall);
        }
      }
    } else {
      // Plain single event.
      final wall = event.dtStart.value;
      final utcMs = _wallMs(wall, zone, isAllDay);
      if ((tafMs == null || utcMs < tafMs) && utcMs < windowEndMs) {
        wallStarts.add(wall);
        seen.add(utcMs);
      }
    }

    // RDATEs join the set.
    for (final rdate in event.rdates) {
      final rdateZone = rdate.tzid == null
          ? zone
          : resolver.resolveLocation(rdate.tzid!);
      final wall = rdate.value;
      final utcMs = _wallMs(wall, rdateZone, isAllDay);
      if (tafMs != null && utcMs >= tafMs) continue;
      if (utcMs < windowStartMs || utcMs >= windowEndMs) continue;
      if (seen.add(utcMs)) wallStarts.add(wall);
    }

    // EXDATE removes instances.
    final excluded = <int>{};
    for (final exdate in event.exdates) {
      final exZone = exdate.tzid == null
          ? zone
          : resolver.resolveLocation(exdate.tzid!);
      excluded.add(_wallMs(exdate.value, exZone, isAllDay));
    }
    if (excluded.isNotEmpty) {
      wallStarts.removeWhere(
        (wall) => excluded.contains(_wallMs(wall, zone, isAllDay)),
      );
    }

    // Assemble occurrences.
    final occurrences = <IcsOccurrence>[];
    for (final wall in wallStarts) {
      final utcMs = _wallMs(wall, zone, isAllDay);
      if (utcMs < windowStartMs) continue;
      final single = singles[utcMs];
      if (single != null) {
        consumed.add(single);
        if (single.status == 'CANCELLED') continue;
        final singleZone = _zoneFor(single, resolver);
        occurrences.add(_buildOccurrence(
          single,
          single.dtStart.value,
          singleZone,
          resolver,
          fromOverride: true,
          recurrenceId: _recurrenceIdAsDateTime(single, resolver),
        ));
        continue;
      }
      occurrences.add(_buildOccurrence(
        event,
        wall,
        zone,
        resolver,
        fromOverride: sourceIsOverride,
        recurrenceId: sourceIsOverride
            ? _recurrenceIdAsDateTime(event, resolver)
            : null,
      ));
    }

    // The THISANDFUTURE override continues as its own series.
    if (taf != null && !consumed.contains(taf)) {
      consumed.add(taf);
      occurrences.addAll(_expandSeries(
        taf,
        overrides.where((o) => !identical(o, taf)).toList(),
        consumed,
        resolver,
        windowStart,
        windowEnd,
        sourceIsOverride: true,
      ));
    }
    return occurrences;
  }

  IcsOccurrence _buildOccurrence(
    IcsEvent source,
    DateTime wallStart,
    tz.Location zone,
    ZoneResolver resolver, {
    required bool fromOverride,
    DateTime? recurrenceId,
  }) {
    final isAllDay = source.isAllDay;
    final startUtc = isAllDay ? wallStart : wallToUtc(zone, wallStart);
    return IcsOccurrence(
      uid: source.uid,
      startUtc: startUtc,
      endUtc: _endUtcFor(source, wallStart, startUtc, zone),
      isAllDay: isAllDay,
      timezoneName: source.timezoneName,
      fromOverride: fromOverride,
      recurrenceId: recurrenceId,
      summary: source.summary,
      description: source.description,
      location: source.location,
      url: source.url,
      reminders: source.reminders,
    );
  }

  DateTime _endUtcFor(
    IcsEvent event,
    DateTime wallStart,
    DateTime startUtc,
    tz.Location zone,
  ) {
    if (event.isAllDay) {
      if (event.dtEnd != null) {
        // Shift the exclusive end date along with the instance.
        return wallStart.add(
          event.dtEnd!.value.difference(event.dtStart.value),
        );
      }
      if (event.duration != null) return startUtc.add(event.duration!);
      return startUtc.add(const Duration(days: 1));
    }
    if (event.dtEnd != null) {
      // Wall-clock duration carried per instance, then converted through
      // the instance's own zone so DST days keep their wall schedule.
      final wallDelta = event.dtEnd!.value.difference(event.dtStart.value);
      return wallToUtc(zone, wallStart.add(wallDelta));
    }
    if (event.duration != null) return startUtc.add(event.duration!);
    return startUtc;
  }

  tz.Location _zoneFor(IcsEvent event, ZoneResolver resolver) {
    if (event.dtStart.isUtc) return resolver.utcLocation;
    final tzid = event.dtStart.tzid;
    if (tzid != null) return resolver.resolveLocation(tzid);
    return resolver.floating;
  }

  int _wallMs(DateTime wall, tz.Location zone, bool isAllDay) =>
      isAllDay ? wall.millisecondsSinceEpoch
              : wallToUtc(zone, wall).millisecondsSinceEpoch;

  int? _recurrenceIdMs(IcsEvent override, ZoneResolver resolver) =>
      _instantMs(override.recurrenceId, resolver, override.isAllDay);

  DateTime? _recurrenceIdAsDateTime(
    IcsEvent override,
    ZoneResolver resolver,
  ) =>
      _instantAsDateTime(override.recurrenceId, resolver);

  int? _instantMs(
    IcsDateTime? value,
    ZoneResolver resolver,
    bool isAllDay,
  ) {
    final resolved = _instantAsDateTime(value, resolver);
    return resolved?.millisecondsSinceEpoch;
  }

  DateTime? _instantAsDateTime(
    IcsDateTime? value,
    ZoneResolver resolver,
  ) {
    if (value == null) return null;
    if (value.isDateOnly) return value.value;
    if (value.isUtc) return value.value;
    final zone = value.tzid == null
        ? resolver.floating
        : resolver.resolveLocation(value.tzid!);
    return wallToUtc(zone, value.value);
  }

  int _untilMs(
    IcsDateTime until,
    IcsEvent event,
    tz.Location zone,
    ZoneResolver resolver,
  ) {
    if (until.isDateOnly) return until.value.millisecondsSinceEpoch;
    if (until.isUtc) return until.value.millisecondsSinceEpoch;
    // A TZID-less UNTIL lives in the event's own zone.
    return wallToUtc(zone, until.value).millisecondsSinceEpoch;
  }

  /// Converts a wall-clock time to UTC through [location]. Handles the
  /// normal case in one step; overlap (fall-back) times resolve to the
  /// first occurrence; non-existent (spring-forward) times normalise with
  /// the pre-transition offset, mirroring mktime-style behaviour.
  static DateTime wallToUtc(tz.Location location, DateTime wall) {
    final wallMs = wall.millisecondsSinceEpoch;
    final offset1 = location.timeZone(wallMs).offset.inMilliseconds;
    final utc1 = wallMs - offset1;
    if (location.timeZone(utc1).offset.inMilliseconds == offset1) {
      return DateTime.fromMillisecondsSinceEpoch(utc1, isUtc: true);
    }
    final offset2 = location.timeZone(utc1).offset.inMilliseconds;
    final utc2 = wallMs - offset2;
    return DateTime.fromMillisecondsSinceEpoch(utc2, isUtc: true);
  }

  static const _subDailyFreqs = {'SECONDLY', 'MINUTELY', 'HOURLY'};

  /// Yields wall-clock start times (UTC carriers) in ascending order.
  Iterable<DateTime> _iterateRule(Rrule rule, IcsEvent event) sync* {
    final isAllDay = event.isAllDay;
    final anchor = event.dtStart.value;
    final anchorDate = DateTime.utc(anchor.year, anchor.month, anchor.day);
    final hours = rule.byHour.isEmpty ? [anchor.hour] : rule.byHour;
    final minutes = rule.byMinute.isEmpty ? [anchor.minute] : rule.byMinute;
    final seconds = rule.bySecond.isEmpty ? [anchor.second] : rule.bySecond;

    Iterable<DateTime> timesFor(DateTime day) sync* {
      if (isAllDay) {
        yield day;
        return;
      }
      for (final hour in hours) {
        for (final minute in minutes) {
          for (final second in seconds) {
            yield DateTime.utc(day.year, day.month, day.day, hour, minute,
                second);
          }
        }
      }
    }

    bool dateOk(DateTime day) {
      if (rule.byMonth.isNotEmpty && !rule.byMonth.contains(day.month)) {
        return false;
      }
      if (rule.byMonthDay.isNotEmpty && !rule.byMonthDay.contains(day.day)) {
        return false;
      }
      if (rule.byDay.isNotEmpty &&
          !rule.byDay.any((bd) => bd.weekday == day.weekday)) {
        return false;
      }
      return true;
    }

    switch (rule.freq) {
      case 'SECONDLY':
        for (var k = 0; ; k++) {
          final candidate = anchor.add(Duration(seconds: rule.interval * k));
          if (rule.bySecond.isNotEmpty &&
              !rule.bySecond.contains(candidate.second)) {
            continue;
          }
          if (rule.byMinute.isNotEmpty &&
              !rule.byMinute.contains(candidate.minute)) {
            continue;
          }
          if (rule.byHour.isNotEmpty && !rule.byHour.contains(candidate.hour)) {
            continue;
          }
          if (!dateOk(candidate)) continue;
          yield candidate;
        }
      case 'MINUTELY':
        for (var k = 0; ; k++) {
          final candidate = anchor.add(Duration(minutes: rule.interval * k));
          if (rule.byMinute.isNotEmpty &&
              !rule.byMinute.contains(candidate.minute)) {
            continue;
          }
          if (rule.byHour.isNotEmpty && !rule.byHour.contains(candidate.hour)) {
            continue;
          }
          if (rule.bySecond.isNotEmpty &&
              !rule.bySecond.contains(candidate.second)) {
            continue;
          }
          if (!dateOk(candidate)) continue;
          yield candidate;
        }
      case 'HOURLY':
        for (var k = 0; ; k++) {
          final candidate = anchor.add(Duration(hours: rule.interval * k));
          if (rule.byHour.isNotEmpty && !rule.byHour.contains(candidate.hour)) {
            continue;
          }
          if (rule.byMinute.isNotEmpty &&
              !rule.byMinute.contains(candidate.minute)) {
            continue;
          }
          if (rule.bySecond.isNotEmpty &&
              !rule.bySecond.contains(candidate.second)) {
            continue;
          }
          if (!dateOk(candidate)) continue;
          yield candidate;
        }
      case 'DAILY':
        for (var k = 0; ; k++) {
          final day = anchorDate.add(Duration(days: rule.interval * k));
          if (dateOk(day)) yield* timesFor(day);
        }
      case 'WEEKLY':
        final anchorWeekday = anchorDate.weekday;
        final daysBack = (anchorWeekday - rule.wkst + 7) % 7;
        final weekStart0 = anchorDate.subtract(Duration(days: daysBack));
        for (var k = 0; ; k++) {
          final weekStart = weekStart0.add(
            Duration(days: 7 * rule.interval * k),
          );
          final days = <DateTime>[
            if (rule.byDay.isNotEmpty)
              for (final byDay in rule.byDay)
                weekStart.add(Duration(days: (byDay.weekday - rule.wkst + 7) % 7))
            else
              weekStart.add(Duration(days: daysBack)),
          ]..sort();
          for (final day in days) {
            if (dateOk(day)) yield* timesFor(day);
          }
        }
      case 'MONTHLY':
        for (var k = 0; ; k++) {
          final monthIndex = (anchorDate.month - 1) + rule.interval * k;
          final year = anchorDate.year + monthIndex ~/ 12;
          final month = monthIndex % 12 + 1;
          for (final day
              in _monthlyDays(year, month, rule, anchorDate.day)) {
            yield* timesFor(day);
          }
        }
      case 'YEARLY':
        for (var k = 0; ; k++) {
          final year = anchorDate.year + rule.interval * k;
          final months = rule.byMonth.isNotEmpty
              ? rule.byMonth
              : [anchorDate.month];
          final days = <DateTime>[];
          for (final month in months) {
            days.addAll(_monthlyDays(year, month, rule, anchorDate.day));
          }
          days.sort();
          for (final day in days) {
            yield* timesFor(day);
          }
        }
      default:
        // Unknown frequency: nothing to expand (caller recorded a
        // diagnostic via `unsupported` only when we recognised the part;
        // a completely unknown FREQ yields no instances).
        return;
    }
  }

  List<DateTime> _monthlyDays(
    int year,
    int month,
    Rrule rule,
    int anchorDay,
  ) {
    if (rule.byMonth.isNotEmpty && !rule.byMonth.contains(month)) {
      return const [];
    }
    if (rule.byMonthDay.isNotEmpty) {
      final days = <DateTime>[
        for (final monthDay in rule.byMonthDay)
          if (_dayOfMonth(year, month, monthDay) case final DateTime day) day,
      ];
      if (rule.byDay.isNotEmpty) {
        days.removeWhere(
          (d) => !rule.byDay.any((bd) => bd.weekday == d.weekday),
        );
      }
      return days..sort();
    }
    if (rule.byDay.isNotEmpty) {
      final days = <DateTime>[];
      for (final byDay in rule.byDay) {
        final ordinal = byDay.ordinal;
        if (ordinal == null || ordinal == 0) {
          final first = DateTime.utc(year, month, 1);
          final offset = (byDay.weekday - first.weekday + 7) % 7;
          for (var day = 1 + offset;
              day <= _daysInMonth(year, month);
              day += 7) {
            days.add(DateTime.utc(year, month, day));
          }
        } else if (_nthWeekdayOfMonth(year, month, byDay.weekday, ordinal)
            case final DateTime day) {
          days.add(day);
        }
      }
      return days..sort();
    }
    if (anchorDay > _daysInMonth(year, month)) return const [];
    return [DateTime.utc(year, month, anchorDay)];
  }
}
