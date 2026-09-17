part of 'ics.dart';

/// Parses a DATE value (`YYYYMMDD`) into a UTC-midnight carrier.
DateTime parseIcsDate(String raw) {
  if (raw.length != 8) {
    throw FormatException('invalid ICS DATE: $raw');
  }
  final year = int.parse(raw.substring(0, 4));
  final month = int.parse(raw.substring(4, 6));
  final day = int.parse(raw.substring(6, 8));
  return DateTime.utc(year, month, day);
}

/// Parses a DATE-TIME value (`YYYYMMDDTHHMMSS` with optional trailing `Z`).
///
/// The result is a wall-clock carrier on a UTC base; a trailing `Z` marks
/// it as an exact UTC instant.
DateTime parseIcsDateTime(String raw) {
  if (raw.length != 15 && raw.length != 16) {
    throw FormatException('invalid ICS DATE-TIME: $raw');
  }
  final year = int.parse(raw.substring(0, 4));
  final month = int.parse(raw.substring(4, 6));
  final day = int.parse(raw.substring(6, 8));
  if (raw[8] != 'T') {
    throw FormatException('invalid ICS DATE-TIME (missing T): $raw');
  }
  final hour = int.parse(raw.substring(9, 11));
  final minute = int.parse(raw.substring(11, 13));
  final second = int.parse(raw.substring(13, 15));
  return DateTime.utc(year, month, day, hour, minute, second);
}

/// Parses a property value into an [IcsDateTime], honouring the
/// `VALUE=DATE` and `TZID` parameters (RFC 5545 section 3.3.5).
IcsDateTime parseIcsDateTimeValue(
  String raw,
  Map<String, List<String>> params,
) {
  final valueType = (params['VALUE'] ?? const []).firstOrNull;
  if (valueType == 'DATE') {
    return IcsDateTime(parseIcsDate(raw), isDateOnly: true);
  }
  if (valueType != null && valueType != 'DATE-TIME') {
    throw FormatException('unsupported ICS value type: $valueType');
  }
  final tzid = (params['TZID'] ?? const []).firstOrNull;
  if (raw.endsWith('Z')) {
    return IcsDateTime(parseIcsDateTime(raw), isUtc: true);
  }
  return IcsDateTime(parseIcsDateTime(raw), tzid: tzid);
}

/// Parses an ISO 8601 duration (`P2W`, `P1D`, `PT1H30M`, `-PT10M`, ...).
Duration parseIcsDuration(String raw) {
  final match = _durationPattern.firstMatch(raw.toUpperCase());
  if (match == null) {
    throw FormatException('invalid ICS DURATION: $raw');
  }
  final sign = match.group(1) == '-' ? -1 : 1;
  final weeks = int.tryParse(match.group(2) ?? '');
  final days = int.tryParse(match.group(3) ?? '');
  final hours = int.tryParse(match.group(4) ?? '');
  final minutes = int.tryParse(match.group(5) ?? '');
  final seconds = int.tryParse(match.group(6) ?? '');
  if (weeks == null &&
      days == null &&
      hours == null &&
      minutes == null &&
      seconds == null) {
    throw FormatException('invalid ICS DURATION: $raw');
  }
  return Duration(
    days: (weeks ?? 0) * 7 + (days ?? 0),
    hours: hours ?? 0,
    minutes: minutes ?? 0,
    seconds: seconds ?? 0,
  ) *
      sign;
}

final RegExp _durationPattern = RegExp(
  r'^([+-])?P(?:(\d+)W|(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?)$',
);

/// Parses a UTC offset value (`+0100`, `-053000`, ...).
Duration parseIcsUtcOffset(String raw) {
  final match = RegExp(r'^([+-])(\d{2})(\d{2})(\d{2})?$').firstMatch(raw);
  if (match == null) {
    throw FormatException('invalid ICS UTC offset: $raw');
  }
  final sign = match.group(1) == '-' ? -1 : 1;
  final hours = int.parse(match.group(2)!);
  final minutes = int.parse(match.group(3)!);
  final seconds = int.parse(match.group(4) ?? '0');
  return Duration(hours: hours, minutes: minutes, seconds: seconds) * sign;
}

/// Reverses RFC 5545 TEXT escaping: `\\`, `\,`, `\;`, `\n`, `\N`.
String unescapeIcsText(String raw) {
  final buffer = StringBuffer();
  var escaped = false;
  for (final rune in raw.runes) {
    if (escaped) {
      if (rune == 0x6E /* n */ || rune == 0x4E /* N */) {
        buffer.write('\n');
      } else if (rune == 0x5C /* \ */ ||
          rune == 0x2C /* , */ ||
          rune == 0x3B /* ; */) {
        buffer.writeCharCode(rune);
      } else {
        buffer.writeCharCode(rune);
      }
      escaped = false;
      continue;
    }
    if (rune == 0x5C) {
      escaped = true;
      continue;
    }
    buffer.writeCharCode(rune);
  }
  if (escaped) buffer.write('\\');
  return buffer.toString();
}

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
