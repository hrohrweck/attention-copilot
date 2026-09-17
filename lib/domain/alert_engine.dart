/// The alert engine: turns the alert policy into fired, deferred, persisted,
/// acknowledgement-gated alerts.
///
/// Pure Dart domain code:
///   * no Flutter imports, no I/O, no wall-clock reads — `now` is injected;
///   * only absolute UTC instants are used;
///   * an alert stops only on explicit acknowledgement — this engine contains
///     no auto-dismiss timer and never emits one.
library;

import 'dart:async';

import 'alert_policy.dart';

/// The machine/user presence the engine currently assumes.
enum EnginePresence { active, locked, away }

/// Lifecycle state of one trigger inside the engine's persisted pending set.
enum PendingTriggerState { pending, deferredLocked, deferredAway, ringing }

/// Why a departure was appended to the engine's record log.
enum AlertRecordReason {
  fired,
  deferredLocked,
  deferredAway,
  meetingEnded,
  occurrenceRemoved,
  acknowledged,
}

/// One persisted pending trigger: the smallest unit the engine tracks and
/// survives restarts with. Immutable; `copyWith` produces the next state.
class PendingTriggerRecord {
  const PendingTriggerRecord({
    required this.alarmId,
    required this.occurrenceId,
    required this.instantUtc,
    required this.endUtc,
    required this.lead,
    required this.state,
  });

  /// Stable deterministic id for the (event, leadTime) pair.
  final String alarmId;

  /// The occurrence (event instance) this trigger belongs to.
  final String occurrenceId;

  /// Absolute UTC instant at which the alert must fire.
  final DateTime instantUtc;

  /// Absolute UTC end of the meeting, exclusive (drives the ended-grace rule).
  final DateTime endUtc;

  /// The lead-time entry (with profile) this trigger was derived from.
  final AlertLeadTime lead;

  /// Current lifecycle state.
  final PendingTriggerState state;

  /// The [AlertTrigger] view of this record.
  AlertTrigger toTrigger() => AlertTrigger(
        alarmId: alarmId,
        occurrenceId: occurrenceId,
        instant: instantUtc,
        lead: lead,
      );

