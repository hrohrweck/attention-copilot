/// Alert policy model: lead times, escalation, acknowledgement and trigger
/// computation for un-ignorable meeting alerts.
///
/// Pure Dart domain code:
///   * no Flutter imports, no I/O, no wall-clock reads — `now` is injected;
///   * only absolute UTC instants are produced ("T-10min" is always resolved
///     to a concrete `DateTime`, never expressed as a relative countdown);
///   * an alert stops only on explicit acknowledgement — this model contains
///     no auto-dismiss timer and never emits one.
library;

/// The audio/visual profile attached to an [AlertLeadTime].
///
/// Escalation can later raise [volume] or change [accent]; the profile only
/// defines the starting state of the alert surface for that lead time.
class AlertProfile {
  const AlertProfile({
    required this.audioId,
    required this.volume,
    required this.accent,
    required this.fullscreen,
    required this.loopAudio,
  });

  /// Identifier of the audio asset/cycle to play (e.g. `chime`, `alarm`).
  final String audioId;

  /// Starting volume in `0.0..1.0`.
  final double volume;

  /// Accent token for the alert surface (e.g. `amber`, `red`).
  final String accent;

  /// Whether the alert surface is full-screen.
  final bool fullscreen;

  /// Whether the audio cycle loops from the start (replay-on-completion is
  /// driven by the engine, this only flags the intent).
  final bool loopAudio;
}

/// One configured lead time: how long before the meeting the alert fires,
/// plus the profile that alert starts with.
class AlertLeadTime {
  const AlertLeadTime(this.before, this.profile);

  /// How far before the meeting start the alert fires.
  final Duration before;

  /// The audio/visual profile for this lead time.
  final AlertProfile profile;

  /// The default heads-up lead time: a gentle chime, no full-screen surface.
  static const tenMinutes = AlertLeadTime(
    Duration(minutes: 10),
    AlertProfile(
      audioId: 'chime',
      volume: 0.6,
      accent: 'amber',
      fullscreen: false,
      loopAudio: false,
    ),
  );

  /// The default urgent lead time: loud, red, full-screen, looping.
  static const oneMinute = AlertLeadTime(
    Duration(minutes: 1),
    AlertProfile(
      audioId: 'alarm',
      volume: 1.0,
      accent: 'red',
      fullscreen: true,
      loopAudio: true,
    ),
  );
}

/// What happens when an alert has been unacknowledged for a given duration.
///
/// Escalation is our own audio/window behaviour — it never touches OS
/// Do-Not-Disturb state (which Android 15 forbids changing, and desktop
/// platforms do not allow bypassing at all).
enum EscalationAction {
  /// Repeat the audio cycle (the step carries the cadence via [EscalationStep.repeatEvery]).
  repeatAudioCycle,

  /// Raise the alert volume by one step.
  raiseVolume,

  /// Re-raise the alert window (bring to front / re-assert always-on-top).
  reRaiseWindow,

  /// Change the accent of the alert surface to the next intensity.
  changeAccent,

  /// Hold the window in its current state and keep emitting a periodic
  /// reminder until the alert is acknowledged.
  holdWindowAndRemind,
}

/// One escalation step: after [after] of being unacknowledged, perform
/// [action] (repeatedly at [repeatEvery] when the action is a repeating one).
class EscalationStep {
  const EscalationStep({
    required this.after,
    required this.action,
    this.repeatEvery,
  });

  /// Unacknowledged duration at which this step activates.
  final Duration after;

  /// The escalation action to perform.
  final EscalationAction action;

  /// Cadence for repeating actions (audio cycles, periodic reminders).
  /// Null for one-shot actions.
  final Duration? repeatEvery;
}

/// The actions a user can take on a ringing acknowledgement surface.
///
/// There is deliberately no auto-dismiss: the alert ends only when the user
/// explicitly acknowledges it.
enum AcknowledgementAction {
  /// Stop the alert.
  dismiss,

  /// Join the meeting (only offered when a conference URL exists).
  join,

  /// Defer the alert (only offered when snooze is enabled in the policy).
  snooze,
}

