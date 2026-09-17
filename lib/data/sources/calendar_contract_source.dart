import 'package:flutter/services.dart';

import '../../domain/models/calendar_event.dart';
import '../../domain/models/calendar_source_id.dart';
import '../../domain/models/event_occurrence.dart';
import 'source.dart';

/// Name of the native `MethodChannel` implemented by the Android
/// `CalendarPlugin` (`android/app/src/main/kotlin/.../CalendarPlugin.kt`).
const String kCalendarContractMethodChannel = 'attention_copilot/calendar';

/// A device calendar (account row) surfaced by `listCalendars`.
///
/// Immutable value type with structural equality.
class ContractCalendar {
  const ContractCalendar({
    required this.id,
    required this.displayName,
    this.accountName,
    required this.visible,
  });

  /// Provider id of the calendar (CalendarContract `_ID`).
  final int id;

  final String displayName;

  /// Owning account (e.g. the Google account), or null when not provided.
  final String? accountName;

  final bool visible;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ContractCalendar &&
          other.id == id &&
          other.displayName == displayName &&
          other.accountName == accountName &&
          other.visible == visible;

  @override
  int get hashCode => Object.hash(id, displayName, accountName, visible);

  @override
  String toString() =>
      'ContractCalendar(id: $id, displayName: $displayName, '
      'accountName: $accountName, visible: $visible)';
}

/// Read-only calendar source over the Android system CalendarContract
/// provider (pre-expanded recurring instances), bridged by the native
/// `CalendarPlugin`.
///
/// Permission model:
///  * [permissionState] reports the last known posture; it starts as
///    [SourcePermissionState.denied] because nothing has been granted yet and
///    a fetch before the grant would fail anyway. The orchestrator therefore
///    surfaces `permission-denied` instead of a misleading empty agenda.
///  * [hasPermission] re-checks the native grant and caches the outcome.
///  * [requestPermission] asks Android at runtime (first install or after a
///    "don't ask again" denial the user must use system settings).
///  * [fetch] re-checks the grant on every call and throws
///    [SourcePermissionDeniedException] rather than returning an
///    empty-but-successful snapshot.
///
/// Window model: [fetch] reads `[cursorEnd, now + lookAhead)`; on the first
/// fetch the window also reaches `lookBack` into the past. The cursor
/// returned by a snapshot carries the window end so consecutive fetches
/// expand the window without re-reading it (CalendarContract has no deltas).
class CalendarContractSource extends CalendarSource {
  CalendarContractSource({
    DateTime Function()? clock,
    this.lookBack = const Duration(days: 1),
    this.lookAhead = const Duration(days: 7),
    MethodChannel? channel,
  })  : assert(lookBack >= Duration.zero),
        assert(lookAhead >= Duration.zero),
        _clock = clock ?? DateTime.now,
        _channel = channel ?? const MethodChannel(kCalendarContractMethodChannel);

  static const CalendarSourceId _sourceId = CalendarSourceId(
    id: 'calendarcontract',
    displayName: 'Android calendars',
    priority: 10,
  );

  /// How far into the past the first (cursorless) fetch reaches.
  final Duration lookBack;

  /// How far into the future every fetch window reaches.
  final Duration lookAhead;

  final DateTime Function() _clock;
  final MethodChannel _channel;

  SourcePermissionState _cachedPermissionState = SourcePermissionState.denied;

  @override
  CalendarSourceId get sourceId => _sourceId;

  @override
  SourcePermissionState get permissionState => _cachedPermissionState;

  /// Queries the native `hasPermission` and returns the cached posture.
  Future<bool> hasPermission() async {
    final granted = await _nativeHasPermission();
    _cachedPermissionState =
        granted ? SourcePermissionState.granted : SourcePermissionState.denied;
    return granted;
  }

  /// Requests `READ_CALENDAR` at runtime and caches the outcome.
  ///
  /// Returns false both when the user declines and when the platform reports
  /// no usable grant (missing plugin, no attached activity, ...).
  Future<bool> requestPermission() async {
    try {
      final granted =
          await _channel.invokeMethod<bool>('requestPermission') ?? false;
      _cachedPermissionState = granted
          ? SourcePermissionState.granted
          : SourcePermissionState.denied;
      return granted;
    } on MissingPluginException {
      _cachedPermissionState = SourcePermissionState.denied;
      return false;
    } on PlatformException {
      _cachedPermissionState = SourcePermissionState.denied;
      return false;
    }
  }

