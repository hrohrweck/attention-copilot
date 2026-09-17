/// Runtime dispatcher for `dart.library.io` targets, selecting the presence
/// mechanism for the running OS.
///
/// `package:win32` opens its DLLs at import time, so the Windows
/// implementation is imported `deferred` and only loaded when
/// `Platform.isWindows` — macOS, Linux and Android builds and test runs
/// never touch it. The macOS and Linux implementations are pure Dart +
/// channels/D-Bus and import safely everywhere.
library;

import 'dart:async';
import 'dart:io' show Platform;

import '../presence_platform.dart';
import 'presence_platform_linux.dart' as linux;
import 'presence_platform_macos.dart' as macos;
import 'presence_platform_windows.dart' deferred as windows;

PresencePlatform createPresencePlatform() {
  if (Platform.isMacOS) {
    return macos.createMacOSPresencePlatform();
  }
  if (Platform.isLinux) {
    return linux.createLinuxPresencePlatform();
  }
  if (Platform.isWindows) {
    return _DeferredWindowsPresencePlatform();
  }
  return unsupportedPresencePlatform(
    'no presence mechanism for ${Platform.operatingSystem}',
  );
}

/// Loads the win32-backed platform lazily, on first use, on Windows only.
class _DeferredWindowsPresencePlatform implements PresencePlatform {
  PresencePlatform? _inner;

  Future<PresencePlatform> _load() async {
    final inner = _inner;
    if (inner != null) {
      return inner;
    }
    await windows.loadLibrary();
    return _inner = windows.createWindowsPresencePlatform();
  }

  @override
  bool get supported => true;

  @override
  String? get unsupportedReason => null;

  @override
  String get mechanism => 'win32-wts';

  @override
  Stream<PresencePlatformEvent> samples() async* {
    final platform = await _load();
    yield* platform.samples();
  }

  @override
  Future<void> start() async => (await _load()).start();

  @override
  Future<void> stop() async => _inner?.stop();
}
