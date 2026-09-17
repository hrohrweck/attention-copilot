import '../../domain/models/calendar_source_id.dart';
import '../../domain/models/event_occurrence.dart';

/// Opaque incremental-sync cursor for a single calendar source.
///
/// The abstraction never interprets the wrapped value: a Google source may
/// carry a sync token, an ICS source an ETag/Last-Modified pair (see
/// `AgendaSourceCursor` in `lib/data/storage/`). The orchestrator only stores
/// what a snapshot returns and hands it back on the next fetch.
class SourceCursor {
  const SourceCursor(this.value);

  /// Provider-specific cursor payload, `null` for a first/full fetch.
  final Object? value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is SourceCursor && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'SourceCursor($value)';
}

/// Result of one [CalendarSource.fetch] call.
class SourceSnapshot {
  const SourceSnapshot({required this.occurrences, this.nextCursor});

  /// Occurrences of this source for the current agenda window. May contain
  /// internal duplicates (e.g. overlapping fetch pages); the orchestrator
  /// dedupes before merging.
  final List<EventOccurrence> occurrences;

  /// Cursor to use for the next incremental fetch, or `null` when the source
  /// has no incremental state to return.
  final SourceCursor? nextCursor;
}

/// Coarse lifecycle state of one calendar source, for the UI status line.
enum SourceStatusKind {
  /// Never fetched or last fetch succeeded.
  idle,

  /// A fetch is currently in flight.
  refreshing,

  /// The last fetch failed; [SourceStatus.reason] carries the cause.
  error,

  /// The user denied calendar access for this source. Distinct from [error]
  /// so the UI can offer the "open settings" action instead of a retry.
  permissionDenied,
}

/// Lifecycle state of a calendar source ([SourceStatusKind]) plus the reason
/// of the failure when in [SourceStatusKind.error].
///
/// Immutable value type with structural equality.
class SourceStatus {
  const SourceStatus._(this.kind, this.reason);

  const SourceStatus.idle() : this._(SourceStatusKind.idle, null);

  const SourceStatus.refreshing() : this._(SourceStatusKind.refreshing, null);

  /// Machine-readable-ish reason of the failure, e.g. the exception text.
  const SourceStatus.error(String reason)
      : this._(SourceStatusKind.error, reason);

  const SourceStatus.permissionDenied([String? reason])
      : this._(SourceStatusKind.permissionDenied, reason);

  final SourceStatusKind kind;

  final String? reason;

  bool get isIdle => kind == SourceStatusKind.idle;
  bool get isRefreshing => kind == SourceStatusKind.refreshing;
  bool get isError => kind == SourceStatusKind.error;
  bool get isPermissionDenied => kind == SourceStatusKind.permissionDenied;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SourceStatus &&
          other.kind == kind &&
          other.reason == reason;

  @override
  int get hashCode => Object.hash(kind, reason);

  @override
  String toString() {
    final name = switch (kind) {
      SourceStatusKind.idle => 'idle',
      SourceStatusKind.refreshing => 'refreshing',
      SourceStatusKind.error => 'error',
      SourceStatusKind.permissionDenied => 'permissionDenied',
    };
    return reason == null ? 'SourceStatus.$name' : 'SourceStatus.$name($reason)';
  }
}

/// Platform permission posture of a calendar source, evaluated before a fetch
/// is attempted so a denied source is surfaced without pointless work.
enum SourcePermissionState {
  /// The source needs no permission (e.g. a public ICS feed).
  notRequired,

  /// Permission has been granted.
  granted,

  /// Permission was requested and denied; the UI must direct the user to
  /// system settings. The orchestrator records `permission-denied` and never
  /// calls [CalendarSource.fetch].
  denied,
}

/// Thrown by [CalendarSource.fetch] when permission is (or was) missing at
/// fetch time. The orchestrator maps it to `permission-denied`, never to a
/// generic error, and applies no backoff.
class SourcePermissionDeniedException implements Exception {
  const SourcePermissionDeniedException([this.message]);

  final String? message;

  @override
  String toString() =>
      'SourcePermissionDeniedException(${message ?? 'permission denied'})';
}

/// A read-only calendar data provider (EventKit, CalendarContract, Google
/// REST, ICS/webcal, ...).
///
/// Implementations are stateless with respect to sync state: they receive the
/// last [SourceCursor] and return the next one inside [SourceSnapshot]. All
/// scheduling, retry and status concerns live in the refresh orchestrator.
abstract class CalendarSource {
  /// Stable identity of this source; also the map key in the registry, the
  /// status map and the agenda cache.
  CalendarSourceId get sourceId;

  /// Stable machine identifier, e.g. `eventkit` or `google:<account>`.
  String get id => sourceId.id;

  /// Human-readable name shown in the UI.
  String get displayName => sourceId.displayName;

  /// Deterministic tie-break weight (lower wins) from the source identity.
  int get priority => sourceId.priority;

  /// Capability flag: every source in this app is read-only. Provider data is
  /// never mutated.
  bool get isReadOnly => true;

  /// Capability flag: whether the source requires interactive authentication
  /// (e.g. Google OAuth) before it can fetch. The wizard uses this to decide
  /// which setup steps to show.
  bool get needsAuthentication => false;

  /// Current permission posture. The orchestrator consults this before every
  /// fetch and records `permission-denied` without calling [fetch] when it is
  /// [SourcePermissionState.denied].
  SourcePermissionState get permissionState => SourcePermissionState.notRequired;

  /// Fetches the occurrences for the current agenda window.
  ///
  /// [cursor] is the last cursor this source returned, or `null` on the first
  /// fetch. A successful snapshot carries the cursor for the next fetch; a
  /// thrown [SourcePermissionDeniedException] reports a denied permission;
  /// any other throw is recorded as a per-source error by the orchestrator.
  Future<SourceSnapshot> fetch(SourceCursor? cursor);
}
