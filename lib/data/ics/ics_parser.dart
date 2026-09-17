part of 'ics.dart';

/// Unfolds an iCalendar body into physical content lines (RFC 5545 3.1):
/// CRLF/LF/CR line endings are normalised, then continuations (a line break
/// followed by a single space or tab) are joined.
List<String> unfoldIcsLines(String body) {
  final normalized = body
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');
  final unfolded = normalized.replaceAll(RegExp(r'\n[ \t]'), '');
  return unfolded
      .split('\n')
      .where((line) => line.isNotEmpty)
      .toList();
}

/// One tokenised content line: property name, parameters and raw value.
class IcsContentLine {
  const IcsContentLine({
    required this.name,
    required this.params,
    required this.value,
  });

  final String name;
  final Map<String, List<String>> params;
  final String value;

  /// Splits a physical content line into `NAME;PARAM=...;PARAM=...:VALUE`.
  ///
  /// The separator scan is quote-aware, so a quoted parameter value may
  /// contain `:` and `;` characters (RFC 5545 section 3.2).
  static IcsContentLine parse(String line) {
    var sep = -1;
    var inQuote = false;
    var escaped = false;
    for (var i = 0; i < line.length; i++) {
      final c = line.codeUnitAt(i);
      if (escaped) {
        escaped = false;
        continue;
      }
      if (c == 0x5C) {
        escaped = true;
        continue;
      }
      if (c == 0x22) {
        inQuote = !inQuote;
        continue;
      }
      if (!inQuote && (c == 0x3A /* : */ || c == 0x3B /* ; */)) {
        sep = i;
        break;
      }
    }

    final String name;
    final Map<String, List<String>> params;
    if (sep == -1) {
      // Degenerate line without separator: whole thing is the name.
      name = line.trim().toUpperCase();
      params = const {};
      return IcsContentLine(name: name, params: params, value: '');
    }

    final head = line.substring(0, sep);
    final separator = line[sep];
    if (separator == ';') {
      // Name ends at the first ';'. Find the next unquoted ':'.
      final rest = line.substring(sep + 1);
      final colon = _findUnquotedColon(rest);
      name = head.toUpperCase();
      final paramText = colon == -1 ? rest : rest.substring(0, colon);
      params = _parseParams(paramText);
      final value = colon == -1 ? '' : rest.substring(colon + 1);
      return IcsContentLine(name: name, params: params, value: value);
    }
    name = head.toUpperCase();
    params = const {};
    return IcsContentLine(
      name: name,
      params: params,
      value: line.substring(sep + 1),
    );
  }

  static int _findUnquotedColon(String text) {
    var inQuote = false;
    var escaped = false;
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (escaped) {
        escaped = false;
        continue;
      }
      if (c == 0x5C) {
        escaped = true;
        continue;
      }
      if (c == 0x22) {
        inQuote = !inQuote;
        continue;
      }
      if (!inQuote && c == 0x3A) return i;
    }
    return -1;
  }

  static Map<String, List<String>> _parseParams(String text) {
    final params = <String, List<String>>{};
    if (text.isEmpty) return params;
    final parts = _splitOutsideQuotes(text, ';');
    for (final part in parts) {
      final eq = _findUnquotedEquals(part);
      if (eq == -1) {
        params.putIfAbsent(part.toUpperCase(), () => const []);
        continue;
      }
      final key = part.substring(0, eq).toUpperCase();
      final rawValues = _splitOutsideQuotes(part.substring(eq + 1), ',');
      final values = rawValues.map(_unquote).toList();
      params[key] = values;
    }
    return params;
  }

  static int _findUnquotedEquals(String text) {
    var inQuote = false;
    var escaped = false;
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (escaped) {
        escaped = false;
        continue;
      }
      if (c == 0x5C) {
        escaped = true;
        continue;
      }
      if (c == 0x22) {
        inQuote = !inQuote;
        continue;
      }
      if (!inQuote && c == 0x3D) return i;
    }
    return -1;
  }

  static List<String> _splitOutsideQuotes(String text, String sep) {
    final code = sep.codeUnitAt(0);
    final result = <String>[];
    var start = 0;
    var inQuote = false;
    var escaped = false;
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (escaped) {
        escaped = false;
        continue;
      }
      if (c == 0x5C) {
        escaped = true;
        continue;
      }
      if (c == 0x22) {
        inQuote = !inQuote;
        continue;
      }
      if (!inQuote && c == code) {
        result.add(text.substring(start, i));
        start = i + 1;
      }
    }
    result.add(text.substring(start));
    return result;
  }

  static String _unquote(String raw) {
    final trimmed = raw.trim();
    if (trimmed.length >= 2 &&
        trimmed.startsWith('"') &&
        trimmed.endsWith('"')) {
      return trimmed.substring(1, trimmed.length - 1);
    }
    return trimmed;
  }

  @override
  String toString() =>
      'IcsContentLine($name, params: $params, value: $value)';
}

