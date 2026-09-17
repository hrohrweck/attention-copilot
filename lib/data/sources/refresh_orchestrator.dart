import 'dart:math' as math;

import '../../domain/models/event_occurrence.dart';
import 'registry.dart';
import 'source.dart';

/// Result of one orchestrator refresh: the merged, deduplicated, sorted
/// occurrences plus the per-source status snapshot.
class RefreshResult {
  const RefreshResult({
    required this.occurrences,
    required this.statuses,
    required this.startedAt,
    required this.wasSkipped,
  });

  /// Result of a refresh that was throttled by the minimum-interval gate.
  factory RefreshResult.skipped(DateTime at) => RefreshResult(
        occurrences: const [],
        statuses: const {},
        startedAt: at,
        wasSkipped: true,
      );

  /// Merged occurrences across all enabled sources, sorted by start instant,
  /// then source priority, then occurrence id.
  final List<EventOccurrence> occurrences;

  /// Status of every enabled source after this refresh, keyed by source id.
  final Map<String, SourceStatus> statuses;

  /// Instant the refresh started (null semantics reserved; always set today).
  final DateTime? startedAt;

  /// True when the refresh was throttled and nothing was fetched.
  final bool wasSkipped;
}

/// Fetches every enabled calendar source concurrently, merges the results
/// into one deduplicated occurrence list and records per-source lifecycle
/// state for the UI.
///
/// Guarantees:
///  * a failing source never blanks the agenda - its error is recorded
///    per-source while the other sources' occurrences stay present, and a
///    refresh in which every source fails keeps the last known-good list;
///  * refreshes are throttled to a minimum interval (5 minutes by default,
///    plus a jitter span) so polling can never run in a tight loop;
///  * failed sources back off exponentially (jittered); a source is not
///    fetched again until its backoff window elapses;
///  * the merge is fully deterministic: dedupe keys and winner selection
///    never depend on input or completion order.
///
/// [clock] and [jitter] (returns a value in [0, 1]) are injectable for tests.
class RefreshOrchestrator {
  RefreshOrchestrator({
    required this.registry,
    DateTime Function()? clock,
    double Function()? jitter,
    Map<String, SourceCursor>? initialCursors,
    this.minRefreshInterval = const Duration(minutes: 5),
    this.minIntervalJitterSpan = const Duration(minutes: 1),
    this.initialBackoff = const Duration(seconds: 30),
    this.backoffFactor = 2.0,
    this.maxBackoff = const Duration(minutes: 15),
    this.backoffJitterFraction = 0.25,
  })  : assert(minRefreshInterval >= Duration.zero),
        assert(minIntervalJitterSpan >= Duration.zero),
        assert(initialBackoff >= Duration.zero),
        assert(backoffFactor >= 1.0),
        assert(backoffJitterFraction >= 0.0 && backoffJitterFraction < 1.0),
        _clock = clock ?? DateTime.now,
        _jitter = jitter ?? _randomJitter,
        _cursors = Map<String, SourceCursor>.of(initialCursors ?? const {});

  static double _randomJitter() => math.Random().nextDouble();

  /// The source set to fetch from. [CalendarSourceRegistry.enabledSources] is
  /// snapshotted at the start of each refresh.
  final CalendarSourceRegistry registry;

  /// Minimum time between two non-forced refreshes.
  final Duration minRefreshInterval;

  /// Maximum extra delay added to the interval by jitter.
  final Duration minIntervalJitterSpan;

  /// Backoff after the first consecutive failure of one source.
  final Duration initialBackoff;

  /// Multiplier applied to the backoff per additional failure; a factor of 2
  /// with a jitter fraction below 1 guarantees strictly growing delays.
  final double backoffFactor;

  /// Ceiling for the exponential backoff.
  final Duration maxBackoff;

  /// Backoff jitter: the delay is multiplied by `1 + jitter * fraction`.
  final double backoffJitterFraction;

  final DateTime Function() _clock;
  final double Function() _jitter;
  final Map<String, SourceCursor> _cursors;
  final Map<String, SourceStatus> _statuses = {};
  final Map<String, int> _consecutiveFailures = {};
  final Map<String, DateTime> _retryAllowedAt = {};

  Future<RefreshResult>? _inFlight;
  DateTime? _lastRefreshStartedAt;
  DateTime? _nextRefreshAllowedAt;
  List<EventOccurrence> _latestOccurrences = const [];

  /// The last known-good merged agenda. Never blanked by failures: only a
  /// refresh with at least one successful source replaces it.
  List<EventOccurrence> get latestOccurrences => _latestOccurrences;

