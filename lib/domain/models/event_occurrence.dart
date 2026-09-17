import 'calendar_event.dart';
import 'calendar_source_id.dart';
import 'meeting_join_info.dart';

/// A concrete instance of a [CalendarEvent] at absolute instants: one
/// occurrence of the master event (recurring expansions and one-off events
/// both materialise as occurrences).
///
/// Immutable: all fields are final and the class is a pure value type with
/// structural equality.
///
/// Invariants:
///  * [startUtc] and [endUtc] are absolute UTC instants (`isUtc == true`);
///    [endUtc] is exclusive and strictly after [startUtc].
///  * For all-day occurrences [startUtc]/[endUtc] are the day boundaries
///    (local midnight instants) in the event's original timezone.
class EventOccurrence {
  const EventOccurrence({
    required this.id,
    required this.event,
    required this.source,
    required this.startUtc,
    required this.endUtc,
    this.isAllDay = false,
  });

  /// Stable identifier of this occurrence (event id + instance key), used as
  /// the final tie-break so ordering never depends on input order.
  final String id;

  /// The master event this occurrence instantiates.
  final CalendarEvent event;

  /// The calendar source this occurrence was ingested from.
  final CalendarSourceId source;

  /// Absolute UTC start instant, inclusive.
  final DateTime startUtc;

  /// Absolute UTC end instant, exclusive.
  final DateTime endUtc;

  final bool isAllDay;

  /// Event metadata delegated from [event] for convenient access.
  String get title => event.title;
  String? get location => event.location;
  String? get originalTimezoneId => event.originalTimezoneId;

  /// Conference entry point, when the provider supplied one.
  MeetingJoinInfo? get joinInfo => event.joinInfo;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EventOccurrence &&
          other.id == id &&
          other.event == event &&
          other.source == source &&
          other.startUtc == startUtc &&
          other.endUtc == endUtc &&
          other.isAllDay == isAllDay;

  @override
  int get hashCode =>
      Object.hash(id, event, source, startUtc, endUtc, isAllDay);

  @override
  String toString() =>
      'EventOccurrence(id: $id, title: $title, startUtc: $startUtc, '
      'endUtc: $endUtc, isAllDay: $isAllDay)';
}
