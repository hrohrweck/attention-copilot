import 'dart:async';

import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;

import '../data/sources/source.dart';
import '../domain/agenda.dart';
import '../domain/models/agenda_day.dart';
import '../domain/models/event_occurrence.dart';

/// Why the agenda is empty, so the UI can tell the user exactly what is
/// wrong instead of showing a bare screen.
enum AgendaEmptyReason {
  /// There is something to render.
  none,

  /// No calendar source is enabled.
  noSourcesEnabled,

  /// Sources are enabled and healthy but nothing overlaps the visible
  /// window (today plus the look-ahead).
  noEventsToday,

  /// Sources are enabled, every fetch failed and there is nothing to show.
  sourceError,
}

/// The today-first agenda: today's appointments in chronological order, the
/// next meeting in a visually dominant card with a live countdown, all-day
/// events in a separate strip and a bounded look-ahead beyond today.
///
/// This widget is presentation-only: it renders the [occurrences] and
/// [statuses] it is given and re-requests data through [onRefresh] (the
/// composition root, not this widget, owns the orchestrator and rebuilds the
/// screen with fresh values after a refresh completes).
///
/// Time is always injected: [clock] supplies the absolute UTC "now" and
/// [timezone] the user's IANA zone, so the countdown and the today window
/// are deterministic in tests.
class AgendaScreen extends StatefulWidget {
  const AgendaScreen({
    super.key,
    required this.occurrences,
    required this.statuses,
    required this.sourceDisplayNames,
    required this.anySourcesEnabled,
    required this.lastRefreshedAt,
    required this.onRefresh,
    required this.clock,
    required this.timezone,
    required this.onJoinMeeting,
    this.lookAhead = const Duration(hours: 24),
  });

  /// Merged occurrences across all sources (the orchestrator's
  /// last-known-good list).
  final List<EventOccurrence> occurrences;

  /// Per-source lifecycle state, keyed by source id.
  final Map<String, SourceStatus> statuses;

  /// Human-readable name per source id, for status and error lines.
  final Map<String, String> sourceDisplayNames;

  /// Whether at least one calendar source is enabled.
  final bool anySourcesEnabled;

  /// Instant the last refresh started, in UTC, or null when nothing was
  /// ever fetched.
  final DateTime? lastRefreshedAt;

  /// Called by pull-to-refresh and the manual refresh action. The caller
  /// triggers a fetch and rebuilds this widget with fresh values.
  final Future<void> Function() onRefresh;

  /// Injected "now" (absolute UTC). Never the machine clock.
  final DateTime Function() clock;

  /// The user's IANA timezone; defines what "today" means.
  final tz.Location timezone;

  /// Opens the conference URL of a meeting's Join action.
  final void Function(String url) onJoinMeeting;

  /// How far beyond the end of today upcoming meetings are listed
  /// (bounded window; never an unbounded list).
  final Duration lookAhead;

  @override
  State<AgendaScreen> createState() => _AgendaScreenState();
}

class _AgendaScreenState extends State<AgendaScreen> {
  Timer? _ticker;
  late DateTime _now;

  @override
  void initState() {
    super.initState();
    _now = widget.clock().toUtc();
    _syncTicker();
  }