/// Parses an iCalendar body into an [IcsCalendar].
class IcsParser {
  IcsParser({
    tz.Location? floatingZone,
    tz.Location? Function(String name)? ianaResolver,
  }) : _floatingZone = floatingZone ?? _utcLocation(),
       _ianaResolver = ianaResolver ?? _defaultIanaResolver;

  final tz.Location _floatingZone;
  final tz.Location? Function(String name) _ianaResolver;

  /// Parses [body]. Malformed input never throws: problems are collected in
  /// [IcsCalendar.diagnostics] and parsing continues.
  IcsCalendar parse(String body) {
    final diagnostics = <IcsDiagnostic>[];
    final lines = unfoldIcsLines(body);

    // --- Build the component tree -------------------------------
    final root = _Component('ROOT');
    final stack = <_Component>[root];
    for (final line in lines) {
      final IcsContentLine content;
      try {
        content = IcsContentLine.parse(line);
      } on FormatException {
        diagnostics.add(IcsDiagnostic('unparseable content line: $line'));
        continue;
      }
      switch (content.name) {
        case 'BEGIN':
          stack.add(_Component(content.value.toUpperCase()));
        case 'END':
          final expected = content.value.toUpperCase();
          if (stack.length <= 1) {
            diagnostics.add(IcsDiagnostic('END:$expected without BEGIN'));
            break;
          }
          final closed = stack.removeLast();
          if (closed.name != expected) {
            diagnostics.add(IcsDiagnostic(
              'END:$expected does not match BEGIN:${closed.name}',
            ));
          }
          stack.last.children.add(closed);
        default:
          stack.last.properties
              .putIfAbsent(content.name, () => <IcsContentLine>[])
              .add(content);
      }
    }
    // Whatever was left open (truncated input) is attached as best effort.
    while (stack.length > 1) {
      final open = stack.removeLast();
      diagnostics.add(
        IcsDiagnostic('unterminated component: ${open.name}'),
      );
      stack.last.children.add(open);
    }

    // --- Interpret the tree --------------------------------------
    final calendars = root.children
        .where((c) => c.name == 'VCALENDAR')
        .toList();
    final events = <IcsEvent>[];
    final timezones = <String, tz.Location>{};

    String? prodId;
    String? calendarName;
    Duration? refreshInterval;
    Duration? publishedTtl;
    var sawCalendar = false;

    for (final cal in calendars) {
      sawCalendar = true;
      prodId ??= _firstValue(cal, 'PRODID');
      calendarName ??= _firstValue(cal, 'X-WR-CALNAME');
      refreshInterval ??= _durationValue(
        cal,
        'REFRESH-INTERVAL',
        diagnostics,
      );
      publishedTtl ??= _durationValue(
        cal,
        'X-PUBLISHED-TTL',
        diagnostics,
      );
      for (final child in cal.children) {
        switch (child.name) {
          case 'VEVENT':
            final event = _assembleEvent(child, diagnostics);
            if (event != null) events.add(event);
          case 'VTIMEZONE':
            final built = _assembleVTimezone(child, diagnostics);
            if (built != null) {
              final (name, location) = built;
              timezones[name] = location;
            }
          default:
            break; // VCALENDAR-level children we do not model.
        }
      }
    }

    if (!sawCalendar) {
      diagnostics.add(IcsDiagnostic('no VCALENDAR component found'));
    }

    final expander = IcsExpander(
      events: events,
      embeddedTimezones: timezones,
      diagnostics: diagnostics,
      floatingZone: _floatingZone,
      ianaResolver: _ianaResolver,
    );

    return IcsCalendar._(
      prodId: prodId,
      calendarName: calendarName,
      refreshInterval: refreshInterval,
      publishedTtl: publishedTtl,
      events: events,
      embeddedTimezones: timezones,
      diagnostics: diagnostics,
      expander: expander,
    );
  }

