import 'dart:async';

import 'package:attention_copilot/app/tray_controller.dart';
import 'package:tray_manager/tray_manager.dart';

import 'tray_host_probe.dart';

/// [TrayPlatform] over `tray_manager`, the real OS tray backend.
///
/// Constructing this class is safe everywhere; the native channel is only
/// touched inside [initialize], [setMenu] and [destroy], which the app calls
/// after [TrayController.initialize] has probed the desktop. Tests never
/// construct it — they inject fakes through the seam.
final class TrayManagerTrayPlatform implements TrayPlatform {
  TrayManagerTrayPlatform({
    this.iconPath,
    this.tooltip = 'Attention Copilot',
    Future<TrayProbe> Function()? probe,
  }) : _probe = probe ?? defaultTrayHostProbe;

  /// Path to the tray icon (PNG on Windows/Linux, template image on macOS).
  /// Null until packaging ships an icon asset: the native default is used.
  final String? iconPath;

  final String tooltip;

  final Future<TrayProbe> Function() _probe;

  final StreamController<String> _clicks = StreamController<String>.broadcast(
    sync: true,
  );

  late final TrayListener _listener = _TrayListener(_clicks);

  @override
  Future<TrayProbe> probe() => _probe();

  @override
  Future<void> initialize() async {
    trayManager.addListener(_listener);
    final icon = iconPath;
    if (icon != null && icon.isNotEmpty) {
      await trayManager.setIcon(icon);
    }
    await trayManager.setToolTip(tooltip);
  }

  @override
  Future<void> setMenu(List<TrayMenuItemSpec> items) async {
    await trayManager.setContextMenu(
      Menu(
        items: [
          for (final spec in items)
            MenuItem(key: spec.key, label: spec.label),
        ],
      ),
    );
  }

  @override
  Stream<String> menuItemClicks() => _clicks.stream;

  @override
  Future<void> destroy() async {
    trayManager.removeListener(_listener);
    if (!_clicks.isClosed) {
      await _clicks.close();
    }
    await trayManager.destroy();
  }
}

final class _TrayListener with TrayListener {
  _TrayListener(this._clicks);

  final StreamController<String> _clicks;

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    final key = menuItem.key;
    if (key == null || key.isEmpty) {
      return;
    }
    if (!_clicks.isClosed) {
      _clicks.add(key);
    }
  }
}
