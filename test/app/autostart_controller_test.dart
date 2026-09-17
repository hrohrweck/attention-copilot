import 'package:flutter_test/flutter_test.dart';

import 'package:attention_copilot/app/autostart_controller.dart';

/// Scriptable [AutostartPlatform] that counts every call.
class FakeAutostartPlatform implements AutostartPlatform {
  FakeAutostartPlatform({this.enabled = false});

  bool enabled;
  int isEnabledCount = 0;
  int enableCount = 0;
  int disableCount = 0;

  /// When true, the mutation calls report failure.
  bool failMutations = false;

  @override
  Future<bool> isEnabled() async {
    isEnabledCount++;
    return enabled;
  }

  @override
  Future<bool> enable() async {
    enableCount++;
    if (failMutations) {
      return false;
    }
    enabled = true;
    return true;
  }

  @override
  Future<bool> disable() async {
    disableCount++;
    if (failMutations) {
      return false;
    }
    enabled = false;
    return true;
  }
}

void main() {
  group('AutostartController toggle', () {
    test('enabling calls the platform once and reports success', () async {
      final platform = FakeAutostartPlatform();
      final controller = AutostartController(platform: platform);

      final ok = await controller.setEnabled(true);

      expect(ok, isTrue);
      expect(platform.enableCount, 1);
      expect(platform.disableCount, 0);
      expect(platform.enabled, isTrue);
    });

    test('re-applying the same value is a no-op: no platform call', () async {
      final platform = FakeAutostartPlatform();
      final controller = AutostartController(platform: platform);

      await controller.setEnabled(true);
      final ok = await controller.setEnabled(true);

      expect(ok, isTrue);
      expect(platform.enableCount, 1, reason: 'no second enable call');
      expect(platform.disableCount, 0);
    });

    test('disabling calls the platform once', () async {
      final platform = FakeAutostartPlatform();
      final controller = AutostartController(platform: platform);

      final ok = await controller.setEnabled(false);

      expect(ok, isTrue);
      expect(platform.disableCount, 1);
      expect(platform.enableCount, 0);
    });

    test('each state change produces exactly one platform call', () async {
      final platform = FakeAutostartPlatform();
      final controller = AutostartController(platform: platform);

      await controller.setEnabled(true);
      await controller.setEnabled(false);
      await controller.setEnabled(true);

      expect(platform.enableCount, 2);
      expect(platform.disableCount, 1);
    });

    test('the result reflects the platform (failure is not swallowed)',
        () async {
      final platform = FakeAutostartPlatform()..failMutations = true;
      final controller = AutostartController(platform: platform);

      final ok = await controller.setEnabled(true);

      expect(ok, isFalse);
      expect(platform.enableCount, 1);
    });

    test('isEnabled delegates to the platform', () async {
      final platform = FakeAutostartPlatform()..enabled = true;
      final controller = AutostartController(platform: platform);

      expect(await controller.isEnabled(), isTrue);
      expect(platform.isEnabledCount, 1);
    });
  });
}
