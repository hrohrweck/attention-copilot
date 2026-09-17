/// The Android ringing alert surface: the full-screen content rendered inside
/// `AlertActivity`.
///
/// Design rules (the same acknowledgement gate as the desktop surface):
///   * the view never decides an alert is over — it only reports
///     acknowledgements to its host, which routes them to the engine;
///   * **acknowledgement is the ONLY way a ringing alert stops**: the system
///     back action is consumed via [PopScope] and reported through
///     [onDismissAttempted] so the host can re-raise the activity instead of
///     letting it dismiss;
///   * the Join button renders only when a conference URL exists
///     ([joinInfo]); both buttons map onto the shared
///     [AcknowledgementAction] contract (dismiss | join);
///   * accessibility: both actions expose `Semantics` labels and touch
///     targets of at least 48 dp; the countdown is a coarse live region that
///     only updates at minute boundaries, so it never spams screen readers.
library;

import 'dart:async';

import 'package:attention_copilot/domain/alert_policy.dart';
import 'package:attention_copilot/domain/models/meeting_join_info.dart';
import 'package:flutter/material.dart';

/// Full-screen ringing content for one alert.
///
/// Pure widget: all time is injected ([nowUtc] is authoritative on build and
/// the view ticks forward from it), all side effects (engine acknowledgement,
/// window re-raise) are callbacks. That keeps the acknowledgement gate
/// testable without a device.
class RingingAlertView extends StatefulWidget {
  const RingingAlertView({
    super.key,
    required this.title,
    required this.startUtc,
    required this.nowUtc,
    required this.onAcknowledgement,
    this.joinInfo,
    this.escalationActions = const [],
    this.accent = 'amber',
    this.onDismissAttempted,
  });

  /// Stable keys for the two acknowledgement actions (tests and hosts).
  static const Key dismissKey = ValueKey('ringing_alert_dismiss_button');
  static const Key joinKey = ValueKey('ringing_alert_join_button');

  /// Screen-reader labels for the two actions.
  static const String dismissSemanticsLabel = 'Dismiss alert';
  static const String joinSemanticsLabel = 'Join meeting';

  /// The canonical escalation ladder, weakest first. Used to render the
  /// "still ringing" progress indicator.
  static const List<EscalationAction> escalationLadder = [
    EscalationAction.repeatAudioCycle,
    EscalationAction.raiseVolume,
    EscalationAction.reRaiseWindow,
    EscalationAction.changeAccent,
    EscalationAction.holdWindowAndRemind,
  ];

  /// The meeting title shown prominently.
  final String title;

  /// Absolute UTC start of the meeting.
  final DateTime startUtc;

  /// Absolute UTC "now" injected for testability. The view ticks forward
  /// from this instant internally (once per second, re-rendering only when
  /// the coarse status label changes).
  final DateTime nowUtc;

  /// The single acknowledgement path: called with
  /// [AcknowledgementAction.dismiss] or [AcknowledgementAction.join]. The
  /// host maps this to the engine's `acknowledge` — the only way ringing
  /// stops.
  final void Function(AcknowledgementAction action) onAcknowledgement;

  /// Conference entry point. The Join button renders only when non-null.
  final MeetingJoinInfo? joinInfo;

  /// Escalation actions applied so far (oldest first), driving the visible
  /// "still ringing" indicator.
  final List<EscalationAction> escalationActions;

  /// Current accent token (`amber`, `orange`, `red`) for the alert surface.
  final String accent;

  /// Called when the system back action is consumed instead of dismissing
  /// the alert. The host re-raises the activity from here.
  final VoidCallback? onDismissAttempted;

  /// The coarse user-facing status for the given clock: `starting in N
  /// minutes` (ceil of the remaining time, never 0) or `in progress`.
  static String statusLabelFor(DateTime nowUtc, DateTime startUtc) {
    final difference = startUtc.toUtc().difference(nowUtc.toUtc());
    if (difference <= Duration.zero) return 'in progress';
    final minutes = (difference.inSeconds / 60).ceil();
    return 'starting in $minutes minute${minutes == 1 ? '' : 's'}';
  }

  /// Human-readable label for one escalation action (the "still ringing"
  /// indicator text).
  static String escalationLabelFor(EscalationAction action) =>
      switch (action) {
        EscalationAction.repeatAudioCycle => 'repeating alarm',
        EscalationAction.raiseVolume => 'volume raised',
        EscalationAction.reRaiseWindow => 're-raising window',
        EscalationAction.changeAccent => 'accent intensified',
        EscalationAction.holdWindowAndRemind =>
          'holding with periodic reminder',
      };