/// Snooze configuration. Present in the model, but **disabled by default**:
/// the product rule is that an alert stops only on explicit acknowledgement.
class SnoozeConfig {
  const SnoozeConfig({
    required this.enabled,
    this.durations = const [
      Duration(minutes: 1),
      Duration(minutes: 5),
      Duration(minutes: 10),
    ],
  });

  /// Snooze disabled: no snooze action is ever offered.
  static const disabled = SnoozeConfig(enabled: false, durations: []);

  /// Whether the snooze action is offered on the acknowledgement surface.
  final bool enabled;

  /// The snooze durations offered to the user, ascending.
  final List<Duration> durations;
}

/// Minimal view of a meeting occurrence the policy needs.
///
/// Implemented by the domain model (todo 4) and by test doubles. All times
/// are absolute UTC instants.
abstract interface class AlertOccurrence {
  /// Stable identity of this occurrence (unique per event instance).
  String get id;

  /// Absolute UTC start.
  DateTime get startUtc;

  /// Absolute UTC end.
  DateTime get endUtc;

  /// Per-meeting lead-time override; null means "use the policy's list".
  /// A non-null list **replaces** the global list entirely.
  List<AlertLeadTime>? get leadTimesOverride;

  /// Whether a conference URL exists, enabling the `join` acknowledgement.
  bool get hasJoinAction;
}

/// One computed alert trigger: an absolute UTC instant plus a stable alarm id.
class AlertTrigger {
  const AlertTrigger({
    required this.alarmId,
    required this.occurrenceId,
    required this.instant,
    required this.lead,
  });

  /// Stable, deterministic id for the (event, leadTime) pair. Recomputing
  /// the same occurrence with the same lead time always yields the same id,
  /// regardless of `now` or of policy changes — the engine dedupes on this.
  final String alarmId;

  /// The occurrence (event instance) this trigger belongs to.
  final String occurrenceId;

  /// Absolute UTC instant at which the alert must fire.
  final DateTime instant;

  /// The lead-time entry (with profile) this trigger was derived from.
  final AlertLeadTime lead;
}

/// The alert policy: lead times, escalation ladder and snooze state.
class AlertPolicy {
  /// Creates a policy. [leadTimes] and [escalation] are normalised: sorted
  /// ascending (by `before` / `after`) and deduplicated (first entry wins).
  AlertPolicy({
    required List<AlertLeadTime> leadTimes,
    required List<EscalationStep> escalation,
    required this.snooze,
  })  : leadTimes = _normalizedLeadTimes(leadTimes),
        escalation = _normalizedEscalation(escalation);

  /// Defaults: lead times `[10 min, 1 min]`; escalation repeats every 30 s
  /// for up to 5 minutes, then holds the window with a periodic reminder;
  /// snooze **disabled**.
  factory AlertPolicy.defaults() => AlertPolicy(
        leadTimes: const [AlertLeadTime.tenMinutes, AlertLeadTime.oneMinute],
        escalation: defaultEscalation,
        snooze: SnoozeConfig.disabled,
      );

  /// The default escalation ladder (see [EscalationAction]).
  static const defaultEscalation = [
    EscalationStep(
      after: Duration.zero,
      action: EscalationAction.repeatAudioCycle,
      repeatEvery: Duration(seconds: 30),
    ),
    EscalationStep(
      after: Duration(seconds: 30),
      action: EscalationAction.raiseVolume,
    ),
    EscalationStep(
      after: Duration(seconds: 60),
      action: EscalationAction.reRaiseWindow,
    ),
    EscalationStep(
      after: Duration(seconds: 90),
      action: EscalationAction.changeAccent,
    ),
    EscalationStep(
      after: Duration(minutes: 5),
      action: EscalationAction.holdWindowAndRemind,
      repeatEvery: Duration(seconds: 30),
    ),
  ];

  /// Lead times, ascending by [AlertLeadTime.before].
  final List<AlertLeadTime> leadTimes;

  /// Escalation steps, ascending by [EscalationStep.after].
  final List<EscalationStep> escalation;

