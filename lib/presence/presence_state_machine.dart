import 'presence_state.dart';

/// Derives [PresenceState]s from raw [PresenceSample]s and suppresses
/// emissions that carry no new information.
///
/// The machine is pure and platform-independent: platform adapters produce
/// samples, this class decides which of them are worth telling consumers
/// about. A new state is emitted only when a field the engine reacts to
/// changes — [PresenceState.locked], [PresenceState.active] (locked OR idle
/// threshold) or the degradation flags — so an idle-threshold crossing emits
/// `active=false` exactly once, no matter how many samples follow while the
/// user keeps being idle. [PresenceState.idleFor] rides along with the
/// freshest value on each emitted transition.
class PresenceStateMachine {
  PresenceStateMachine({required this.idleThreshold, this.mechanism});

  /// Idle duration at or above which the user counts as away (`active=false`).
  final Duration idleThreshold;

  /// Mechanism identifier stamped onto every emitted state (informational).
  final String? mechanism;

  PresenceState? _last;

  /// Returns the new state to emit, or `null` when nothing changed.
  ///
  /// Never throws; all inputs (including nonsensical ones such as negative
  /// idle durations) reduce to a well-defined state.
  PresenceState? onSample(PresenceSample sample) {
    final next = PresenceState(
      locked: sample.locked,
      idleFor: sample.idleFor,
      active: !sample.locked && sample.idleFor < idleThreshold,
      supported: true,
      degraded: sample.degraded,
      degradedReason: sample.degradedReason,
      mechanism: mechanism,
    );
    if (next.equivalentTo(_last)) {
      return null;
    }
    _last = next;
    return next;
  }

  /// Forgets the last emitted state; the next sample re-emits even if it
  /// matches what came before. Used when a service restarts.
  void reset() => _last = null;
}