  @override
  void didUpdateWidget(AgendaScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// Runs the countdown ticker only while a next meeting exists, so idle
  /// screens never repaint and the countdown re-renders at most once per
  /// second.
  void _syncTicker() {
    final hasNext = selectNextMeeting(widget.occurrences, _now) != null;
    if (hasNext && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    } else if (!hasNext && _ticker != null) {
      _ticker!.cancel();
      _ticker = null;
    }
  }

  void _tick() {
    final now = widget.clock().toUtc();
    if (now.isAtSameMomentAs(_now)) {
      return; // The injected clock did not advance; nothing to repaint.
    }
    setState(() {
      _now = now;
      _syncTicker();
    });
  }

  /// Timed, non-all-day occurrences starting after the end of today and
  /// before `now + lookAhead` — the bounded look-ahead window.
  List<EventOccurrence> _lookAhead(AgendaDay today, DateTime now) {
    final windowEnd = now.add(widget.lookAhead);
    return sortOccurrences(
      widget.occurrences
          .where((occurrence) =>
              !occurrence.isAllDay &&
              !occurrence.startUtc.isBefore(today.dayEndUtc) &&
              occurrence.startUtc.isBefore(windowEnd))
          .toList(),
    );
  }

  List<MapEntry<String, SourceStatus>> _erroringSources() => widget.statuses
      .entries
      .where((entry) =>
          entry.value.isError || entry.value.isPermissionDenied)
      .toList();

  String _sourceName(String id) => widget.sourceDisplayNames[id] ?? id;

  @override
  Widget build(BuildContext context) {
    final now = _now;
    final today = buildTodayAgenda(widget.occurrences, now, widget.timezone);
    final next = selectNextMeeting(widget.occurrences, now);
    // The dominant card already presents the next meeting; the flat lists
    // below show every other occurrence exactly once.
    final todayRows = <EventOccurrence>[
      for (final occurrence in today.timedOccurrences)
        if (occurrence.id != next?.id) occurrence,
    ];
    final lookAheadRows = <EventOccurrence>[
      for (final occurrence in _lookAhead(today, now))
        if (occurrence.id != next?.id) occurrence,
    ];
    final errors = _erroringSources();
    final hasItems = next != null ||
        today.allDayOccurrences.isNotEmpty ||
        todayRows.isNotEmpty ||
        lookAheadRows.isNotEmpty;
    final reason = _emptyReason(hasItems: hasItems, errors: errors);

    return Scaffold(
      appBar: AppBar(
        title: Text('Today · ${_dateLabel(now, widget.timezone)}'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: widget.onRefresh,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: widget.onRefresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 24),
          children: <Widget>[
            if (reason != AgendaEmptyReason.none)
              _buildEmptyState(context, reason, errors)
            else ...<Widget>[
              if (errors.isNotEmpty)
                _SourceErrorBanner(
                  errors: errors,
                  names: widget.sourceDisplayNames,
                ),
              if (next != null)
                _NextMeetingCard(
                  occurrence: next,
                  now: now,
                  timezone: widget.timezone,
                  onJoin: widget.onJoinMeeting,
                ),
              if (today.allDayOccurrences.isNotEmpty)
                _AllDayStrip(occurrences: today.allDayOccurrences),
              for (final occurrence in todayRows)
                _AgendaRow(
                  key: ValueKey('agenda-row-${occurrence.id}'),
                  occurrence: occurrence,
                  now: now,
                  timezone: widget.timezone,
                ),
              if (lookAheadRows.isNotEmpty) ...<Widget>[
                const _SectionHeader(
                  key: ValueKey('later-section'),
                  title: 'Later',
                ),
                for (final occurrence in lookAheadRows)
                  _AgendaRow(
                    key: ValueKey('agenda-row-${occurrence.id}'),
                    occurrence: occurrence,
                    now: now,
                    timezone: widget.timezone,
                  ),
              ],
            ],
            _StatusFooter(lastRefreshedAt: widget.lastRefreshedAt, now: now),
          ],
        ),
      ),
    );
  }

  AgendaEmptyReason _emptyReason({
    required bool hasItems,
    required List<MapEntry<String, SourceStatus>> errors,
  }) {
    if (!widget.anySourcesEnabled) {
      return AgendaEmptyReason.noSourcesEnabled;
    }
    if (hasItems) {
      return AgendaEmptyReason.none;
    }
    return errors.isEmpty
        ? AgendaEmptyReason.noEventsToday
        : AgendaEmptyReason.sourceError;
  }

  Widget _buildEmptyState(
    BuildContext context,
    AgendaEmptyReason reason,
    List<MapEntry<String, SourceStatus>> errors,
  ) {
    switch (reason) {
      case AgendaEmptyReason.noSourcesEnabled:
        return const _EmptyState(
          key: ValueKey('empty-noSourcesEnabled'),
          icon: Icons.calendar_today_outlined,
          title: 'No calendars enabled',
          message: 'Enable a calendar source to see your agenda for today.',
        );
      case AgendaEmptyReason.noEventsToday:
        return const _EmptyState(
          key: ValueKey('empty-noEventsToday'),
          icon: Icons.event_available_outlined,
          title: 'Nothing on the agenda today',
          message: 'Enjoy the quiet — new meetings will appear here.',
        );
      case AgendaEmptyReason.sourceError:
        return _EmptyState(
          key: const ValueKey('empty-sourceError'),
          icon: Icons.error_outline,
          title: "Couldn't load your agenda",
          message: 'Something went wrong while refreshing your calendars:',
          details: <String>[
            for (final entry in errors)
              '${_sourceName(entry.key)}: ${_sourceErrorReason(entry.value)}',
          ],
        );
      case AgendaEmptyReason.none:
        return const SizedBox.shrink();
    }
  }
}

