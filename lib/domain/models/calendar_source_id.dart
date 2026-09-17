/// Identity of a calendar source (EventKit, CalendarContract, Google REST,
/// ICS/webcal, ...).
///
/// Immutable: all fields are final and the class is a pure value type with
/// structural equality, so occurrences from the same source always compare
/// and hash identically.
class CalendarSourceId {
  const CalendarSourceId({
    required this.id,
    required this.displayName,
    this.priority = 0,
  });

  /// Stable machine identifier, e.g. `eventkit` or `google:<account>`.
  final String id;

  /// Human-readable source name shown in the UI.
  final String displayName;

  /// Deterministic tie-break weight: a lower number wins a tie between
  /// occurrences that start at the same instant (higher priority).
  final int priority;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CalendarSourceId &&
          other.id == id &&
          other.displayName == displayName &&
          other.priority == priority;

  @override
  int get hashCode => Object.hash(id, displayName, priority);

  @override
  String toString() =>
      'CalendarSourceId(id: $id, displayName: $displayName, priority: $priority)';
}