  // --- VEVENT assembly ------------------------------------------

  IcsEvent? _assembleEvent(
    _Component comp,
    List<IcsDiagnostic> diagnostics,
  ) {
    final uid = _firstValue(comp, 'UID') ?? '';
    final dtStartLine = _firstLine(comp, 'DTSTART');
    if (dtStartLine == null) {
      diagnostics.add(
        IcsDiagnostic('VEVENT without DTSTART skipped', context: uid),
      );
      return null;
    }

    final IcsDateTime dtStart;
    try {
      dtStart = parseIcsDateTimeValue(dtStartLine.value, dtStartLine.params);
    } on FormatException {
      diagnostics.add(
        IcsDiagnostic('invalid DTSTART: ${dtStartLine.value}', context: uid),
      );
      return null;
    }

    final dtEnd = _optionalDateTime(
      comp,
      'DTEND',
      uid,
      diagnostics,
    );
    final duration = _optionalDuration(comp, 'DURATION', uid, diagnostics);

    final recurrenceId = _optionalDateTime(
      comp,
      'RECURRENCE-ID',
      uid,
      diagnostics,
    );
    final rangeParam = _firstLine(comp, 'RECURRENCE-ID')?.params['RANGE'];
    final rangeThisAndFuture =
        rangeParam != null && rangeParam.contains('THISANDFUTURE');

    final reminders = <ProviderReminder>[
      for (final alarm in comp.children.where((c) => c.name == 'VALARM'))
        if (_assembleAlarm(alarm, dtStart, dtEnd, uid, diagnostics)
            case final ProviderReminder reminder)
          reminder,
    ];

    final rdates = <IcsDateTime>[];
    for (final line in _lines(comp, 'RDATE')) {
      try {
        rdates.addAll(_splitValueList(line.value)
            .map((v) => parseIcsDateTimeValue(v, line.params)));
      } on FormatException {
        diagnostics.add(
          IcsDiagnostic('invalid RDATE: ${line.value}', context: uid),
        );
      }
    }

    final exdates = <IcsDateTime>[];
    for (final line in _lines(comp, 'EXDATE')) {
      try {
        exdates.addAll(_splitValueList(line.value)
            .map((v) => parseIcsDateTimeValue(v, line.params)));
      } on FormatException {
        diagnostics.add(
          IcsDiagnostic('invalid EXDATE: ${line.value}', context: uid),
        );
      }
    }

    return IcsEvent(
      uid: uid.isEmpty ? _syntheticUid(comp) : uid,
      dtStart: dtStart,
      dtEnd: dtEnd,
      duration: duration,
      summary: _textValue(comp, 'SUMMARY'),
      description: _textValue(comp, 'DESCRIPTION'),
      location: _textValue(comp, 'LOCATION'),
      url: _firstValue(comp, 'URL'),
      status: _firstValue(comp, 'STATUS')?.toUpperCase(),
      rruleText: _firstValue(comp, 'RRULE'),
      rdates: rdates,
      exdates: exdates,
      recurrenceId: recurrenceId,
      rangeThisAndFuture: rangeThisAndFuture,
      reminders: reminders,
    );
  }