  /// Enumerates the visible device calendars.
  Future<List<ContractCalendar>> listCalendars() async {
    final raw = await _channel.invokeListMethod<Object?>('listCalendars') ??
        const <Object?>[];
    return List.unmodifiable(
      raw.map(_calendarFromRow).whereType<ContractCalendar>(),
    );
  }

  @override
  Future<SourceSnapshot> fetch(SourceCursor? cursor) async {
    final granted = await _nativeHasPermission();
    _cachedPermissionState =
        granted ? SourcePermissionState.granted : SourcePermissionState.denied;
    if (!granted) {
      throw const SourcePermissionDeniedException(
        'READ_CALENDAR is not granted',
      );
    }

    final (from, to) = _windowFor(cursor);
    final raw = await _listInstances(from, to);
    return SourceSnapshot(
      occurrences: List.unmodifiable(
        raw.map(_occurrenceFromRow).whereType<EventOccurrence>(),
      ),
      nextCursor: SourceCursor(_WindowCursor(to)),
    );
  }

  Future<bool> _nativeHasPermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasPermission') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<List<Object?>> _listInstances(int fromMillis, int toMillis) async {
    try {
      return await _channel.invokeListMethod<Object?>(
            'listInstances',
            <String, Object>{'fromMillis': fromMillis, 'toMillis': toMillis},
          ) ??
          const <Object?>[];
    } on MissingPluginException {
      throw const SourcePermissionDeniedException(
        'calendar plugin not registered on this platform',
      );
    } on PlatformException catch (error) {
      if (error.code == 'permission_denied') {
        throw const SourcePermissionDeniedException(
          'READ_CALENDAR is not granted',
        );
      }
      rethrow;
    }
  }

  (int, int) _windowFor(SourceCursor? cursor) {
    final now = _clock();
    final to = now.add(lookAhead).millisecondsSinceEpoch;
    final previous = switch (cursor?.value) {
      final _WindowCursor c => c.throughMillis,
      _ => null,
    };
    final from = previous == null
        ? now.subtract(lookBack).millisecondsSinceEpoch
        : (previous > to ? to : previous);
    return (from, to);
  }

  EventOccurrence? _occurrenceFromRow(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final eventId = (raw['eventId'] as num?)?.toInt();
    final begin = (raw['beginMillis'] as num?)?.toInt();
    final end = (raw['endMillis'] as num?)?.toInt();
    if (eventId == null || begin == null || end == null || end <= begin) {
      return null;
    }
    final title = raw['title'] as String? ?? '';
    return EventOccurrence(
      // `eventId/begin` is stable for one expanded instance (an event id plus
      // the instance start instant) and sorts deterministically as a
      // tie-break without depending on input order.
      id: '$eventId/$begin',
      event: CalendarEvent(
        id: '$eventId',
        title: title.isEmpty ? '(no title)' : title,
        location: raw['location'] as String?,
      ),
      source: _sourceId,
      startUtc: DateTime.fromMillisecondsSinceEpoch(begin, isUtc: true),
      endUtc: DateTime.fromMillisecondsSinceEpoch(end, isUtc: true),
      isAllDay: (raw['allDay'] as num?)?.toInt() != 0,
    );
  }

  ContractCalendar? _calendarFromRow(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final id = (raw['id'] as num?)?.toInt();
    if (id == null) {
      return null;
    }
    return ContractCalendar(
      id: id,
      displayName: raw['displayName'] as String? ?? '',
      accountName: raw['accountName'] as String?,
      visible: raw['visible'] == 1 || raw['visible'] == true,
    );
  }
}

/// Opaque cursor payload: the exclusive end (millis) of the last fetched
/// window, used as the start of the next one.
class _WindowCursor {
  const _WindowCursor(this.throughMillis);

  final int throughMillis;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _WindowCursor && other.throughMillis == throughMillis;

  @override
  int get hashCode => throughMillis.hashCode;
}
