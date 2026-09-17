import 'package:attention_copilot/data/sources/source.dart';
import 'package:attention_copilot/domain/models/calendar_event.dart';
import 'package:attention_copilot/domain/models/calendar_source_id.dart';
import 'package:attention_copilot/domain/models/event_occurrence.dart';
import 'package:attention_copilot/domain/models/meeting_join_info.dart';

/// Test-only [CalendarSource] with fully scriptable behaviour: a fixed list of
/// occurrences, an optional next cursor, an optional error to throw, an
/// optional permission state and a log of every cursor it received.
class FakeCalendarSource extends CalendarSource {
  FakeCalendarSource({
    required String id,
    String? displayName,
    int priority = 0,
    this.permission = SourcePermissionState.notRequired,
  }) : sourceId = CalendarSourceId(
          id: id,
          displayName: displayName ?? id,
          priority: priority,
        );

  @override
  final CalendarSourceId sourceId;

  /// Permission posture reported by [permissionState].
  final SourcePermissionState permission;

  @override
  SourcePermissionState get permissionState => permission;

  /// Occurrences returned by [fetch].
  List<EventOccurrence> occurrences = const [];

  /// Cursor handed back in every snapshot, or null when the source has no
  /// incremental state to return.
  SourceCursor? nextCursor;

  /// When non-null, [fetch] throws this object.
  Exception? thrownError;

  /// When true, [fetch] throws [SourcePermissionDeniedException].
  bool throwPermissionDenied = false;

  /// Every cursor value passed into [fetch], in call order.
  final List<SourceCursor?> receivedCursors = [];

  /// Number of [fetch] invocations.
  int fetchCount = 0;

  @override
  Future<SourceSnapshot> fetch(SourceCursor? cursor) async {
    fetchCount++;
    receivedCursors.add(cursor);
    if (throwPermissionDenied) {
      throw const SourcePermissionDeniedException('user denied access');
    }
    final error = thrownError;
    if (error != null) {
      throw error;
    }
    return SourceSnapshot(
      occurrences: List.of(occurrences),
      nextCursor: nextCursor,
    );
  }
}

/// Builds a single [EventOccurrence] with controlled identity fields.
///
/// [eventId] becomes the master event id; [instanceSuffix] disambiguates
/// occurrence ids so the deterministic merge tie-breaks are observable.
EventOccurrence occurrence({
  required String sourceId,
  required String eventId,
  String title = 'Meeting',
  DateTime? startUtc,
  DateTime? endUtc,
  MeetingJoinInfo? joinInfo,
  String instanceSuffix = '',
}) {
  final start = startUtc ?? DateTime.utc(2026, 9, 18, 9);
  final end = endUtc ?? start.add(const Duration(hours: 1));
  return EventOccurrence(
    id: '$eventId$instanceSuffix',
    event: CalendarEvent(id: eventId, title: title, joinInfo: joinInfo),
    source: CalendarSourceId(id: sourceId, displayName: sourceId),
    startUtc: start,
    endUtc: end,
  );
}

/// Manually advanced clock for orchestrator tests. Callable as a `DateTime
/// Function()` so it can be injected where the orchestrator reads "now".
class TestClock {
  TestClock([DateTime? start])
      : current = (start ?? DateTime.utc(2026, 9, 18, 8)).toUtc();

  DateTime current;

  DateTime call() => current;
}