  @override
  State<RingingAlertView> createState() => _RingingAlertViewState();
}

class _RingingAlertViewState extends State<RingingAlertView> {
  late DateTime _now;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _now = widget.nowUtc.toUtc();
    _startTicker();
  }

  @override
  void didUpdateWidget(RingingAlertView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.nowUtc != oldWidget.nowUtc) {
      _now = widget.nowUtc.toUtc();
    }
  }

  /// Advances the clock by one second and rebuilds only when the coarse
  /// status label changed (once a minute), so the live region never spams
  /// screen readers and the frame never renders more than once per second.
  void _startTicker() {
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final next = _now.add(const Duration(seconds: 1));
      final before = RingingAlertView.statusLabelFor(_now, widget.startUtc);
      final after = RingingAlertView.statusLabelFor(next, widget.startUtc);
      _now = next;
      if (before != after) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accentColor = _accentColor(widget.accent);
    final status = RingingAlertView.statusLabelFor(_now, widget.startUtc);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        // The back action must never dismiss an unacknowledged alert: report
        // it so the host can re-raise the activity.
        if (!didPop) widget.onDismissAttempted?.call();
      },
      child: Material(
        color: theme.colorScheme.surface,
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.alarm_on, size: 64, color: accentColor),
                  const SizedBox(height: 12),
                  Text(
                    'Meeting alert',
                    style: theme.textTheme.labelLarge?.copyWith(
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Starts at ${_formatStartTime(widget.startUtc.toLocal())}',
                    style: theme.textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 12),
                  Semantics(
                    liveRegion: true,
                    label: status,
                    child: ExcludeSemantics(
                      child: Text(
                        status,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: accentColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _EscalationIndicator(
                    actions: widget.escalationActions,
                    accentColor: accentColor,
                  ),
                  const SizedBox(height: 24),
                  if (widget.joinInfo != null) ...[
                    Semantics(
                      label: RingingAlertView.joinSemanticsLabel,
                      button: true,
                      child: FilledButton.icon(
                        key: RingingAlertView.joinKey,
                        onPressed: () =>
                            widget.onAcknowledgement(AcknowledgementAction.join),
                        icon: const Icon(Icons.videocam),
                        label: const Text('Join'),
                        style: _actionButtonStyle(theme),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  Semantics(
                    label: RingingAlertView.dismissSemanticsLabel,
                    button: true,
                    child: FilledButton(
                      key: RingingAlertView.dismissKey,
                      onPressed: () => widget
                          .onAcknowledgement(AcknowledgementAction.dismiss),
                      style: _actionButtonStyle(theme),
                      child: const Text("I'm on it"),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Large full-width action button: far above the 48 dp minimum touch
  /// target.
  static ButtonStyle _actionButtonStyle(ThemeData theme) =>
      FilledButton.styleFrom(
        minimumSize: const Size(double.infinity, 56),
        textStyle: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.bold,
        ),
      );

  static String _formatStartTime(DateTime local) {
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  static Color _accentColor(String accent) => switch (accent) {
        'red' => Colors.red.shade700,
        'orange' => Colors.deepOrange.shade700,
        _ => Colors.amber.shade700,
      };
}

/// The visible "still ringing" escalation indicator: a status line naming
/// the strongest applied escalation action plus a five-step progress row.
/// Always present while the alert rings.
class _EscalationIndicator extends StatelessWidget {
  const _EscalationIndicator({
    required this.actions,
    required this.accentColor,
  });

  final List<EscalationAction> actions;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final step = _strongestIndex(actions);
    final text = step < 0
        ? 'Still ringing'
        : 'Still ringing — '
            '${RingingAlertView.escalationLabelFor(RingingAlertView.escalationLadder[step])}';
    final semanticsLabel = step < 0
        ? text
        : '$text (escalation step ${step + 1} of '
            '${RingingAlertView.escalationLadder.length})';
    return Semantics(
      label: semanticsLabel,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: accentColor.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: accentColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.max,
          children: [
            Icon(Icons.notifications_active, color: accentColor),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                text,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0;
                    i < RingingAlertView.escalationLadder.length;
                    i++)
                  Container(
                    width: 10,
                    height: 10,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i <= step
                          ? accentColor
                          : theme.colorScheme.outlineVariant,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Index into [RingingAlertView.escalationLadder] of the strongest action
  /// applied so far, or -1 when none.
  static int _strongestIndex(List<EscalationAction> actions) {
    var strongest = -1;
    for (final action in actions) {
      final index = RingingAlertView.escalationLadder.indexOf(action);
      if (index > strongest) strongest = index;
    }
    return strongest;
  }
}