  /// Snooze configuration (disabled by default).
  final SnoozeConfig snooze;

  /// The acknowledgement actions offered to the user for an alert.
  ///
  /// Always includes [AcknowledgementAction.dismiss]; includes `join` when a
  /// conference URL exists, and `snooze` only when snooze is enabled.
  List<AcknowledgementAction> acknowledgementActions({
    required bool hasJoinAction,
  }) {
    return List.unmodifiable([
      AcknowledgementAction.dismiss,
      if (hasJoinAction) AcknowledgementAction.join,
      if (snooze.enabled) AcknowledgementAction.snooze,
    ]);
  }

  /// The escalation step that is active after [unacknowledgedFor] of the
  /// alert ringing without acknowledgement, or null when no step has
  /// activated yet (impossible with the defaults, which start at zero).
  EscalationStep? escalationStepAt(Duration unacknowledgedFor) {
    EscalationStep? active;
    for (final step in escalation) {
      if (step.after <= unacknowledgedFor) {
        active = step;
      } else {
        break;
      }
    }
    return active;
  }

  static List<AlertLeadTime> _normalizedLeadTimes(List<AlertLeadTime> input) {
    final indexed = <(int, AlertLeadTime)>[
      for (var i = 0; i < input.length; i++) (i, input[i]),
    ];
    indexed.sort((a, b) {
      final byBefore = a.$2.before.compareTo(b.$2.before);
      return byBefore != 0 ? byBefore : a.$1.compareTo(b.$1);
    });
    final out = <AlertLeadTime>[];
    Duration? last;
    for (final (_, lead) in indexed) {
      if (lead.before != last) {
        out.add(lead);
        last = lead.before;
      }
    }
    return List.unmodifiable(out);
  }

  static List<EscalationStep> _normalizedEscalation(List<EscalationStep> input) {
    final indexed = <(int, EscalationStep)>[
      for (var i = 0; i < input.length; i++) (i, input[i]),
    ];
    indexed.sort((a, b) {
      final byAfter = a.$2.after.compareTo(b.$2.after);
      return byAfter != 0 ? byAfter : a.$1.compareTo(b.$1);
    });
    final out = <EscalationStep>[];
    Duration? last;
    for (final (_, step) in indexed) {
      if (step.after != last) {
        out.add(step);
        last = step.after;
      }
    }
    return List.unmodifiable(out);
  }
}

/// Computes the alert triggers for one occurrence under a policy.
///
/// Returns absolute UTC trigger instants, ascending, each with a stable
/// deterministic alarm id. Rules:
///   * a trigger whose instant is already in the past is **not** emitted;
///   * an event that has already ended yields no triggers, and no trigger is
///     ever scheduled past the event's end;
///   * a per-meeting override replaces the policy's lead-time list;
///   * nothing here is relative: every instant is an absolute UTC `DateTime`.
List<AlertTrigger> computeAlertTriggers({
  required AlertOccurrence occurrence,
  required AlertPolicy policy,
  required DateTime now,
}) {
  final nowUtc = now.toUtc();
  final startUtc = occurrence.startUtc.toUtc();
  final endUtc = occurrence.endUtc.toUtc();
  final leads = occurrence.leadTimesOverride ?? policy.leadTimes;

  final triggers = <AlertTrigger>[];
  for (final lead in leads) {
    final instant = startUtc.subtract(lead.before);
    if (instant.isBefore(nowUtc)) {
      continue; // never emit a past trigger
    }
    if (instant.isAfter(endUtc)) {
      continue; // never schedule beyond the event
    }
    triggers.add(AlertTrigger(
      alarmId: alarmIdFor(occurrence.id, lead.before),
      occurrenceId: occurrence.id,
      instant: instant,
      lead: lead,
    ));
  }
  triggers.sort((a, b) => a.instant.compareTo(b.instant));
  return List.unmodifiable(triggers);
}

/// The stable deterministic alarm id for an (event, leadTime) pair.
String alarmIdFor(String occurrenceId, Duration before) {
  return '$occurrenceId#lead${before.inSeconds}';
}
