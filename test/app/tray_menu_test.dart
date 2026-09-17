import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:attention_copilot/app/tray_controller.dart';

/// Minimal [TrayPlatform] whose clicks are driven by [simulateClick].
class ClickFakePlatform implements TrayPlatform {
  final StreamController<String> _clicks = StreamController<String>.broadcast(
    sync: true,
  );

  void simulateClick(String key) => _clicks.add(key);

  @override
  Future<TrayProbe> probe() async => const TrayProbe(supported: true);

  @override
  Future<void> initialize() async {}

  @override
  Future<void> setMenu(List<TrayMenuItemSpec> items) async {}

  @override
  Stream<String> menuItemClicks() => _clicks.stream;

  @override
  Future<void> destroy() async {}
}

TrayActions recordingActions(List<String> calls) => TrayActions(
  onOpenToday: () async => calls.add('openToday'),
  onTestAlert: () async => calls.add('testAlert'),
  onOpenSettings: () async => calls.add('settings'),
  onHideMainWindow: () async => calls.add('hideWindow'),
  onQuit: () async => calls.add('quit'),
);

void main() {
  group('tray menu action mapping', () {
    test('each menu key dispatches to exactly its callback', () async {
      const cases = <String, String>{
        TrayMenuKeys.openToday: 'openToday',
        TrayMenuKeys.testAlert: 'testAlert',
        TrayMenuKeys.settings: 'settings',
        TrayMenuKeys.quit: 'quit',
      };

      for (final entry in cases.entries) {
        final calls = <String>[];
        final controller = TrayController(actions: recordingActions(calls));

        await controller.handleMenuItem(entry.key);

        expect(calls, [entry.value], reason: 'key ${entry.key}');
      }
    });

    test('Quit is the only menu key that triggers the exit path', () async {
      for (final key in [
        TrayMenuKeys.openToday,
        TrayMenuKeys.testAlert,
        TrayMenuKeys.settings,
      ]) {
        final calls = <String>[];
        final controller = TrayController(actions: recordingActions(calls));

        await controller.handleMenuItem(key);

        expect(calls, isNot(contains('quit')), reason: 'key $key');
      }
    });

    test('unknown menu key fires no callback', () async {
      final calls = <String>[];
      final controller = TrayController(actions: recordingActions(calls));

      await controller.handleMenuItem('unknown_key');

      expect(calls, isEmpty);
    });

    test('native tray click events are routed through the same mapping',
        () async {
      final calls = <String>[];
      final platform = ClickFakePlatform();
      final controller = TrayController(actions: recordingActions(calls));
      await controller.initialize(platform);

      platform.simulateClick(TrayMenuKeys.openToday);
      platform.simulateClick(TrayMenuKeys.testAlert);
      platform.simulateClick(TrayMenuKeys.settings);
      platform.simulateClick(TrayMenuKeys.quit);
      await Future<void>.delayed(Duration.zero);

      expect(calls, ['openToday', 'testAlert', 'settings', 'quit']);
    });
  });
}
