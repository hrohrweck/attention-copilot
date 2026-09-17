import 'event_occurrence.dart';

/// One local calendar day, as seen by a user in a specific timezone.
///
/// The window `[dayStartUtc, dayEndUtc)` is the user's local midnight to the
/// next local midnight, stored as absolute UTC instants, so a DST-transition
/// day naturally spans 23 or 25 hours.
///
/// Immutable: all fields are final and the lists are unmodifiable.
class AgendaDay {
  const AgendaDay({
    required this.dayStartUtc,
    required this.dayEndUtc,
    this.allDayOccurrences = const [],
    this.timedOccurrences = const [],
  });

  /// Absolute UTC instant of the user's local midnight, inclusive.
  final DateTime dayStartUtc;

  /// Absolute UTC instant of the next local midnight, exclusive.
  final DateTime dayEndUtc;

  /// All-day occurrences overlapping this day, sorted by [EventOccurrence.startUtc].
  final List<EventOccurrence> allDayOccurrences;

  /// Timed occurrences overlapping this day, sorted by [EventOccurrence.startUtc].
  final List<EventOccurrence> timedOccurrences;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgendaDay &&
          other.dayStartUtc == dayStartUtc &&
          other.dayEndUtc == dayEndUtc &&
          _listEquals(other.allDayOccurrences, allDayOccurrences) &&
          _listEquals(other.timedOccurrences, timedOccurrences);

  @override
  int get hashCode =>
      Object.hash(dayStartUtc, dayEndUtc, Object.hashAll(allDayOccurrences),
          Object.hashAll(timedOccurrences));

  @override
  String toString() =>
      'AgendaDay(dayStartUtc: $dayStartUtc, dayEndUtc: $dayEndUtc, '
      'allDay: ${allDayOccurrences.length}, timed: ${timedOccurrences.length})';

  static bool _listEquals(List<EventOccurrence> a, List<EventOccurrence> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
