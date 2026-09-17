import 'package:flutter/foundation.dart';

/// The derived, user-visible presence of the person at the machine:
/// `{locked, idleFor, active}` plus capability flags.
///
/// Immutable value type with structural equality. Consumers that gate
/// behaviour on [active] MUST check [supported] first: an unsupported
/// platform cannot know whether the user is present, and its [active] value
/// carries no meaning.
@immutable
class PresenceState {
  const PresenceState({
    required this.locked,
    required this.idleFor,
    required this.active,
    this.supported = true,
    this.unsupportedReason,
    this.degraded = false,
    this.degradedReason,
    this.mechanism,
  });

  /// Reports a platform on which no presence mechanism responds. Never
  /// thrown; this is the state an unsupported platform degrades to.
  const PresenceState.unsupported({
    required String reason,
    this.mechanism,
  })  : locked = false,
        idleFor = Duration.zero,
        active = false,
        supported = false,
        unsupportedReason = reason,
        degraded = false,
        degradedReason = null;

  /// Whether the screen is locked (or the session otherwise hidden).
  final bool locked;

  /// How long the user has been idle (no input), as reported by the OS.
  final Duration idleFor;

  /// Whether the user counts as present: unlocked AND idle below the
  /// configured threshold.
  final bool active;

  /// Whether a presence mechanism responded on this platform. When `false`,
  /// [unsupportedReason] explains why and [locked]/[idleFor]/[active] are
  /// meaningless.
  final bool supported;

  /// Human-readable reason for `supported == false`, `null` otherwise.
  final String? unsupportedReason;

  /// Whether the mechanism responded but with reduced capability (e.g. the
  /// macOS screen-lock key was absent so a fallback signal is used).
  final bool degraded;

  /// Human-readable explanation for [degraded], `null` when not degraded.
  final String? degradedReason;

  /// Short identifier of the underlying mechanism
  /// (`logind`, `gnome-idle-monitor`, `kde-screensaver`, `cgssession`,
  /// `win32-wts`, `fake`, ...). Informational only.
  final String? mechanism;

  /// Whether two states differ only in fields a consumer reacts to.
  ///
  /// [idleFor] is deliberately excluded: idle time grows monotonically and
  /// would make every sample "different", defeating the state machine's
  /// change detection. Transitions carry the freshest [idleFor]; between
  /// transitions the last reported value stands.
  bool equivalentTo(PresenceState? other) =>
      other != null &&
      other.locked == locked &&
      other.active == active &&
      other.supported == supported &&
      other.degraded == degraded &&
      other.degradedReason == degradedReason;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PresenceState &&
          other.locked == locked &&
          other.idleFor == idleFor &&
          other.active == active &&
          other.supported == supported &&
          other.unsupportedReason == unsupportedReason &&
          other.degraded == degraded &&
          other.degradedReason == degradedReason &&
          other.mechanism == mechanism;

  @override
  int get hashCode => Object.hash(
        locked,
        idleFor,
        active,
        supported,
        unsupportedReason,
        degraded,
        degradedReason,
        mechanism,
      );

  @override
  String toString() =>
      'PresenceState(locked: $locked, idleFor: $idleFor, active: $active, '
      'supported: $supported'
      '${unsupportedReason == null ? '' : ', unsupportedReason: $unsupportedReason'}'
      '${degraded ? ', degraded' : ''}'
      '${mechanism == null ? '' : ', mechanism: $mechanism'})';
}

/// Raw, un-derived presence input reported by a platform mechanism.
///
/// Fed into [PresenceStateMachine.onSample], which derives the user-visible
/// [PresenceState] (computing `active` from the configured idle threshold)
/// and suppresses no-change emissions.
@immutable
class PresenceSample {
  const PresenceSample({
    required this.locked,
    required this.idleFor,
    this.degraded = false,
    this.degradedReason,
  });

  final bool locked;

  final Duration idleFor;

  /// Whether the mechanism that produced this sample is working with reduced
  /// capability.
  final bool degraded;

  /// Human-readable explanation for [degraded].
  final String? degradedReason;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PresenceSample &&
          other.locked == locked &&
          other.idleFor == idleFor &&
          other.degraded == degraded &&
          other.degradedReason == degradedReason;

  @override
  int get hashCode =>
      Object.hash(locked, idleFor, degraded, degradedReason);

  @override
  String toString() =>
      'PresenceSample(locked: $locked, idleFor: $idleFor'
      '${degraded ? ', degraded' : ''})';
}
