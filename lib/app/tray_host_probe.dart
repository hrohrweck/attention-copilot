import 'dart:io';

import 'package:attention_copilot/app/tray_controller.dart';
import 'package:dbus/dbus.dart';

/// Default desktop tray-host probe behind `tray_manager`.
///
/// macOS and Windows always provide a tray, so the probe reports `supported`
/// there without further checks. Linux needs a StatusNotifier host for the
/// icon to be drawn anywhere: on GNOME that host only exists when the
/// AppIndicator extension is installed, so the probe asks the session bus
/// for `org.kde.StatusNotifierWatcher` and reports "tray unavailable"
/// instead of the app silently having no icon.
///
/// Linux-only at runtime (`Platform.isLinux` guard). The `dbus` package is
/// pure Dart (no FFI), so importing this file does not affect macOS,
/// Windows or Android builds.
Future<TrayProbe> defaultTrayHostProbe() async {
  if (!Platform.isLinux) {
    return const TrayProbe(supported: true);
  }
  try {
    final client = DBusClient.session();
    try {
      final bus = DBusRemoteObject(
        client,
        name: 'org.freedesktop.DBus',
        path: DBusObjectPath('/org/freedesktop/DBus'),
      );
      final response = await bus.callMethod(
        'org.freedesktop.DBus',
        'NameHasOwner',
        [const DBusString('org.kde.StatusNotifierWatcher')],
      );
      final hasHost = (response.returnValues.first as DBusBoolean).value;
      return TrayProbe(
        supported: hasHost,
        reason: hasHost
            ? null
            : 'no StatusNotifier host on the session bus '
                  '(GNOME needs the AppIndicator extension)',
      );
    } finally {
      await client.close();
    }
  } catch (_) {
    // No reachable session bus: no host to draw the icon into.
    return const TrayProbe(
      supported: false,
      reason: 'cannot reach the session bus to probe for a tray host',
    );
  }
}
