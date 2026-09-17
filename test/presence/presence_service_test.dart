import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:attention_copilot/presence/presence_platform.dart';
import 'package:attention_copilot/presence/presence_service.dart';
import 'package:attention_copilot/presence/presence_state.dart';

void main() {
  group('FakePresenceService (state machine on the fake)', () {
    test('locked -> unlock emits the transition in order with active=true',
        () async {
      final service = FakePresenceService();
      final states = <PresenceState>[];
      service.states().listen(states.add);

      await service.start();
      service.emitSample(locked: true);
      service.emitSample(locked: false); // idle 0: active again.

      expect(states, hasLength(2));
      expect(states[0].locked, isTrue);
      expect(states[0].active, isFalse,
          reason: 'first emission must be the locked state');
      expect(states[1].locked, isFalse);
      expect(states[1].active, isTrue,
          reason: 'unlock with fresh input is active');
      await service.stop();
    });

    test('idle threshold crossing emits active=false exactly once', () async {
      final service = FakePresenceService(
        idleThreshold: const Duration(minutes: 5),
      );
      final states = <PresenceState>[];
      service.states().listen(states.add);

      await service.start();
      service.emitSample(locked: false);
      service.emitSample(
        locked: false,
        idleFor: const Duration(minutes: 4, seconds: 59),
      );
      service.emitSample(
        locked: false,
        idleFor: const Duration(minutes: 5),
      );
      service.emitSample(
        locked: false,
        idleFor: const Duration(minutes: 30),
      );

      final inactiveEmissions =
          states.where((s) => s.active == false).toList();
      expect(inactiveEmissions, hasLength(1),
          reason: 'the threshold crossing must emit active=false exactly once');
      expect(inactiveEmissions.single.idleFor, const Duration(minutes: 5));
      await service.stop();
    });

    test('unsupported platform reports supported=false + reason, never throws',
        () async {
      final service = FakePresenceService(
        supported: false,
        unsupportedReason: 'no presence mechanism on this platform',
      );
      final states = <PresenceState>[];
      service.states().listen(states.add);

      await service.start();
      expect(states, hasLength(1));
      expect(states.single.supported, isFalse);
      expect(states.single.unsupportedReason,
          'no presence mechanism on this platform');

      // Injecting samples into an unsupported platform must be a silent
      // no-op, not an error.
      expect(
        () => service.emitSample(locked: true),
        returnsNormally,
      );
      expect(states, hasLength(1));

      await service.stop();
      // stop on an already-stopped service must not throw.
      await expectLater(service.stop(), completes);
    });

    test('start is idempotent for unsupported platforms', () async {
      final service = FakePresenceService(
        supported: false,
        unsupportedReason: 'nope',
      );
      final states = <PresenceState>[];
      service.states().listen(states.add);

      await service.start();
      await service.start();

      expect(states, hasLength(1));
      await service.stop();
    });

    test('repeated identical samples do not duplicate emissions', () async {
      final service = FakePresenceService();
      final states = <PresenceState>[];
      service.states().listen(states.add);

      await service.start();
      service.emitSample(locked: false);
      service.emitSample(locked: false);
      service.emitSample(locked: false);

      expect(states, hasLength(1));
      await service.stop();
    });

    test('degraded samples flow through to the emitted state', () async {
      final service = FakePresenceService();
      final states = <PresenceState>[];
      service.states().listen(states.add);

      await service.start();
      service.emitSample(locked: false);
      service.emitSample(
        locked: false,
        degraded: true,
        degradedReason: 'lock key missing',
      );

      expect(states, hasLength(2));
      expect(states[1].degraded, isTrue);
      expect(states[1].degradedReason, 'lock key missing');
      await service.stop();
    });
  });

  group('StreamPresenceService', () {
    test('wires platform samples through the machine to states', () async {
      final platform = _FakePlatform();
      final service = StreamPresenceService(
        platform: platform,
        idleThreshold: const Duration(minutes: 5),
      );
      final states = <PresenceState>[];
      service.states().listen(states.add);

      await service.start();
      platform.emitSample(const PresenceSample(
        locked: true,
        idleFor: Duration.zero,
      ));
      platform.emitSample(const PresenceSample(
        locked: false,
        idleFor: Duration.zero,
      ));
      platform.emitSample(const PresenceSample(
        locked: false,
        idleFor: Duration(minutes: 10),
      ));

      expect(states, hasLength(3));
      expect(states[0].locked, isTrue);
      expect(states[1].active, isTrue);
      expect(states[2].active, isFalse);
      expect(states.every((s) => s.mechanism == 'fake-platform'), isTrue);
      await service.stop();
    });

    test('an unavailable platform reports supported=false with a reason',
        () async {
      final platform = _FakePlatform();
      final service = StreamPresenceService(platform: platform);
      final states = <PresenceState>[];
      service.states().listen(states.add);

      await service.start();
      platform.emitUnavailable('D-Bus session bus missing');

      expect(states, hasLength(1));
      expect(states.single.supported, isFalse);
      expect(states.single.unsupportedReason, 'D-Bus session bus missing');

      // Samples after unavailability are ignored, and nothing throws.
      platform.emitSample(const PresenceSample(
        locked: false,
        idleFor: Duration.zero,
      ));
      expect(states, hasLength(1));
      await service.stop();
    });

    test('a platform that reports supported=false emits the unsupported state '
        'without being started', () async {
      final platform =
          _FakePlatform(supported: false, unsupportedReason: 'stub os');
      final service = StreamPresenceService(platform: platform);
      final states = <PresenceState>[];
      service.states().listen(states.add);

      await service.start();

      expect(states, hasLength(1));
      expect(states.single.supported, isFalse);
      expect(states.single.unsupportedReason, 'stub os');
      expect(platform.startCalls, 0,
          reason: 'an unsupported platform must not be started');
      await service.stop();
    });
  });
}

/// Minimal in-memory [PresencePlatform] used to verify the service wiring.
class _FakePlatform implements PresencePlatform {
  _FakePlatform({this.supported = true, this.unsupportedReason});

  final _controller = StreamController<PresencePlatformEvent>.broadcast(
    sync: true,
  );

  @override
  final bool supported;

  @override
  final String? unsupportedReason;

  @override
  String get mechanism => 'fake-platform';

  int startCalls = 0;
  int stopCalls = 0;

  void emitSample(PresenceSample sample) =>
      _controller.add(PresenceSampleEvent(sample));

  void emitUnavailable(String reason) =>
      _controller.add(PresenceUnavailableEvent(reason));

  @override
  Stream<PresencePlatformEvent> samples() => _controller.stream;

  @override
  Future<void> start() async => startCalls++;

  @override
  Future<void> stop() async => stopCalls++;
}
