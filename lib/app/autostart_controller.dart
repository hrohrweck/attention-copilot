import 'dart:io';

import 'package:launch_at_startup/launch_at_startup.dart';

/// Seam over the OS autostart mechanism (`launch_at_startup` plugin).
/// Tests inject a fake to assert the toggle calls the platform exactly once
/// per state change; the app wires [LaunchAtStartupAutostartPlatform].
abstract interface class AutostartPlatform {
  /// Whether the OS currently launches the app at login.
  Future<bool> isEnabled();

  /// Registers the app for launch at login. Returns success.
  Future<bool> enable();

  /// Unregisters the app from launch at login. Returns success.
  Future<bool> disable();
}

/// Real [AutostartPlatform] backed by the `launch_at_startup` plugin.
///
/// [setup] must run once before [enable]/[disable]/[isEnabled] so the plugin
/// knows which executable to register. Constructing this class in a test
/// host is safe, but its methods hit the native channel and are only called
/// from the real app.
final class LaunchAtStartupAutostartPlatform implements AutostartPlatform {
  LaunchAtStartupAutostartPlatform({String? appName, String? appPath}) {
    launchAtStartup.setup(
      appName: appName ?? 'Attention Copilot',
      appPath: appPath ?? Platform.resolvedExecutable,
    );
  }

  @override
  Future<bool> isEnabled() => launchAtStartup.isEnabled();

  @override
  Future<bool> enable() => launchAtStartup.enable();

  @override
  Future<bool> disable() => launchAtStartup.disable();
}

/// Applies the user's autostart preference to the OS.
///
/// Each state change results in exactly one platform call: re-applying the
/// current value is a no-op that never touches the platform, so a settings
/// toggle cannot spam the OS registry/login items. Autostart is only ever
/// registered through [setEnabled] — the app itself never registers it
/// behind the user's back.
class AutostartController {
  AutostartController({required this._platform});

  final AutostartPlatform _platform;

  bool? _requested;
  bool? _current;

  /// Whether the OS currently launches the app at login.
  Future<bool> isEnabled() => _platform.isEnabled();

  /// Registers ([enabled] = true) or unregisters ([enabled] = false)
  /// autostart. Returns the platform's reported success; a failed mutation
  /// is returned to the caller, not swallowed.
  Future<bool> setEnabled(bool enabled) async {
    final current = _current;
    if (enabled == _requested && current != null) {
      // No state change: do not touch the platform again.
      return current;
    }
    _requested = enabled;
    final result = enabled ? await _platform.enable() : await _platform.disable();
    _current = result;
    return result;
  }
}