  /// The per-source incremental cursors, keyed by source id.
  Map<String, SourceCursor> get cursors => Map.unmodifiable(_cursors);

  /// Instant the last actually-started refresh began, or null.
  DateTime? get lastRefreshStartedAt => _lastRefreshStartedAt;

  /// Earliest instant at which the next non-forced refresh may fetch.
  DateTime? get nextRefreshAllowedAt => _nextRefreshAllowedAt;

  /// Lifecycle status of every source touched so far, keyed by source id.
  Map<String, SourceStatus> get statuses => Map.unmodifiable(_statuses);

  /// Current status of the source with [sourceId]; idle when unknown.
  SourceStatus statusFor(String sourceId) =>
      _statuses[sourceId] ?? const SourceStatus.idle();

  /// Number of consecutive failed fetches of the source with [sourceId].
  int consecutiveFailures(String sourceId) => _consecutiveFailures[sourceId] ?? 0;

  /// Earliest instant at which the source with [sourceId] may be fetched
  /// again, or null when it is not in backoff.
  DateTime? nextRetryAllowedAt(String sourceId) => _retryAllowedAt[sourceId];

  /// Fetches all enabled sources concurrently and merges their occurrences.
  ///
  /// A refresh that is throttled by [minRefreshInterval] returns a skipped
  /// result without fetching; [force] bypasses the interval gate (e.g. for a
  /// user pull-to-refresh). Calls made while a refresh is in flight return
  /// the in-flight future, so a refresh is never started twice concurrently.
  Future<RefreshResult> refresh({bool force = false, DateTime? now}) {
    final inFlight = _inFlight;
    if (inFlight != null) {
      return inFlight;
    }
    final future = _doRefresh(force: force, now: now);
    _inFlight = future;
    return future;
  }

  Future<RefreshResult> _doRefresh({
    required bool force,
    DateTime? now,
  }) async {
    try {
      return await _runRefresh(force: force, now: now);
    } finally {
      _inFlight = null;
    }
  }

  Future<RefreshResult> _runRefresh({
    required bool force,
    DateTime? now,
  }) async {
    final t = (now ?? _clock()).toUtc();
    final sources = registry.enabledSources;
    if (sources.isEmpty) {
      return RefreshResult(
        occurrences: const [],
        statuses: const {},
        startedAt: t,
        wasSkipped: false,
      );
    }

    final gate = _nextRefreshAllowedAt;
    if (!force && gate != null && t.isBefore(gate)) {
      return RefreshResult.skipped(t);
    }

    _lastRefreshStartedAt = t;
    _nextRefreshAllowedAt =
        t.add(minRefreshInterval + (minIntervalJitterSpan * _clampedJitter()));
    for (final source in sources) {
      _statuses.putIfAbsent(source.id, () => const SourceStatus.idle());
    }

    final outcomes = await Future.wait(sources.map((s) => _fetchOne(s, t)));

    final collected = <EventOccurrence>[];
    var anySuccess = false;
    for (final outcome in outcomes) {
      final occurrences = outcome.occurrences;
      if (occurrences != null) {
        collected.addAll(occurrences);
        anySuccess = true;
      }
    }
    final merged = _mergeAndDedupe(collected);
    if (anySuccess) {
      _latestOccurrences = merged;
    }
    return RefreshResult(
      occurrences: merged,
      statuses: Map.unmodifiable({
        for (final source in sources)
          source.id: _statuses[source.id] ?? const SourceStatus.idle(),
      }),
      startedAt: t,
      wasSkipped: false,
    );
  }

  Future<_SourceOutcome> _fetchOne(CalendarSource source, DateTime now) async {
    if (source.permissionState == SourcePermissionState.denied) {
      // Surfaced distinctly, never fetched, never backed off: only the user
      // can fix a denied permission in system settings.
      _statuses[source.id] = const SourceStatus.permissionDenied();
      return const _SourceOutcome.skipped();
    }
    final retryAt = _retryAllowedAt[source.id];
    if (retryAt != null && now.isBefore(retryAt)) {
      // Still in backoff: keep the recorded error status, do not fetch.
      return const _SourceOutcome.skipped();
    }

    _statuses[source.id] = const SourceStatus.refreshing();
    try {
      final snapshot = await source.fetch(_cursors[source.id]);
      final nextCursor = snapshot.nextCursor;
      if (nextCursor != null) {
        _cursors[source.id] = nextCursor;
      }
      _consecutiveFailures.remove(source.id);
      _retryAllowedAt.remove(source.id);
      _statuses[source.id] = const SourceStatus.idle();
      return _SourceOutcome.success(snapshot.occurrences);
    } on SourcePermissionDeniedException {
      _statuses[source.id] = const SourceStatus.permissionDenied();
      return const _SourceOutcome.skipped();
    } catch (error) {
      final failures = _consecutiveFailures[source.id] ?? 0;
      final count = failures + 1;
      _consecutiveFailures[source.id] = count;
      _statuses[source.id] = SourceStatus.error(error.toString());
      _retryAllowedAt[source.id] = now.add(_jitteredBackoff(count));
      return const _SourceOutcome.skipped();
    }
  }

