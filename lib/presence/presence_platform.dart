import 'dart:async';

import 'presence_state.dart';

/// Events a [PresencePlatform] emits on its [PresencePlatform.samples]
/// stream. Either a fresh raw sample or a terminal "no mechanism responds"
/// report.
sealed class PresencePlatformEvent {
  const PresencePlatformEvent();
}

/// A fresh raw presence reading, to be reduced by the state machine.
final class PresenceSampleEvent extends PresencePlatformEvent {
  const PresenceSampleEvent(this.sample);

  final PresenceSample sample;
}

/// The platform's mechanism stopped responding (or never started). Terminal:
/// the service folds this into a single `supported=false` [PresenceState]
/// and ignores any later events.
final class PresenceUnavailableEvent extends PresencePlatformEvent {
  const PresenceUnavailableEvent(this.reason);

  /// Human-readable reason no mechanism responds.
  final String reason;
}

/// Low-level, per-OS presence reader. One implementation per desktop
/// platform (macOS MethodChannel, Windows win32 FFI, Linux D-Bus) plus
/// [UnsupportedPresencePlatform] everywhere else.
///
/// A platform is a dumb sensor: it emits raw [PresenceSampleEvent]s (at most
/// every 2 s — the UI contract forbids faster polling) and, when no
/// mechanism responds at all, a single [PresenceUnavailableEvent]. Deriving
/// user-visible state and de-duplication is the service's job.
abstract interface class PresencePlatform {
  /// Whether a mechanism is implemented for this OS at all. `true` on
  /// macOS/Windows/Linux even if the runtime probe may still fail (in which
  /// case [samples] reports [PresenceUnavailableEvent]).
  bool get supported;

  /// Why [supported] is `false` (set only when it is).
  String? get unsupportedReason;

  /// Short identifier of the mechanism (`logind`, `cgssession`, `win32-wts`).
  String get mechanism;

  /// Raw events. Safe to listen before [start]; events may arrive while the
  /// platform is running only.
  Stream<PresencePlatformEvent> samples();

  /// Starts the underlying mechanism (timers, channels, bus connections).
  /// Idempotent. Must not throw for a missing mechanism — report
  /// [PresenceUnavailableEvent] instead.
  Future<void> start();

  /// Stops the mechanism and releases resources. Idempotent, never throws.
  Future<void> stop();
}

/// Platform for OSes without a presence mechanism (Android, web, ...).
/// Reports `supported=false` with a reason; [start] and [stop] are no-ops
/// and [samples] never emits.
final class UnsupportedPresencePlatform implements PresencePlatform {
  UnsupportedPresencePlatform(this._reason);

  final String _reason;

  @override
  bool get supported => false;

  @override
  String? get unsupportedReason => _reason;

  @override
  String get mechanism => 'unsupported';

  @override
  Stream<PresencePlatformEvent> samples() => const Stream.empty();

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}

/// Builds a [PresencePlatform] reporting [reason] as `supported=false`.
PresencePlatform unsupportedPresencePlatform(String reason) =>
    UnsupportedPresencePlatform(reason);
