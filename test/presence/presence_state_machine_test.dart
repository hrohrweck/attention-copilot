import 'package:flutter_test/flutter_test.dart';

import 'package:attention_copilot/presence/presence_state.dart';
import 'package:attention_copilot/presence/presence_state_machine.dart';

void main() {
  const threshold = Duration(minutes: 5);

  PresenceStateMachine newMachine() =>
      PresenceStateMachine(idleThreshold: threshold, mechanism: 'fake');

  group('PresenceStateMachine', () {
    test('emits nothing when the derived state does not change', () {
      final machine = newMachine();

      final first = machine.onSample(
        const PresenceSample(locked: false, idleFor: Duration.zero),
      );
      final repeat = machine.onSample(
        const PresenceSample(locked: false, idleFor: Duration.zero),
      );
      // idleFor grows but active stays true: still no new emission.
      final moreIdle = machine.onSample(
        const PresenceSample(locked: false, idleFor: Duration(minutes: 1)),
      );

      expect(first, isNotNull);
      expect(repeat, isNull);
      expect(moreIdle, isNull);
    });

    test('locked -> unlock emits locked=true then unlocked with active=true',
        () {
      final machine = newMachine();

      final locked = machine.onSample(
        const PresenceSample(locked: true, idleFor: Duration.zero),
      );
      final unlocked = machine.onSample(
        const PresenceSample(locked: false, idleFor: Duration.zero),
      );

      expect(locked, isNotNull);
      expect(locked!.locked, isTrue);
      expect(locked.active, isFalse,
          reason: 'a locked session is never active');

      expect(unlocked, isNotNull);
      expect(unlocked!.locked, isFalse);
      expect(unlocked.active, isTrue,
          reason: 'unlocked with no idle below the threshold is active');
    });

    test('idle threshold crossing emits active=false exactly once per crossing',
        () {
      final machine = newMachine();

      final active = machine.onSample(
        const PresenceSample(locked: false, idleFor: Duration.zero),
      );
      // Below threshold: still active, no emission.
      final nearThreshold = machine.onSample(
        const PresenceSample(
          locked: false,
          idleFor: Duration(minutes: 4, seconds: 59),
        ),
      );
      // First crossing: exactly one emission with active=false.
      final crossing = machine.onSample(
        const PresenceSample(locked: false, idleFor: Duration(minutes: 5)),
      );
      // Well past the threshold: still no further emission.
      final farPast = machine.onSample(
        const PresenceSample(locked: false, idleFor: Duration(minutes: 30)),
      );

      expect(active, isNotNull);
      expect(active!.active, isTrue);
      expect(nearThreshold, isNull);
      expect(crossing, isNotNull);
      expect(crossing!.active, isFalse);
      expect(crossing.idleFor, const Duration(minutes: 5));
      expect(farPast, isNull);

      // Returning to activity crosses back and emits active=true exactly once.
      final backActive = machine.onSample(
        const PresenceSample(locked: false, idleFor: Duration(seconds: 10)),
      );
      expect(backActive, isNotNull);
      expect(backActive!.active, isTrue);

      // A second crossing emits active=false again (one per crossing).
      final secondCrossing = machine.onSample(
        const PresenceSample(locked: false, idleFor: Duration(minutes: 7)),
      );
      expect(secondCrossing, isNotNull);
      expect(secondCrossing!.active, isFalse);
    });

    test('locked while idle keeps active=false and reports the idle time', () {
      final machine = newMachine();

      final locked = machine.onSample(
        const PresenceSample(
          locked: true,
          idleFor: Duration(minutes: 3),
        ),
      );

      expect(locked, isNotNull);
      expect(locked!.locked, isTrue);
      expect(locked.active, isFalse);
      expect(locked.idleFor, const Duration(minutes: 3));
    });

    test('unlock while still idle stays inactive until activity returns', () {
      final machine = newMachine();

      machine.onSample(
        const PresenceSample(locked: true, idleFor: Duration.zero),
      );
      final unlockedStillIdle = machine.onSample(
        const PresenceSample(
          locked: false,
          idleFor: Duration(minutes: 8),
        ),
      );

      expect(unlockedStillIdle, isNotNull);
      expect(unlockedStillIdle!.locked, isFalse);
      expect(unlockedStillIdle.active, isFalse,
          reason: 'idle above the threshold is not active even unlocked');
    });

    test('degraded flag changes are emitted and preserved', () {
      final machine = newMachine();

      machine.onSample(
        const PresenceSample(locked: false, idleFor: Duration.zero),
      );
      final degraded = machine.onSample(
        const PresenceSample(
          locked: false,
          idleFor: Duration.zero,
          degraded: true,
          degradedReason: 'screen-lock key not provided',
        ),
      );

      expect(degraded, isNotNull);
      expect(degraded!.degraded, isTrue);
      expect(degraded.degradedReason, 'screen-lock key not provided');
      expect(degraded.active, isTrue,
          reason: 'degradation does not change the derived active value');
    });

    test('reset() forgets the last state so the next sample re-emits', () {
      final machine = newMachine();

      final first = machine.onSample(
        const PresenceSample(locked: true, idleFor: Duration.zero),
      );
      machine.reset();
      final again = machine.onSample(
        const PresenceSample(locked: true, idleFor: Duration.zero),
      );

      expect(first, isNotNull);
      expect(again, isNotNull);
    });
  });
}