  /// Exponential backoff with multiplicative jitter.
  ///
  /// `delay = min(initialBackoff * factor^(failures-1), maxBackoff)
  ///          * (1 + jitter * backoffJitterFraction)`.
  /// Because the jitter multiplies the base and the base at least doubles per
  /// failure (factor >= 1 + fraction guarantees this for factor 2), delays
  /// grow strictly across consecutive failures of one source.
  Duration _jitteredBackoff(int failures) {
    final base = _backoffBase(failures);
    final factor = 1 + _clampedJitter() * backoffJitterFraction;
    return base * factor;
  }

  Duration _backoffBase(int failures) {
    final scaledMicros =
        initialBackoff.inMicroseconds * math.pow(backoffFactor, failures - 1);
    final clamped =
        math.min(scaledMicros, maxBackoff.inMicroseconds.toDouble());
    return Duration(microseconds: clamped.round());
  }

  double _clampedJitter() {
    final value = _jitter();
    if (value.isNaN) {
      return 0;
    }
    return value.clamp(0.0, 1.0).toDouble();
  }
}

/// Outcome of one per-source fetch: the occurrences on success, nothing on
/// skip/failure.
class _SourceOutcome {
  const _SourceOutcome.skipped() : occurrences = null;

  const _SourceOutcome.success(this.occurrences);

  final List<EventOccurrence>? occurrences;
}

/// Merges and dedupes occurrences across sources, deterministically.
///
/// Dedupe identity: when the master event id is an iCalUID (contains `@`, the
/// RFC 5545 globally-unique convention shared by Google/Outlook/ICS feeds),
/// the key is `uid + start + end` - recurring instances of one event share
/// the UID but never the instant. Otherwise the key is the conservative
/// fallback `normalized title + start + source id`, so occurrences without a
/// cross-source identifier are deduped within one source but never falsely
/// merged across sources.
List<EventOccurrence> _mergeAndDedupe(List<EventOccurrence> occurrences) {
  final best = <String, EventOccurrence>{};
  for (final occurrence in occurrences) {
    final key = _dedupeKey(occurrence);
    final incumbent = best[key];
    if (incumbent == null || _isBetterCandidate(occurrence, incumbent)) {
      best[key] = occurrence;
    }
  }
  final merged = best.values.toList();
  merged.sort(_compareOccurrences);
  return List.unmodifiable(merged);
}

String _dedupeKey(EventOccurrence occurrence) {
  final eventId = occurrence.event.id;
  final start = occurrence.startUtc.toUtc().toIso8601String();
  if (eventId.contains('@')) {
    final end = occurrence.endUtc.toUtc().toIso8601String();
    return 'uid:$eventId|$start|$end';
  }
  final title = _normalizedTitle(occurrence.title);
  return 'fallback:$title|$start|${occurrence.source.id}';
}

String _normalizedTitle(String title) =>
    title.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// Deterministic winner between two occurrences with the same dedupe key:
/// the one with a join URL, else the one from the higher-priority source
/// (lower [priority] number), else the one with the smaller occurrence id.
bool _isBetterCandidate(EventOccurrence candidate, EventOccurrence incumbent) {
  final candidateHasJoin = candidate.joinInfo != null;
  final incumbentHasJoin = incumbent.joinInfo != null;
  if (candidateHasJoin != incumbentHasJoin) {
    return candidateHasJoin;
  }
  final byPriority = candidate.source.priority.compareTo(incumbent.source.priority);
  if (byPriority != 0) {
    return byPriority < 0;
  }
  return candidate.id.compareTo(incumbent.id) < 0;
}

int _compareOccurrences(EventOccurrence a, EventOccurrence b) {
  final byStart = a.startUtc.compareTo(b.startUtc);
  if (byStart != 0) {
    return byStart;
  }
  final byPriority = a.source.priority.compareTo(b.source.priority);
  if (byPriority != 0) {
    return byPriority;
  }
  return a.id.compareTo(b.id);
}
