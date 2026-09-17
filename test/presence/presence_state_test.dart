import 'package:flutter_test/flutter_test.dart';

import 'package:attention_copilot/presence/presence_state.dart';

void main() {
  group('PresenceState', () {
    test('is an immutable value with structural equality', () {
      const a = PresenceState(
        locked: false,
        idleFor: Duration(minutes: 2),
        active: true,
        supported: true,
        degraded: false,
        mechanism: 'fake',
      );
      const b = PresenceState(
        locked: false,
        idleFor: Duration(minutes: 2),
        active: true,
        supported: true,
        degraded: false,
        mechanism: 'fake',
      );
      const c = PresenceState(
        locked: true,
        idleFor: Duration(minutes: 2),
        active: false,
        supported: true,
        degraded: false,
        mechanism: 'fake',
      );

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
      expect(a.toString(), contains('active: true'));
    });

    test('unsupported factory sets supported=false and carries the reason',
        () {
      const state = PresenceState.unsupported(
        reason: 'no session bus',
        mechanism: 'linux',
      );

      expect(state.supported, isFalse);
      expect(state.unsupportedReason, 'no session bus');
      expect(state.mechanism, 'linux');
      expect(state.locked, isFalse);
      expect(state.active, isFalse);
    });

    test('equivalentTo compares the semantic fields, not idleFor', () {
      const base = PresenceState(
        locked: false,
        idleFor: Duration(minutes: 1),
        active: true,
        supported: true,
      );
      const fresherIdle = PresenceState(
        locked: false,
        idleFor: Duration(minutes: 4),
        active: true,
        supported: true,
      );
      const idleCrossed = PresenceState(
        locked: false,
        idleFor: Duration(minutes: 6),
        active: false,
        supported: true,
      );

      expect(base.equivalentTo(fresherIdle), isTrue);
      expect(base.equivalentTo(idleCrossed), isFalse);
      expect(base.equivalentTo(null), isFalse);
    });
  });

  group('PresenceSample', () {
    test('is an immutable raw platform input with equality', () {
      const sample = PresenceSample(
        locked: true,
        idleFor: Duration(seconds: 3),
      );
      const equal = PresenceSample(
        locked: true,
        idleFor: Duration(seconds: 3),
      );
      const different = PresenceSample(
        locked: true,
        idleFor: Duration(seconds: 4),
      );

      expect(sample.locked, isTrue);
      expect(sample.idleFor, const Duration(seconds: 3));
      expect(sample.degraded, isFalse);
      expect(sample, equals(equal));
      expect(sample.hashCode, equals(equal.hashCode));
      expect(sample, isNot(equals(different)));
    });
  });
}