  PendingTriggerRecord copyWith({
    String? alarmId,
    String? occurrenceId,
    DateTime? instantUtc,
    DateTime? endUtc,
    AlertLeadTime? lead,
    PendingTriggerState? state,
  }) {
    return PendingTriggerRecord(
      alarmId: alarmId ?? this.alarmId,
      occurrenceId: occurrenceId ?? this.occurrenceId,
      instantUtc: instantUtc ?? this.instantUtc,
      endUtc: endUtc ?? this.endUtc,
      lead: lead ?? this.lead,
      state: state ?? this.state,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'alarmId': alarmId,
        'occurrenceId': occurrenceId,
        'instantUtc': instantUtc.toIso8601String(),
        'endUtc': endUtc.toIso8601String(),
        'lead': _leadToJson(lead),
        'state': state.name,
      };

  static PendingTriggerRecord fromJson(Map<String, Object?> json) {
    return PendingTriggerRecord(
      alarmId: json['alarmId'] as String,
      occurrenceId: json['occurrenceId'] as String,
      instantUtc: DateTime.parse(json['instantUtc'] as String),
      endUtc: DateTime.parse(json['endUtc'] as String),
      lead: _leadFromJson((json['lead'] as Map).cast<String, Object?>()),
      state: PendingTriggerState.values.asNameMap()[json['state']] ??
          PendingTriggerState.pending,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PendingTriggerRecord &&
          other.alarmId == alarmId &&
          other.occurrenceId == occurrenceId &&
          other.instantUtc == instantUtc &&
          other.endUtc == endUtc &&
          other.state == state &&
          _sameLead(other.lead, lead);

  @override
  int get hashCode =>
      Object.hash(alarmId, occurrenceId, instantUtc, endUtc, state);
}

/// One departure (fire, defer, retire, remove, acknowledge) in the engine's
/// append-only record log, for observability.
class AlertEngineRecord {
  const AlertEngineRecord({
    required this.alarmId,
    required this.occurrenceId,
    required this.reason,
    required this.atUtc,
  });

  final String alarmId;
  final String occurrenceId;
  final AlertRecordReason reason;

  /// Absolute UTC instant at which the departure happened.
  final DateTime atUtc;

  Map<String, Object?> toJson() => <String, Object?>{
        'alarmId': alarmId,
        'occurrenceId': occurrenceId,
        'reason': reason.name,
        'atUtc': atUtc.toIso8601String(),
      };

  static AlertEngineRecord fromJson(Map<String, Object?> json) {
    return AlertEngineRecord(
      alarmId: json['alarmId'] as String,
      occurrenceId: json['occurrenceId'] as String,
      reason: AlertRecordReason.values.asNameMap()[json['reason']] ??
          AlertRecordReason.fired,
      atUtc: DateTime.parse(json['atUtc'] as String),
    );
  }
}

/// Platform alarm scheduling. This is a cache of the engine's earliest
/// pending instant — the engine itself is the authority and re-arms on every
/// change. The platform uses it to wake the process; the engine's heartbeat
/// (`onTick`) is what actually fires alerts.
abstract interface class AlertSchedulerPort {
  void schedule(DateTime instantUtc, String alarmId);
  void cancel(String alarmId);
}

/// The user-facing alert surface (audio, window, notifications).
abstract interface class AlertSurfacePort {
  void ring(AlertTrigger trigger, {required List<AcknowledgementAction> actions});
  void escalate(String alarmId, EscalationStep step);
  void stop(String alarmId);
}

/// Persistence for the engine's pending set, so a crash/quit/reboot loses
/// nothing.
abstract interface class AlertPersistencePort {
  Future<void> savePending(List<PendingTriggerRecord> records);
  Future<List<PendingTriggerRecord>> loadPending();
}

/// The alert engine: plans triggers from the agenda, fires them through the
/// surface at their instants, defers them while locked/away, persists the
/// pending set, drives escalation while ringing, and never auto-dismisses.
class AlertEngine {
  AlertEngine({
    required this._scheduler,
    required this._surface,
    required this._persistence,
    required this._presence,
    this.meetingEndedGrace = const Duration(minutes: 2),
  });

  /// Rebuilds an engine from the persisted pending set. The stored instants
  /// are absolute UTC, so nothing is lost across a restart; the caller then
  /// re-plans the fresh agenda on top (idempotent by alarm id).
  static Future<AlertEngine> restore({
    required AlertSchedulerPort scheduler,
    required AlertSurfacePort surface,
    required AlertPersistencePort persistence,
    required EnginePresence presence,
    Duration meetingEndedGrace = const Duration(minutes: 2),
  }) async {
    final engine = AlertEngine(
      scheduler: scheduler,
      surface: surface,
      persistence: persistence,
      presence: presence,
      meetingEndedGrace: meetingEndedGrace,
    );
    final stored = await persistence.loadPending();
    for (final record in stored) {
      engine._pending.putIfAbsent(record.alarmId, () => record);
    }
    engine._rearm();
    return engine;
  }

  final AlertSchedulerPort _scheduler;
  final AlertSurfacePort _surface;
  final AlertPersistencePort _persistence;

  /// How long after a meeting has ended a deferred trigger may still fire.
  final Duration meetingEndedGrace;

  EnginePresence _presence;
  AlertPolicy? _policy;

  /// The persisted pending set: every trigger that has not departed, keyed by
  /// alarm id. Includes deferred and ringing states — the alert only leaves
  /// this set via retirement or explicit acknowledgement.
  final Map<String, PendingTriggerRecord> _pending = {};

  /// alarmId -> when the alert started ringing (the escalation clock).
  final Map<String, DateTime> _ringingSince = {};

  /// alarmId -> (last escalated step, when it was escalated).
  final Map<String, (EscalationStep, DateTime)> _escalationState = {};

  /// occurrenceId -> whether the meeting has a join action, refreshed on
  /// every plan, so the acknowledgement surface can offer `join`.
  final Map<String, bool> _hasJoinAction = {};

  /// Append-only departure log.
  final List<AlertEngineRecord> _records = [];

  String? _armedAlarmId;
  DateTime? _armedInstant;
  DateTime? _lastNow;

  // ---------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------

  /// Re-plans the engine from the given agenda under [policy] at [now].
  ///
  /// Idempotent: triggers are keyed by their deterministic alarm id, so
  /// re-planning never double-fires and never drops one. Triggers whose
  /// occurrence left the agenda (or whose lead time is no longer yielded)
  /// are retired with [AlertRecordReason.occurrenceRemoved] — except ringing
  /// ones, which stop only on acknowledgement.
  void plan(List<AlertOccurrence> agenda, AlertPolicy policy, DateTime now) {
    final nowUtc = now.toUtc();
    _lastNow = nowUtc;
    _policy = policy;
    var changed = false;

    _hasJoinAction.clear();
    final occurrenceById = <String, AlertOccurrence>{};
    for (final occurrence in agenda) {
      _hasJoinAction[occurrence.id] = occurrence.hasJoinAction;
      occurrenceById.putIfAbsent(occurrence.id, () => occurrence);
    }

    // Every (occurrence, lead) alarm id the agenda still yields — including
    // instants already in the past, which `computeAlertTriggers` omits but
    // the engine still owns (it fires or retires them by the grace rule).
    final identityIds = <String>{};
    for (final occurrence in agenda) {
      final leads = occurrence.leadTimesOverride ?? policy.leadTimes;
      for (final lead in leads) {
        identityIds.add(alarmIdFor(occurrence.id, lead.before));
      }
    }

    // Departures: occurrence gone from the agenda, or lead no longer
    // yielded. Ringing alerts are never auto-removed.
    final removals = <String>[];
    for (final record in _pending.values) {
      if (record.state == PendingTriggerState.ringing) continue;
      final stillPlanned =
          occurrenceById.containsKey(record.occurrenceId) &&
              identityIds.contains(record.alarmId);
      if (!stillPlanned) removals.add(record.alarmId);
    }
    for (final alarmId in removals) {
      final record = _pending.remove(alarmId)!;
      _records.add(AlertEngineRecord(
        alarmId: alarmId,
        occurrenceId: record.occurrenceId,
        reason: AlertRecordReason.occurrenceRemoved,
        atUtc: nowUtc,
      ));
      changed = true;
    }

    // Merge: add new triggers, refresh the instants of still-current ones
    // (a moved meeting must not fire at the old instant nor be lost).
    for (final occurrence in agenda) {
      final endUtc = occurrence.endUtc.toUtc();
      final triggers = computeAlertTriggers(
        occurrence: occurrence,
        policy: policy,
        now: nowUtc,
      );
      for (final trigger in triggers) {
        final existing = _pending[trigger.alarmId];
        if (existing == null) {
          _pending[trigger.alarmId] = PendingTriggerRecord(
            alarmId: trigger.alarmId,
            occurrenceId: trigger.occurrenceId,
            instantUtc: trigger.instant,
            endUtc: endUtc,
            lead: trigger.lead,
            state: PendingTriggerState.pending,
          );
          changed = true;
        } else if (existing.state != PendingTriggerState.ringing) {
          final updated = existing.copyWith(
            instantUtc: trigger.instant,
            endUtc: endUtc,
            lead: trigger.lead,
          );
          if (updated != existing) {
            _pending[trigger.alarmId] = updated;
            changed = true;
          }
        }
      }
    }

    if (changed) _changed();
  }

  /// The engine heartbeat: fires due triggers (or defers them while
  /// locked/away), retires triggers whose meeting ended beyond the grace,
  /// and drives escalation for ringing alerts.
  void onTick(DateTime now) {
    final nowUtc = now.toUtc();
    _lastNow = nowUtc;
    _resolveDue(nowUtc);
    _driveEscalation(nowUtc);
  }

  /// Presence updates. Returning to `active` fires every deferred trigger
  /// whose meeting has not ended beyond the grace, in deterministic order,
  /// and retires the rest.
  void onPresenceChanged(EnginePresence presence, DateTime now) {
    final nowUtc = now.toUtc();
    _lastNow = nowUtc;
    _presence = presence;
    if (presence == EnginePresence.active) {
      _processReturn(nowUtc);
    }
    _driveEscalation(nowUtc);
  }

  /// The app woke up or the machine unlocked: same as returning to `active`
  /// (fire deferred/due triggers per the grace rule, retire the rest).
  void onWakeOrUnlock(DateTime now) {
    final nowUtc = now.toUtc();
    _lastNow = nowUtc;
    _processReturn(nowUtc);
    _driveEscalation(nowUtc);
  }

  /// Explicit acknowledgement: the only way a ringing alert ends.
  void acknowledge(String alarmId) {
    final record = _pending[alarmId];
    if (record == null || record.state != PendingTriggerState.ringing) return;
    _pending.remove(alarmId);
    _ringingSince.remove(alarmId);
    _escalationState.remove(alarmId);
    _surface.stop(alarmId);
    final atUtc = _lastNow ?? record.instantUtc;
    _records.add(AlertEngineRecord(
      alarmId: alarmId,
      occurrenceId: record.occurrenceId,
      reason: AlertRecordReason.acknowledged,
      atUtc: atUtc,
    ));
    _changed();
  }

  /// Every trigger still in the pending set (pending, deferred or ringing),
  /// sorted by instant then alarm id.
  List<AlertTrigger> get pendingTriggers =>
      _sortedPending().map((r) => r.toTrigger()).toList(growable: false);

  /// The subset of the pending set currently deferred (locked or away),
  /// sorted by instant then alarm id.
  List<AlertTrigger> get deferredAlerts => _sortedPending()
      .where((r) =>
          r.state == PendingTriggerState.deferredLocked ||
          r.state == PendingTriggerState.deferredAway)
      .map((r) => r.toTrigger())
      .toList(growable: false);

  /// The append-only departure log.
  List<AlertEngineRecord> get records => List.unmodifiable(_records);

  /// 1s while any alert is ringing, 30s while anything is pending, else null.
  Duration? get recommendedHeartbeat {
    if (_pending.values
        .any((r) => r.state == PendingTriggerState.ringing)) {
      return const Duration(seconds: 1);
    }
    if (_pending.isNotEmpty) return const Duration(seconds: 30);
    return null;
  }

  // ---------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------

  List<PendingTriggerRecord> _sortedPending() =>
      _pending.values.toList()..sort(_byInstantThenAlarmId);

  /// Fires or defers every due pending trigger according to the current
  /// presence, and retires the ones whose meeting ended beyond the grace.
  void _resolveDue(DateTime nowUtc) {
    final due = _pending.values
        .where((r) =>
            r.state == PendingTriggerState.pending &&
            !r.instantUtc.isAfter(nowUtc))
        .toList()
      ..sort(_byInstantThenAlarmId);
    for (final record in due) {
      _resolveOne(record, nowUtc, allowDefer: true);
    }
  }

  /// Wake/unlock processing: every deferred trigger — and every pending
  /// trigger that came due while the process was suspended — either fires
  /// immediately or is retired with `meetingEnded`, in deterministic order.
  void _processReturn(DateTime nowUtc) {
    final candidates = _pending.values
        .where((r) =>
            r.state == PendingTriggerState.deferredLocked ||
            r.state == PendingTriggerState.deferredAway ||
            (r.state == PendingTriggerState.pending &&
                !r.instantUtc.isAfter(nowUtc)))
        .toList()
      ..sort(_byInstantThenAlarmId);
    for (final record in candidates) {
      _resolveOne(record, nowUtc, allowDefer: false);
    }
  }

  /// The single grace rule: a trigger whose meeting ended beyond the grace
  /// is retired (never rung); anything else due either defers (when presence
  /// is locked/away and deferral is allowed) or fires.
  void _resolveOne(
    PendingTriggerRecord record,
    DateTime nowUtc, {
    required bool allowDefer,
  }) {
    if (_endedBeyondGrace(record, nowUtc)) {
      _retire(record.alarmId, AlertRecordReason.meetingEnded, nowUtc);
      return;
    }
    if (allowDefer && _presence != EnginePresence.active) {
      _defer(
        record.alarmId,
        _presence == EnginePresence.locked
            ? PendingTriggerState.deferredLocked
            : PendingTriggerState.deferredAway,
        nowUtc,
      );
      return;
    }
    _fire(record.alarmId, nowUtc);
  }

  bool _endedBeyondGrace(PendingTriggerRecord record, DateTime nowUtc) =>
      nowUtc.isAfter(record.endUtc.add(meetingEndedGrace));

  void _fire(String alarmId, DateTime nowUtc) {
    final record = _pending[alarmId];
    if (record == null || record.state == PendingTriggerState.ringing) return;
    _pending[alarmId] = record.copyWith(state: PendingTriggerState.ringing);
    _ringingSince[alarmId] = nowUtc;
    final actions = _policy?.acknowledgementActions(
          hasJoinAction: _hasJoinAction[record.occurrenceId] ?? false,
        ) ??
        const [AcknowledgementAction.dismiss];
    _surface.ring(record.toTrigger(), actions: actions);
    _records.add(AlertEngineRecord(
      alarmId: alarmId,
      occurrenceId: record.occurrenceId,
      reason: AlertRecordReason.fired,
      atUtc: nowUtc,
    ));
    _changed();
  }

  void _defer(String alarmId, PendingTriggerState state, DateTime nowUtc) {
    final record = _pending[alarmId];
    if (record == null) return;
    _pending[alarmId] = record.copyWith(state: state);
    _records.add(AlertEngineRecord(
      alarmId: alarmId,
      occurrenceId: record.occurrenceId,
      reason: state == PendingTriggerState.deferredLocked
          ? AlertRecordReason.deferredLocked
          : AlertRecordReason.deferredAway,
      atUtc: nowUtc,
    ));
    _changed();
  }

  void _retire(String alarmId, AlertRecordReason reason, DateTime nowUtc) {
    final record = _pending.remove(alarmId);
    if (record == null) return;
    _records.add(AlertEngineRecord(
      alarmId: alarmId,
      occurrenceId: record.occurrenceId,
      reason: reason,
      atUtc: nowUtc,
    ));
    _changed();
  }

  /// Escalates each ringing alert according to the policy ladder: whenever
  /// the active step changes, or the active step's repeat cadence elapses.
  void _driveEscalation(DateTime nowUtc) {
    final policy = _policy;
    if (policy == null) return;
    for (final record in _pending.values) {
      if (record.state != PendingTriggerState.ringing) continue;
      final since = _ringingSince.putIfAbsent(record.alarmId, () => nowUtc);
      final step = policy.escalationStepAt(nowUtc.difference(since));
      if (step == null) continue;
      final previous = _escalationState[record.alarmId];
      final due =
          previous == null ||
          !identical(previous.$1, step) ||
          (step.repeatEvery != null &&
              !nowUtc.difference(previous.$2).isNegative &&
              nowUtc.difference(previous.$2) >= step.repeatEvery!);
      if (!due) continue;
      _escalationState[record.alarmId] = (step, nowUtc);
      _surface.escalate(record.alarmId, step);
    }
  }

  /// Persists the pending set and re-arms the platform scheduler cache to
  /// the earliest non-deferred pending instant. Call on every change.
  void _changed() {
    _rearm();
    unawaited(
      _persistence.savePending(List<PendingTriggerRecord>.of(_pending.values)),
    );
  }

  void _rearm() {
    PendingTriggerRecord? earliest;
    for (final record in _pending.values) {
      if (record.state != PendingTriggerState.pending) continue;
      if (earliest == null || _byInstantThenAlarmId(record, earliest) < 0) {
        earliest = record;
      }
    }
    if (_armedAlarmId == earliest?.alarmId &&
        _armedInstant == earliest?.instantUtc) {
      return;
    }
    if (_armedAlarmId != null) _scheduler.cancel(_armedAlarmId!);
    _armedAlarmId = null;
    _armedInstant = null;
    if (earliest != null) {
      _scheduler.schedule(earliest.instantUtc, earliest.alarmId);
      _armedAlarmId = earliest.alarmId;
      _armedInstant = earliest.instantUtc;
    }
  }

  static int _byInstantThenAlarmId(
    PendingTriggerRecord a,
    PendingTriggerRecord b,
  ) {
    final byInstant = a.instantUtc.compareTo(b.instantUtc);
    return byInstant != 0 ? byInstant : a.alarmId.compareTo(b.alarmId);
  }
}

Map<String, Object?> _leadToJson(AlertLeadTime lead) => <String, Object?>{
      'beforeSeconds': lead.before.inSeconds,
      'audioId': lead.profile.audioId,
      'volume': lead.profile.volume,
      'accent': lead.profile.accent,
      'fullscreen': lead.profile.fullscreen,
      'loopAudio': lead.profile.loopAudio,
    };

AlertLeadTime _leadFromJson(Map<String, Object?> json) => AlertLeadTime(
      Duration(seconds: (json['beforeSeconds'] as num).toInt()),
      AlertProfile(
        audioId: json['audioId'] as String,
        volume: (json['volume'] as num).toDouble(),
        accent: json['accent'] as String,
        fullscreen: json['fullscreen'] as bool,
        loopAudio: json['loopAudio'] as bool,
      ),
    );

bool _sameLead(AlertLeadTime a, AlertLeadTime b) =>
    a.before == b.before &&
    a.profile.audioId == b.profile.audioId &&
    a.profile.volume == b.profile.volume &&
    a.profile.accent == b.profile.accent &&
    a.profile.fullscreen == b.profile.fullscreen &&
    a.profile.loopAudio == b.profile.loopAudio;