  String _syntheticUid(_Component comp) {
    final hash = comp.properties.values
        .expand((lines) => lines)
        .map((l) => '${l.name}:${l.value}')
        .join('\n');
    return 'ac-${hash.hashCode.toRadixString(16)}';
  }

  // --- VALARM assembly ------------------------------------------

  ProviderReminder? _assembleAlarm(
    _Component alarm,
    IcsDateTime dtStart,
    IcsDateTime? dtEnd,
    String uid,
    List<IcsDiagnostic> diagnostics,
  ) {
    final action = _firstValue(alarm, 'ACTION')?.toUpperCase() ?? 'DISPLAY';
    final triggerLine = _firstLine(alarm, 'TRIGGER');
    if (triggerLine == null) {
      diagnostics.add(
        IcsDiagnostic('VALARM without TRIGGER skipped', context: uid),
      );
      return null;
    }

    // Absolute trigger: distance from the event start.
    if ((triggerLine.params['VALUE'] ?? const []).contains('DATE-TIME')) {
      final IcsDateTime absolute;
      try {
        absolute = parseIcsDateTimeValue(triggerLine.value, triggerLine.params);
      } on FormatException {
        diagnostics.add(
          IcsDiagnostic('invalid VALARM TRIGGER: ${triggerLine.value}',
              context: uid),
        );
        return null;
      }
      final startMs = _approximateInstantMs(dtStart);
      final triggerMs = _approximateInstantMs(absolute);
      final relativeToEnd =
          (triggerLine.params['RELATED'] ?? const []).contains('END');
      final referenceMs =
          relativeToEnd && dtEnd != null ? _approximateInstantMs(dtEnd) : startMs;
      return ProviderReminder(
        action: action,
        trigger: Duration(milliseconds: triggerMs - referenceMs),
        relativeToEnd: relativeToEnd,
        repeatCount: _intValue(alarm, 'REPEAT'),
        repeatInterval: _optionalDuration(alarm, 'DURATION', uid, diagnostics) ??
            Duration.zero,
        description: _textValue(alarm, 'DESCRIPTION'),
      );
    }

    // Relative trigger.
    final Duration trigger;
    try {
      trigger = parseIcsDuration(triggerLine.value);
    } on FormatException {
      diagnostics.add(
        IcsDiagnostic('invalid VALARM TRIGGER: ${triggerLine.value}',
            context: uid),
      );
      return null;
    }
    final relativeToEnd =
        (triggerLine.params['RELATED'] ?? const []).contains('END');
    return ProviderReminder(
      action: action,
      trigger: trigger,
      relativeToEnd: relativeToEnd,
      repeatCount: _intValue(alarm, 'REPEAT'),
      repeatInterval: _optionalDuration(alarm, 'DURATION', uid, diagnostics) ??
          Duration.zero,
      description: _textValue(alarm, 'DESCRIPTION'),
    );
  }

  /// Best-effort instant for alarm maths: DATE and wall times are treated
  /// on a UTC carrier. VALARM values are hints only, never scheduling input.
  static int _approximateInstantMs(IcsDateTime value) =>
      value.value.millisecondsSinceEpoch;

  // --- VTIMEZONE assembly ---------------------------------------

  (String, tz.Location)? _assembleVTimezone(
    _Component comp,
    List<IcsDiagnostic> diagnostics,
  ) {
    final tzid = _firstValue(comp, 'TZID');
    if (tzid == null) {
      diagnostics.add(IcsDiagnostic('VTIMEZONE without TZID skipped'));
      return null;
    }
    try {
      final location = buildVTimezoneLocation(
        tzid,
        comp.children
            .where((c) => c.name == 'STANDARD' || c.name == 'DAYLIGHT')
            .map(_observanceFromComponent)
            .whereType<VtzObservance>()
            .toList(),
      );
      return (tzid, location);
    } on FormatException catch (e) {
      diagnostics.add(
        IcsDiagnostic('VTIMEZONE $tzid could not be built: ${e.message}'),
      );
      return null;
    }
  }

