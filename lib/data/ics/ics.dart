/// Attention Copilot's own RFC 5545 ICS parser.
///
/// Covers the subset needed for a trustworthy agenda: line unfolding,
/// property/parameter parsing, VEVENT extraction, DTSTART/DTEND/DURATION,
/// TZID resolution against embedded VTIMEZONE blocks with IANA fallback,
/// all-day VALUE=DATE, RRULE/RDATE/EXDATE expansion, RECURRENCE-ID
/// overrides (including RANGE=THISANDFUTURE), VALARM surfaced as provider
/// reminders, and the RFC 7986 / X-PUBLISHED-TTL refresh hints.
///
/// Malformed input never throws: problems are recorded as
/// [IcsDiagnostic]s and parsing continues with what it could recover.
library;

import 'package:timezone/timezone.dart' as tz;

part 'ics_models.dart';
part 'ics_value_parsers.dart';
part 'ics_parser.dart';
part 'ics_vtimezone.dart';
part 'ics_recurrence.dart';
