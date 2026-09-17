import 'package:flutter_test/flutter_test.dart';

import 'package:attention_copilot/domain/alert_policy.dart';

/// Minimal occurrence test double; the real `EventOccurrence` (todo 4)
/// implements the same [AlertOccurrence] interface later.
class _Occ implements AlertOccurrence {
  _Occ({
    required this.id,
    required this.startUtc,
    required this.endUtc,
    this.leadTimesOverride,
  });

  @override
  final String id;

  @override
  final DateTime startUtc;

  @override
  final DateTime endUtc;

  @override
  final List<AlertLeadTime>? leadTimesOverride;

  /// No caller of this test double needs a join action; it stays `false`.
  @override
  final bool hasJoinAction = false;
}

const _amber = AlertProfile(
  audioId: 'chime',
  volume: 0.6,
  accent: 'amber',
  fullscreen: false,
  loopAudio: false,
);

const _red = AlertProfile(
  audioId: 'alarm',
  volume: 1.0,
  accent: 'red',
  fullscreen: true,
  loopAudio: true,
);

void main() {
  final now = DateTime.utc(2026, 9, 17, 12, 0, 0);

  group('computeAlertTriggers', () {
    test('a meeting 3 h away produces exactly the configured default triggers',
        () {
      final occ = _Occ(
        id: 'evt-1',
        startUtc: now.add(const Duration(hours: 3)),
        endUtc: now.add(const Duration(hours: 3, minutes: 30)),
      );

      final triggers = computeAlertTriggers(
        occurrence: occ,
        policy: AlertPolicy.defaults(),
        now: now,
      );

      expect(triggers, hasLength(2));
      expect(
        triggers[0].instant,
        occ.startUtc.subtract(const Duration(minutes: 10)),
      );
      expect(
        triggers[1].instant,
        occ.startUtc.subtract(const Duration(minutes: 1)),
      );
      expect(triggers[0].lead.before, const Duration(minutes: 10));
      expect(triggers[1].lead.before, const Duration(minutes: 1));
      // ascending order
      expect(
        triggers[0].instant.isBefore(triggers[1].instant),
        isTrue,
      );
      // absolute UTC instants only
      expect(triggers.every((t) => t.instant.isUtc), isTrue);
    });

    test('a meeting 30 s away produces no past trigger', () {
      final occ = _Occ(
        id: 'evt-2',
        startUtc: now.add(const Duration(seconds: 30)),
        endUtc: now.add(const Duration(minutes: 30)),
      );

      expect(
        computeAlertTriggers(
          occurrence: occ,
          policy: AlertPolicy.defaults(),
          now: now,
        ),
        isEmpty,
      );
    });

    test('a per-meeting override replaces the global lead-time list', () {
      const override = [
        AlertLeadTime(Duration(minutes: 5), _amber),
        AlertLeadTime(Duration(minutes: 2), _red),
      ];
      final occ = _Occ(
        id: 'evt-3',
        startUtc: now.add(const Duration(hours: 1)),
        endUtc: now.add(const Duration(hours: 1, minutes: 30)),
        leadTimesOverride: override,
      );

      final triggers = computeAlertTriggers(
        occurrence: occ,
        policy: AlertPolicy.defaults(),
        now: now,
      );

      expect(triggers, hasLength(2));
      expect(
        triggers[0].instant,
        occ.startUtc.subtract(const Duration(minutes: 5)),
      );
      expect(
        triggers[1].instant,
        occ.startUtc.subtract(const Duration(minutes: 2)),
      );
      expect(triggers[0].lead.profile.accent, 'amber');
      expect(triggers[1].lead.profile.accent, 'red');
    });

    test('every trigger carries a stable deterministic alarm id', () {
      final occ = _Occ(
        id: 'evt-stable',
        startUtc: now.add(const Duration(hours: 3)),
        endUtc: now.add(const Duration(hours: 3, minutes: 30)),
      );

      final first = computeAlertTriggers(
        occurrence: occ,
        policy: AlertPolicy.defaults(),
        now: now,
      );
      final second = computeAlertTriggers(
        occurrence: occ,
        policy: AlertPolicy.defaults(),
        now: now.add(const Duration(minutes: 1)),
      );

      // same event + same lead times → identical ids, independent of `now`
      expect(
        first.map((t) => t.alarmId).toList(),
        second.map((t) => t.alarmId).toList(),
      );
      // different lead times → different ids
      expect(first[0].alarmId, isNot(first[1].alarmId));
      // different event → different ids
      final other = _Occ(
        id: 'evt-other',
        startUtc: occ.startUtc,
        endUtc: occ.endUtc,
      );
      final otherTriggers = computeAlertTriggers(
        occurrence: other,
        policy: AlertPolicy.defaults(),
        now: now,
      );
      expect(otherTriggers[0].alarmId, isNot(first[0].alarmId));
      // the id does not depend on the policy (only on event + lead time)
      final escalatedPolicy = AlertPolicy(
        leadTimes: const [
          AlertLeadTime.tenMinutes,
          AlertLeadTime.oneMinute,
        ],
        escalation: const [
          EscalationStep(
            after: Duration.zero,
            action: EscalationAction.holdWindowAndRemind,
          ),
        ],
        snooze: SnoozeConfig.disabled,
      );
      final escalatedTriggers = computeAlertTriggers(
        occurrence: occ,
        policy: escalatedPolicy,
        now: now,
      );
      expect(
        escalatedTriggers.map((t) => t.alarmId).toList(),
        first.map((t) => t.alarmId).toList(),
      );
    });

    test('a trigger due exactly now is emitted (not treated as past)', () {
      final occ = _Occ(
        id: 'evt-boundary',
        startUtc: now.add(const Duration(minutes: 1)),
        endUtc: now.add(const Duration(minutes: 31)),
        leadTimesOverride: const [
          AlertLeadTime(Duration(minutes: 1), _red),
        ],
      );

      final triggers = computeAlertTriggers(
        occurrence: occ,
        policy: AlertPolicy.defaults(),
        now: now,
      );

      expect(triggers, hasLength(1));
      expect(triggers.single.instant, now);
    });

    test('an event that has already ended yields no triggers', () {
      final occ = _Occ(
        id: 'evt-done',
        startUtc: now.subtract(const Duration(hours: 1)),
        endUtc: now.subtract(const Duration(minutes: 30)),
      );

      expect(
        computeAlertTriggers(
          occurrence: occ,
          policy: AlertPolicy.defaults(),
          now: now,
        ),
        isEmpty,
      );
    });

    test('never schedules a trigger after the meeting has ended', () {
      // A (pathological) negative lead time pushes the instant past the
      // meeting end and past `now`; the end guard must still exclude it.
      final occ = _Occ(
        id: 'evt-x',
        startUtc: now.subtract(const Duration(minutes: 1)),
        endUtc: now.subtract(const Duration(seconds: 30)),
        leadTimesOverride: const [
          AlertLeadTime(Duration(minutes: -2), _red),
        ],
      );

      expect(
        computeAlertTriggers(
          occurrence: occ,
          policy: AlertPolicy.defaults(),
          now: now,
        ),
        isEmpty,
      );
    });

    test('triggers are returned in ascending order even with unsorted leads',
        () {
      final occ = _Occ(
        id: 'evt-asc',
        startUtc: now.add(const Duration(hours: 1)),
        endUtc: now.add(const Duration(hours: 2)),
        leadTimesOverride: const [
          AlertLeadTime(Duration(minutes: 1), _red),
          AlertLeadTime(Duration(minutes: 10), _amber),
        ],
      );

      final triggers = computeAlertTriggers(
        occurrence: occ,
        policy: AlertPolicy.defaults(),
        now: now,
      );

      expect(triggers, hasLength(2));
      expect(
        triggers[0].instant.isBefore(triggers[1].instant),
        isTrue,
      );
    });
  });

  group('AlertPolicy defaults', () {
    test('lead times default to 10 min and 1 min, ascending, with profiles',
        () {
      final policy = AlertPolicy.defaults();

      // The configured defaults are "10 minutes and 1 minute"; the model
      // keeps the list ascending.
      expect(
        policy.leadTimes.map((l) => l.before).toList(),
        const [Duration(minutes: 1), Duration(minutes: 10)],
      );
      final headsUp = policy.leadTimes.singleWhere(
        (l) => l.before == const Duration(minutes: 10),
      );
      final urgent = policy.leadTimes.singleWhere(
        (l) => l.before == const Duration(minutes: 1),
      );
      expect(headsUp.profile.accent, 'amber');
      expect(headsUp.profile.volume, lessThan(urgent.profile.volume));
      expect(headsUp.profile.fullscreen, isFalse);
      expect(urgent.profile.accent, 'red');
      expect(urgent.profile.fullscreen, isTrue);
      expect(urgent.profile.loopAudio, isTrue);
    });

    test('default escalation repeats every 30 s, then holds with a periodic '
        'reminder after 5 minutes', () {
      final policy = AlertPolicy.defaults();

      final first = policy.escalation.first;
      expect(first.after, Duration.zero);
      expect(first.action, EscalationAction.repeatAudioCycle);
      expect(first.repeatEvery, const Duration(seconds: 30));

      final hold = policy.escalation.last;
      expect(hold.after, const Duration(minutes: 5));
      expect(hold.action, EscalationAction.holdWindowAndRemind);
      expect(hold.repeatEvery, isNotNull);

      // steps are ordered ascending by `after`
      for (var i = 1; i < policy.escalation.length; i++) {
        expect(
          policy.escalation[i - 1].after <= policy.escalation[i].after,
          isTrue,
          reason: 'step $i is out of order',
        );
      }
    });

    test('escalationStepAt returns the active step for an unacknowledged '
        'duration', () {
      final policy = AlertPolicy.defaults();

      expect(
        policy.escalationStepAt(const Duration(seconds: 10))?.action,
        EscalationAction.repeatAudioCycle,
      );
      expect(
        policy.escalationStepAt(const Duration(seconds: 31))?.action,
        EscalationAction.raiseVolume,
      );
      expect(
        policy.escalationStepAt(const Duration(minutes: 10))?.action,
        EscalationAction.holdWindowAndRemind,
      );
    });

    test('snooze is disabled by default', () {
      expect(AlertPolicy.defaults().snooze.enabled, isFalse);
    });
  });

  group('acknowledgement surface', () {
    test('when snooze is disabled the surface has no snooze action', () {
      final policy = AlertPolicy.defaults();

      expect(
        policy.acknowledgementActions(hasJoinAction: false),
        const [AcknowledgementAction.dismiss],
      );
      expect(
        policy.acknowledgementActions(hasJoinAction: true),
        const [AcknowledgementAction.dismiss, AcknowledgementAction.join],
      );
    });

    test('snooze action appears only when snooze is enabled', () {
      final policy = AlertPolicy(
        leadTimes: const [
          AlertLeadTime.tenMinutes,
          AlertLeadTime.oneMinute,
        ],
        escalation: AlertPolicy.defaults().escalation,
        snooze: const SnoozeConfig(enabled: true),
      );

      expect(
        policy.acknowledgementActions(hasJoinAction: false),
        const [AcknowledgementAction.dismiss, AcknowledgementAction.snooze],
      );
      expect(
        policy.acknowledgementActions(hasJoinAction: true),
        const [
          AcknowledgementAction.dismiss,
          AcknowledgementAction.join,
          AcknowledgementAction.snooze,
        ],
      );
    });
  });

  group('normalisation', () {
    test('policy sorts unsorted lead times ascending and dedupes', () {
      final policy = AlertPolicy(
        leadTimes: const [
          AlertLeadTime.oneMinute,
          AlertLeadTime.tenMinutes,
          AlertLeadTime(Duration(minutes: 10), _amber),
        ],
        escalation: AlertPolicy.defaults().escalation,
        snooze: SnoozeConfig.disabled,
      );

      expect(
        policy.leadTimes.map((l) => l.before).toList(),
        const [Duration(minutes: 1), Duration(minutes: 10)],
      );
    });
  });
}