  VtzObservance? _observanceFromComponent(_Component comp) {
    final dtStartLine = _firstLine(comp, 'DTSTART');
    final offsetFromRaw = _firstValue(comp, 'TZOFFSETFROM');
    final offsetToRaw = _firstValue(comp, 'TZOFFSETTO');
    if (dtStartLine == null || offsetFromRaw == null || offsetToRaw == null) {
      return null;
    }
    try {
      return VtzObservance(
        isDaylight: comp.name == 'DAYLIGHT',
        dtStart: parseIcsDateTime(dtStartLine.value),
        offsetFrom: parseIcsUtcOffset(offsetFromRaw),
        offsetTo: parseIcsUtcOffset(offsetToRaw),
        rrule: _firstValue(comp, 'RRULE'),
        rdates: _lines(comp, 'RDATE').map((l) => l.value).toList(),
        abbreviation: _firstValue(comp, 'TZNAME'),
      );
    } on FormatException {
      return null;
    }
  }

  // --- Small helpers --------------------------------------------

  static List<String> _splitValueList(String value) {
    final parts = value.split(',');
    // Dates and date-times never contain escaped commas; a naive split is
    // fine for the RFC 5545 value types we accept (DATE / DATE-TIME).
    return parts.where((p) => p.isNotEmpty).toList();
  }

  static String? _firstValue(_Component comp, String name) =>
      _firstLine(comp, name)?.value;

  static List<IcsContentLine> _lines(_Component comp, String name) =>
      comp.properties[name] ?? const [];

  static IcsContentLine? _firstLine(_Component comp, String name) {
    final lines = comp.properties[name];
    return lines == null || lines.isEmpty ? null : lines.first;
  }

  static String? _textValue(_Component comp, String name) {
    final raw = _firstValue(comp, name);
    return raw == null ? null : unescapeIcsText(raw);
  }

  static int _intValue(_Component comp, String name) {
    final raw = _firstValue(comp, name);
    return raw == null ? 0 : (int.tryParse(raw) ?? 0);
  }

  static Duration? _durationValue(
    _Component comp,
    String name,
    List<IcsDiagnostic> diagnostics,
  ) {
    final raw = _firstValue(comp, name);
    if (raw == null) return null;
    try {
      return parseIcsDuration(raw);
    } on FormatException {
      diagnostics.add(IcsDiagnostic('invalid $name: $raw'));
      return null;
    }
  }

  static Duration? _optionalDuration(
    _Component comp,
    String name,
    String uid,
    List<IcsDiagnostic> diagnostics,
  ) {
    final raw = _firstValue(comp, name);
    if (raw == null) return null;
    try {
      return parseIcsDuration(raw);
    } on FormatException {
      diagnostics.add(IcsDiagnostic('invalid $name: $raw', context: uid));
      return null;
    }
  }

  static IcsDateTime? _optionalDateTime(
    _Component comp,
    String name,
    String uid,
    List<IcsDiagnostic> diagnostics,
  ) {
    final line = _firstLine(comp, name);
    if (line == null) return null;
    try {
      return parseIcsDateTimeValue(line.value, line.params);
    } on FormatException {
      diagnostics.add(
        IcsDiagnostic('invalid $name: ${line.value}', context: uid),
      );
      return null;
    }
  }

  static tz.Location? _defaultIanaResolver(String name) {
    try {
      return tz.getLocation(name);
    } catch (_) {
      return null;
    }
  }
}

/// Minimal generic iCalendar component tree used during parsing.
class _Component {
  _Component(this.name);

  final String name;
  final Map<String, List<IcsContentLine>> properties = {};
  final List<_Component> children = [];
}

/// A UTC location that does not require the timezone database.
tz.Location _utcLocation() => tz.Location('UTC', const [], const [], [
      tz.TimeZone(Duration.zero, isDst: false, abbreviation: 'UTC'),
    ]);
