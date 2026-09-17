part of 'ics.dart';

/// Default polling cadence when the feed carries no refresh hint
/// (RFC 7986 discourages frequent polling; 30 minutes is our default).
const Duration kDefaultPollInterval = Duration(minutes: 30);

/// Hard floor for polling: no source may be polled faster than this,
/// regardless of what the feed advertises (RFC 7986 section 7 throttling).
const Duration kMinPollInterval = Duration(minutes: 15);

/// Upper bound on instances generated for a single recurrence rule, so a
/// malformed feed (e.g. SECONDLY forever) cannot hang expansion.
const int kMaxRecurrenceInstances = 10000;

/// A DATE or DATE-TIME value with its zone context.
///
/// [value] carries the components: for `VALUE=DATE` it is the date at UTC
/// midnight; for a UTC DATE-TIME (trailing `Z`) it is the exact instant;
/// for a TZID or floating DATE-TIME it is the *wall clock* time carried on
/// a UTC-midnight base. Callers must resolve wall times through a
/// `timezone.Location` before comparing against absolute instants.
class IcsDateTime {
  const IcsDateTime(
    this.value, {
    this.isDateOnly = false,
    this.isUtc = false,
    this.tzid,
  });

  final DateTime value;
  final bool isDateOnly;
  final bool isUtc;
  final String? tzid;

  @override
  String toString() =>
      'IcsDateTime(${value.toIso8601String()}, dateOnly: $isDateOnly, '
      'utc: $isUtc, tzid: $tzid)';
}

/// A reminder attached to the event by the calendar *provider* (VALARM).
///
/// Surfaced for information and as a hint; it is never a scheduling source
/// for our own alerts - the alert policy engine owns all alerting.
class ProviderReminder {
  const ProviderReminder({
    required this.action,
    required this.trigger,
    required this.relativeToEnd,
    this.repeatCount = 0,
    this.repeatInterval = Duration.zero,
    this.description,
  });

  /// `DISPLAY`, `AUDIO` or `EMAIL`.
  final String action;

  /// Relative trigger offset; negative means before the reference instant.
  final Duration trigger;

  /// When true, [trigger] is relative to the event END instead of its start.
  final bool relativeToEnd;

  /// `REPEAT` count (0 = no repetition).
  final int repeatCount;

  /// Interval between repetitions (`DURATION` inside the VALARM).
  final Duration repeatInterval;

  /// Human-readable reminder text (`DESCRIPTION`).
  final String? description;
}

/// A VEVENT as parsed: one master or one RECURRENCE-ID override.
class IcsEvent {
  const IcsEvent({
    required this.uid,
    required this.dtStart,
    this.dtEnd,
    this.duration,
    this.summary,
    this.description,
    this.location,
    this.url,
    this.status,
    this.rruleText,
    this.rdates = const [],
    this.exdates = const [],
    this.recurrenceId,
    this.rangeThisAndFuture = false,
    this.reminders = const [],
  });

  final String uid;
  final IcsDateTime dtStart;

  /// Exclusive end (DATE or DATE-TIME); null when the event carries a
  /// [duration] or nothing at all.
  final IcsDateTime? dtEnd;

  /// Absolute event duration from the `DURATION` property.
  final Duration? duration;

  final String? summary;
  final String? description;
  final String? location;

  /// Join-URL candidate (`URL` property).
  final String? url;
  final String? status;
  final String? rruleText;
  final List<IcsDateTime> rdates;
  final List<IcsDateTime> exdates;

  /// Set on override VEVENTs; null on masters.
  final IcsDateTime? recurrenceId;
  final bool rangeThisAndFuture;
  final List<ProviderReminder> reminders;

  bool get isAllDay => dtStart.isDateOnly;

  bool get isOverride => recurrenceId != null;

  /// The zone this event's wall times live in: its TZID, `UTC` for
  /// `Z`-suffixed DATE-TIMEs, null for floating times.
  String? get timezoneName {
    if (dtStart.isDateOnly) return dtStart.tzid;
    if (dtStart.isUtc) return 'UTC';
    return dtStart.tzid;
  }
}

