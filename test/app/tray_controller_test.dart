import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:attention_copilot/app/tray_controller.dart';

/// Scriptable [TrayPlatform] with a call log and a click sink.
class FakeTrayPlatform implements TrayPlatform {
  FakeTrayPlatform({TrayProbe? probeResult})
    : probeResult = probeResult ?? const TrayProbe(supported: true);

  TrayProbe probeResult;
  int initializeCount = 0;
  int destroyCount = 0;
  final List<List<TrayMenuItemSpec>> menusSet = [];

  final StreamController<String> _clicks = StreamController<String>.broadcast(
    sync: true,
  );

  /// Simulates the native tray dispatching a menu item selection.
  void simulateClick(String key) => _clicks.add(key);

  @override
  Future<TrayProbe> probe() async => probeResult;

  @override
  Future<void> initialize() async {
    initializeCount++;
  }

  @override
  Future<void> setMenu(List<TrayMenuItemSpec> items) async {
    menusSet.add(List.of(items));
  }

  @override
  Stream<String> menuItemClicks() => _clicks.stream;

  @override
  Future<void> destroy() async {
    destroyCount++;
  }
}

/// [TrayActions] whose calls are appended to [calls] in order.
TrayActions recordingActions(List<String> calls) => TrayActions(
  onOpenToday: () async => calls.add('openToday'),
  onTestAlert: () async => calls.add('testAlert'),
  onOpenSettings: () async => calls.add('settings'),
  onHideMainWindow: () async => calls.add('hideWindow'),
  onQuit: () async => calls.add('quit'),
);

void main() {
  group('TrayController lifecycle', () {
    test('starts in initializing state, not resident, not quitting', () {
      final controller = TrayController(actions: recordingActions([]));

      expect(controller.state.status, TrayAvailabilityStatus.initializing);
      expect(controller.state.resident, isFalse);
      expect(controller.state.quitting, isFalse);
      expect(controller.state.unavailableReason, isNull);
    });

    test('initialize with a supported tray installs the menu and icon',
        () async {
      final platform = FakeTrayPlatform();
      final controller = TrayController(actions: recordingActions([]));

      await controller.initialize(platform);

      expect(controller.state.status, TrayAvailabilityStatus.available);
      expect(platform.initializeCount, 1);
      expect(platform.menusSet, hasLength(1));
      expect(
        platform.menusSet.single.map((s) => s.key),
        [TrayMenuKeys.openToday, TrayMenuKeys.testAlert, TrayMenuKeys.settings, TrayMenuKeys.quit],
      );
    });

    test('unsupported tray is reported, not silently missing, and no menu '
        'is registered', () async {
      final platform = FakeTrayPlatform(
        probeResult: const TrayProbe(
          supported: false,
          reason: 'GNOME needs the AppIndicator extension',
        ),
      );
      final controller = TrayController(actions: recordingActions([]));

      await controller.initialize(platform);

      expect(controller.state.status, TrayAvailabilityStatus.unavailable);
      expect(
        controller.state.unavailableReason,
        'GNOME needs the AppIndicator extension',
      );
      expect(platform.initializeCount, 0);
      expect(platform.menusSet, isEmpty);
    });

    test('initialize twice throws instead of double-registering', () async {
      final platform = FakeTrayPlatform();
      final controller = TrayController(actions: recordingActions([]));

      await controller.initialize(platform);
      expect(
        () => controller.initialize(platform),
        throwsStateError,
      );
    });
  });

  group('resident mode (close-to-tray)', () {
    test('closing the main window hides it and keeps the process resident',
        () async {
      final calls = <String>[];
      final platform = FakeTrayPlatform();
      final controller = TrayController(actions: recordingActions(calls));
      await controller.initialize(platform);

      await controller.handleMainWindowClose();

      expect(calls, ['hideWindow']);
      expect(controller.state.resident, isTrue);
      // Closing the window is NOT an exit path.
      expect(controller.state.quitting, isFalse);
      expect(calls, isNot(contains('quit')));
    });

    test('closing the window stays resident even when the tray is '
        'unavailable (state is surfaced for the settings UI)', () async {
      final calls = <String>[];
      final platform = FakeTrayPlatform(
        probeResult: const TrayProbe(supported: false, reason: 'no host'),
      );
      final controller = TrayController(actions: recordingActions(calls));
      await controller.initialize(platform);

      await controller.handleMainWindowClose();

      expect(calls, ['hideWindow']);
      expect(controller.state.resident, isTrue);
      expect(controller.state.quitting, isFalse);
      expect(controller.state.status, TrayAvailabilityStatus.unavailable);
    });

    test('quit is the only exit path and runs exactly once', () async {
      final calls = <String>[];
      final platform = FakeTrayPlatform();
      final controller = TrayController(actions: recordingActions(calls));
      await controller.initialize(platform);

      await controller.handleMainWindowClose();
      await controller.quit();
      await controller.quit(); // repeated quit must not exit twice

      expect(calls, ['hideWindow', 'quit']);
      expect(controller.state.quitting, isTrue);
      expect(platform.destroyCount, 1);
    });

    test('window close after quit is a no-op (process is exiting)', () async {
      final calls = <String>[];
      final platform = FakeTrayPlatform();
      final controller = TrayController(actions: recordingActions(calls));
      await controller.initialize(platform);

      await controller.quit();
      await controller.handleMainWindowClose();

      expect(calls, ['quit']);
      expect(controller.state.resident, isFalse);
    });
  });

  group('state stream', () {
    test('broadcasts the current state to new listeners and transitions',
        () async {
      final platform = FakeTrayPlatform();
      final controller = TrayController(actions: recordingActions([]));
      final received = <TrayControllerState>[];

      final sub = controller.states().listen(received.add);
      await controller.initialize(platform);
      await controller.handleMainWindowClose();
      await controller.quit();
      await sub.cancel();

      expect(received, hasLength(4));
      expect(
        received.map((s) => s.status),
        [
          TrayAvailabilityStatus.initializing,
          TrayAvailabilityStatus.available,
          TrayAvailabilityStatus.available,
          TrayAvailabilityStatus.available,
        ],
      );
      expect(received[2].resident, isTrue);
      expect(received[3].quitting, isTrue);
    });
  });

  group('dispose', () {
    test('destroys the native tray and closes the stream', () async {
      final platform = FakeTrayPlatform();
      final controller = TrayController(actions: recordingActions([]));
      await controller.initialize(platform);

      await controller.dispose();
      await controller.dispose(); // idempotent

      expect(platform.destroyCount, 1);
    });

    test('does not destroy the platform twice after quit', () async {
      final platform = FakeTrayPlatform();
      final controller = TrayController(actions: recordingActions([]));
      await controller.initialize(platform);

      await controller.quit();
      await controller.dispose();

      expect(platform.destroyCount, 1);
    });
  });
}