/// The dominant presentation of the next meeting: title, live countdown,
/// time range, calendar name, location and the Join action.
class _NextMeetingCard extends StatelessWidget {
  const _NextMeetingCard({
    required this.occurrence,
    required this.now,
    required this.timezone,
    required this.onJoin,
  });

  final EventOccurrence occurrence;
  final DateTime now;
  final tz.Location timezone;
  final void Function(String url) onJoin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final inProgress = occurrence.startUtc.isBefore(now);
    final remaining = occurrence.startUtc.difference(now);
    final join = occurrence.joinInfo;

    return Card(
      key: const ValueKey('next-meeting-card'),
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      color: scheme.primaryContainer,
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    occurrence.title,
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: scheme.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (inProgress) const _InProgressBadge(),
              ],
            ),
            const SizedBox(height: 12),
            if (!inProgress)
              Semantics(
                label: _countdownSemanticsLabel(remaining),
                child: ExcludeSemantics(
                  child: Text(
                    _formatCountdown(remaining),
                    key: const ValueKey('next-meeting-countdown'),
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: scheme.onPrimaryContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Text(
              '${_formatTime(occurrence.startUtc, timezone)} – '
              '${_formatTime(occurrence.endUtc, timezone)}',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              occurrence.source.displayName,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onPrimaryContainer.withValues(alpha: 0.8),
              ),
            ),
            if (occurrence.location != null) ...<Widget>[
              const SizedBox(height: 2),
              Row(
                children: <Widget>[
                  Icon(
                    Icons.place_outlined,
                    size: 14,
                    color: scheme.onPrimaryContainer.withValues(alpha: 0.8),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      occurrence.location!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onPrimaryContainer.withValues(alpha: 0.8),
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (join != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: FilledButton.icon(
                  onPressed: () => onJoin(join.url),
                  icon: const Icon(Icons.videocam_outlined),
                  label: const Text('Join'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _InProgressBadge extends StatelessWidget {
  const _InProgressBadge();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('in-progress-badge'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        'In progress',
        style: TextStyle(
          color: scheme.onTertiaryContainer,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Today's all-day events, rendered as a horizontal chip strip that is
/// structurally separate from the timed list.
class _AllDayStrip extends StatelessWidget {
  const _AllDayStrip({required this.occurrences});

  final List<EventOccurrence> occurrences;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      key: const ValueKey('all-day-strip'),
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Text(
              'All day',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.outline,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final occurrence in occurrences)
                Chip(
                  key: ValueKey('all-day-chip-${occurrence.id}'),
                  label: Text(occurrence.title),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One timed occurrence row. Past meetings are muted so the focus stays on
/// what is next.
class _AgendaRow extends StatelessWidget {
  const _AgendaRow({
    super.key,
    required this.occurrence,
    required this.now,
    required this.timezone,
  });

  final EventOccurrence occurrence;
  final DateTime now;
  final tz.Location timezone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isPast = !occurrence.endUtc.isAfter(now);

    Widget row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 96,
            child: Text(
              '${_formatTime(occurrence.startUtc, timezone)} – '
              '${_formatTime(occurrence.endUtc, timezone)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  occurrence.title,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  occurrence.source.displayName,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (isPast) {
      row = Opacity(opacity: 0.55, child: row);
    }
    return row;
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.outline,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Prominent, always-visible explanation of which sources failed and why.
/// Never hides the healthy sources' events: it is shown alongside the list.
class _SourceErrorBanner extends StatelessWidget {
  const _SourceErrorBanner({required this.errors, required this.names});

  final List<MapEntry<String, SourceStatus>> errors;
  final Map<String, String> names;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('source-error-banner'),
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                Icons.sync_problem,
                size: 18,
                color: scheme.onErrorContainer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  "Couldn't refresh every calendar",
                  style: TextStyle(
                    color: scheme.onErrorContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (final entry in errors)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '${names[entry.key] ?? entry.key}: '
                '${_sourceErrorReason(entry.value)}',
                style: TextStyle(
                  color: scheme.onErrorContainer,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The source-status line: when the agenda was last refreshed.
class _StatusFooter extends StatelessWidget {
  const _StatusFooter({required this.lastRefreshedAt, required this.now});

  final DateTime? lastRefreshedAt;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      key: const ValueKey('agenda-status-footer'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.schedule,
            size: 14,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(width: 6),
          Text(
            _updatedLabel(lastRefreshedAt, now),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.details = const <String>[],
  });

  final IconData icon;
  final String title;
  final String message;
  final List<String> details;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 64, 24, 16),
      child: Column(
        children: <Widget>[
          Icon(icon, size: 48, color: scheme.outline),
          const SizedBox(height: 16),
          Text(
            title,
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            message,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          if (details.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            for (final detail in details)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  detail,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.error,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Formatting helpers (all pure, deterministic, timezone-explicit).
// ---------------------------------------------------------------------------

/// Human countdown label, e.g. `1h 30m`, `5m 00s`, `45s`, `Starting now`.
String _formatCountdown(Duration remaining) {
  if (remaining.isNegative || remaining.inSeconds == 0) {
    return 'Starting now';
  }
  if (remaining.inDays >= 1) {
    return '${remaining.inDays}d ${remaining.inHours % 24}h';
  }
  if (remaining.inHours >= 1) {
    return '${remaining.inHours}h '
        '${(remaining.inMinutes % 60).toString().padLeft(2, '0')}m';
  }
  if (remaining.inMinutes >= 1) {
    return '${remaining.inMinutes}m '
        '${(remaining.inSeconds % 60).toString().padLeft(2, '0')}s';
  }
  return '${remaining.inSeconds}s';
}

/// Coarse accessibility label so the per-second countdown never becomes a
/// live region that spams screen readers.
String _countdownSemanticsLabel(Duration remaining) {
  if (remaining.inSeconds <= 60) {
    return 'starts in less than a minute';
  }
  if (remaining.inHours < 1) {
    return 'starts in about ${remaining.inMinutes} minutes';
  }
  if (remaining.inDays < 1) {
    return 'starts in about ${remaining.inHours} hours';
  }
  return 'starts in about ${remaining.inDays} days';
}

String _sourceErrorReason(SourceStatus status) {
  final reason = status.reason;
  if (reason != null) {
    return reason;
  }
  return status.isPermissionDenied
      ? 'calendar access denied'
      : 'failed to refresh';
}

String _updatedLabel(DateTime? lastRefreshedAt, DateTime now) {
  if (lastRefreshedAt == null) {
    return 'Not refreshed yet';
  }
  final elapsed = now.difference(lastRefreshedAt.toUtc());
  if (elapsed.isNegative || elapsed.inSeconds < 5) {
    return 'Updated just now';
  }
  if (elapsed.inMinutes < 1) {
    return 'Updated ${elapsed.inSeconds}s ago';
  }
  if (elapsed.inHours < 1) {
    return 'Updated ${elapsed.inMinutes}m ago';
  }
  if (elapsed.inDays < 1) {
    return 'Updated ${elapsed.inHours}h ago';
  }
  return 'Updated ${elapsed.inDays}d ago';
}

String _formatTime(DateTime utcInstant, tz.Location timezone) {
  final local = tz.TZDateTime.from(utcInstant, timezone);
  return '${_two(local.hour)}:${_two(local.minute)}';
}

String _dateLabel(DateTime now, tz.Location timezone) {
  const weekdays = <String>['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = <String>[
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final local = tz.TZDateTime.from(now, timezone);
  return '${weekdays[local.weekday - 1]} ${local.day} '
      '${months[local.month - 1]}';
}

String _two(int value) => value.toString().padLeft(2, '0');