/// One concrete instance of an event at an absolute instant, produced by
/// expanding masters, RDATEs and RECURRENCE-ID overrides.
class IcsOccurrence {
  const IcsOccurrence({
    required this.uid,
    required this.startUtc,
    required this.endUtc,
    required this.isAllDay,
    required this.timezoneName,
    required this.fromOverride,
    this.recurrenceId,
    this.summary,
    this.description,
    this.location,
    this.url,
    this.reminders = const [],
  });

  final String uid;

  /// Absolute start instant. For all-day occurrences this is the date at
  /// UTC midnight; consumers must render all-day items by date.
  final DateTime startUtc;

  /// Exclusive absolute end instant (all-day: exclusive end date at UTC
  /// midnight).
  final DateTime endUtc;
  final bool isAllDay;

  /// Zone the instance was defined in: TZID, `UTC`, or null when floating.
  final String? timezoneName;

  /// True when this occurrence came from a RECURRENCE-ID override.
  final bool fromOverride;

  /// The original recurrence instant this occurrence replaced (overrides
  /// only).
  final DateTime? recurrenceId;

  final String? summary;
  final String? description;
  final String? location;
  final String? url;
  final List<ProviderReminder> reminders;
}

/// Non-fatal problem found while parsing or expanding. The parser keeps
/// going and records these instead of throwing into the agenda.
class IcsDiagnostic {
  const IcsDiagnostic(this.message, {this.context});

  final String message;

  /// Event UID or property the diagnostic refers to, when known.
  final String? context;

  @override
  String toString() => 'ICS: $message${context == null ? '' : ' ($context)'}';
}

/// A parsed calendar feed.
class IcsCalendar {
  IcsCalendar._({
    required this.prodId,
    required this.calendarName,
    required this.refreshInterval,
    required this.publishedTtl,
    required this.events,
    required this.embeddedTimezones,
    required this.diagnostics,
    required IcsExpander expander,
  }) : // The expander stays a private field with a descriptive parameter
      // name; `this._expander` is not legal for named parameters.
      // ignore: prefer_initializing_formals
      _expander = expander,
       pollInterval = resolvePollInterval(
         refreshInterval: refreshInterval,
         publishedTtl: publishedTtl,
       );

  final String? prodId;
  final String? calendarName;

  /// Raw `REFRESH-INTERVAL` hint (RFC 7986), if present.
  final Duration? refreshInterval;

  /// Raw `X-PUBLISHED-TTL` hint (MS-OXCICAL), if present.
  final Duration? publishedTtl;

  /// The cadence the caller must poll at: REFRESH-INTERVAL, else
  /// X-PUBLISHED-TTL, else 30 minutes - never faster than 15 minutes.
  final Duration pollInterval;

  final List<IcsEvent> events;

  /// VTIMEZONE blocks parsed into resolvable locations, keyed by TZID.
  final Map<String, tz.Location> embeddedTimezones;

  /// Parse/expansion problems. The consumer must never trust local times
  /// from entries whose zone could not be resolved; those are recorded here.
  final List<IcsDiagnostic> diagnostics;

  final IcsExpander _expander;

  /// Expands every event (masters, RDATEs, RECURRENCE-ID overrides) into
  /// absolute occurrences inside the UTC window `[windowStart, windowEnd)`.
  ///
  /// [floatingZone] overrides the parser's floating zone for this call; by
  /// default floating times resolve against the parser's floating zone
  /// (UTC when none was configured).
  List<IcsOccurrence> expandOccurrences(
    DateTime windowStart,
    DateTime windowEnd, {
    tz.Location? floatingZone,
  }) {
    return _expander.expand(
      windowStart,
      windowEnd,
      floatingZone: floatingZone,
    );
  }
}

/// REFRESH-INTERVAL > X-PUBLISHED-TTL > default, clamped to the floor.
Duration resolvePollInterval({
  Duration? refreshInterval,
  Duration? publishedTtl,
}) {
  var interval = refreshInterval ?? publishedTtl ?? kDefaultPollInterval;
  if (interval < kMinPollInterval) interval = kMinPollInterval;
  return interval;
}
