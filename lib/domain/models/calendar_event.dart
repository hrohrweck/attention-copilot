import 'meeting_join_info.dart';

/// The master record of a calendar entry: stable identity plus the metadata
/// that never changes between occurrences (title, location, conference URL).
///
/// Immutable: all fields are final and the class is a pure value type with
/// structural equality. A [CalendarEvent] carries no time information -
/// concrete instances are modelled as [EventOccurrence]s.
class CalendarEvent {
  const CalendarEvent({
    required this.id,
    required this.title,
    this.location,
    this.originalTimezoneId,
    this.joinInfo,
  });

  /// Stable event identifier (iCalUID or provider event id), used to dedupe
  /// the same event fetched from multiple sources.
  final String id;

  final String title;

  final String? location;

  /// IANA timezone id (e.g. `Europe/Berlin`) of the zone the event was
  /// defined in, or `null` for floating time. Kept for display and for
  /// rendering all-day events in the correct local day.
  final String? originalTimezoneId;

  /// Conference entry point, exposed by occurrences of this event when the
  /// provider supplied one.
  final MeetingJoinInfo? joinInfo;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CalendarEvent &&
          other.id == id &&
          other.title == title &&
          other.location == location &&
          other.originalTimezoneId == originalTimezoneId &&
          other.joinInfo == joinInfo;

  @override
  int get hashCode =>
      Object.hash(id, title, location, originalTimezoneId, joinInfo);

  @override
  String toString() => 'CalendarEvent(id: $id, title: $title)';
}
