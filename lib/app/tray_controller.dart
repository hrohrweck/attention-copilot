import 'dart:async';

/// Keys of the tray context menu entries. Stable identifiers: the native
/// platform reports clicks by key, and the settings UI consumes them.
abstract final class TrayMenuKeys {
  static const String openToday = 'open_today';
  static const String testAlert = 'test_alert';
  static const String settings = 'settings';
  static const String quit = 'quit';
}

/// One entry of the tray context menu.
final class TrayMenuItemSpec {
  const TrayMenuItemSpec({required this.key, required this.label});

  final String key;
  final String label;
}

/// Whether a tray icon can exist on this desktop at all.
enum TrayAvailabilityStatus {
  /// Probing/installing the tray host; nothing is known yet.
  initializing,

  /// The icon is installed and the menu is active.
  available,

  /// No tray host exists (e.g. GNOME without the AppIndicator extension).
  /// The app stays resident but there is no icon: the settings UI must
  /// surface [TrayControllerState.unavailableReason] instead of appearing
  /// broken.
  unavailable,
}

/// User-visible state of the tray subsystem, consumed by the settings UI.
final class TrayControllerState {
  const TrayControllerState({
    required this.status,
    required this.resident,
    required this.quitting,
    this.unavailableReason,
  });

  const TrayControllerState.initial()
    : status = TrayAvailabilityStatus.initializing,
      unavailableReason = null,
      resident = false,
      quitting = false;

  final TrayAvailabilityStatus status;

  /// Why no tray icon can be shown (set only when [status] is
  /// [TrayAvailabilityStatus.unavailable]).
  final String? unavailableReason;

  /// True once the main window has been closed while the app stays resident.
  final bool resident;

  /// True once an explicit Quit was requested; the process is exiting.
  final bool quitting;

  TrayControllerState copyWith({
    TrayAvailabilityStatus? status,
    String? unavailableReason,
    bool? resident,
    bool? quitting,
  }) {
    return TrayControllerState(
      status: status ?? this.status,
      unavailableReason: unavailableReason ?? this.unavailableReason,
      resident: resident ?? this.resident,
      quitting: quitting ?? this.quitting,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is TrayControllerState &&
        other.status == status &&
        other.unavailableReason == unavailableReason &&
        other.resident == resident &&
        other.quitting == quitting;
  }

  @override
  int get hashCode => Object.hash(status, unavailableReason, resident, quitting);

  @override
  String toString() {
    return 'TrayControllerState(status: $status, unavailableReason: '
        '$unavailableReason, resident: $resident, quitting: $quitting)';
  }
}

/// Result of a tray host availability probe.
final class TrayProbe {
  const TrayProbe({required this.supported, this.reason});

  final bool supported;

  /// Why no tray host responds (set only when [supported] is false).
  final String? reason;
}

/// Low-level tray icon/menu backend. The real implementation wraps
/// `tray_manager`; tests inject a fake, so the controller logic runs without
/// a native tray.
abstract interface class TrayPlatform {
  /// Whether a tray host exists on this desktop. Linux/GNOME without the
  /// AppIndicator extension reports `supported=false` with a reason.
  Future<TrayProbe> probe();

  /// Installs the icon + tooltip and starts forwarding native events.
  Future<void> initialize();

  /// Replaces the context menu.
  Future<void> setMenu(List<TrayMenuItemSpec> items);

  /// Native menu item selections, keyed by [TrayMenuItemSpec.key].
  Stream<String> menuItemClicks();

  /// Removes the icon and releases native resources. Idempotent.
  Future<void> destroy();
}

/// Callbacks the tray menu and the window-close policy dispatch into.
/// The controller owns *when* each callback runs; the callbacks own *what*
/// the callback does (window raising, alert firing, process exit).
final class TrayActions {
  const TrayActions({
    required this.onOpenToday,
    required this.onTestAlert,
    required this.onOpenSettings,
    required this.onHideMainWindow,
    required this.onQuit,
  });

  /// "Open today" menu item: shows and raises the main window.
  final Future<void> Function() onOpenToday;

  /// "Test alert" menu item: fires a real end-to-end test alert.
  final Future<void> Function() onTestAlert;

  /// "Settings" menu item: opens the settings surface.
  final Future<void> Function() onOpenSettings;

  /// Hides (does not close) the main window when the user hits close.
  final Future<void> Function() onHideMainWindow;

  /// Terminates the process. The ONLY exit path of the application.
  final Future<void> Function() onQuit;
}

/// Owns the tray lifecycle and the resident-mode policy: closing the main
/// window hides it and keeps the process alive, and an explicit Quit (tray
/// menu or [quit]) is the only way the process exits.
class TrayController {
  TrayController({required this._actions});

  final TrayActions _actions;

  TrayPlatform? _platform;
  StreamSubscription<String>? _clicks;
  TrayControllerState _state = const TrayControllerState.initial();
  bool _disposed = false;

  late final StreamController<TrayControllerState> _states =
      StreamController<TrayControllerState>.broadcast(
        sync: true,
        onListen: () {
          // Replay the current state so a late listener can always render.
          if (!_states.isClosed) {
            _states.add(_state);
          }
        },
      );

  /// The current state.
  TrayControllerState get state => _state;

  /// Current state on subscribe, then every transition.
  Stream<TrayControllerState> states() => _states.stream;

  /// The tray context menu definition, in display order.
  List<TrayMenuItemSpec> buildMenu() => const [
    TrayMenuItemSpec(key: TrayMenuKeys.openToday, label: 'Open today'),
    TrayMenuItemSpec(key: TrayMenuKeys.testAlert, label: 'Test alert'),
    TrayMenuItemSpec(key: TrayMenuKeys.settings, label: 'Settings'),
    TrayMenuItemSpec(key: TrayMenuKeys.quit, label: 'Quit'),
  ];

  /// Probes the tray host, installs the menu and starts routing clicks.
  /// On a desktop without a tray host the state reports `unavailable` (with
  /// the reason) and no native menu is registered — the settings UI consumes
  /// that state instead of the app silently having no icon.
  Future<void> initialize(TrayPlatform platform) async {
    if (_disposed) {
      throw StateError('TrayController already disposed');
    }
    if (_platform != null) {
      throw StateError('TrayController already initialized');
    }
    _platform = platform;

    final probe = await platform.probe();
    if (!probe.supported) {
      _setState(
        _state.copyWith(
          status: TrayAvailabilityStatus.unavailable,
          unavailableReason: probe.reason ?? 'no tray host on this desktop',
        ),
      );
      return;
    }

    await platform.setMenu(buildMenu());
    await platform.initialize();
    _clicks = platform.menuItemClicks().listen(
      (key) => unawaited(handleMenuItem(key)),
    );
    _setState(_state.copyWith(status: TrayAvailabilityStatus.available));
  }

  /// Routes a tray menu selection to its callback. Unknown keys are ignored.
  Future<void> handleMenuItem(String key) async {
    switch (key) {
      case TrayMenuKeys.openToday:
        await _actions.onOpenToday();
      case TrayMenuKeys.testAlert:
        await _actions.onTestAlert();
      case TrayMenuKeys.settings:
        await _actions.onOpenSettings();
      case TrayMenuKeys.quit:
        await quit();
    }
  }

  /// The user closed the main window: hide it and stay resident. The process
  /// must keep running until an explicit [quit].
  Future<void> handleMainWindowClose() async {
    if (_state.quitting) {
      return;
    }
    _setState(_state.copyWith(resident: true));
    await _actions.onHideMainWindow();
  }

  /// The single, explicit exit path. Removes the tray icon and exits.
  /// Idempotent: a repeated quit does not exit twice.
  Future<void> quit() async {
    if (_state.quitting) {
      return;
    }
    _setState(_state.copyWith(quitting: true));
    final platform = _platform;
    if (platform != null) {
      await platform.destroy();
    }
    await _actions.onQuit();
  }

  /// Stops routing clicks, releases the native tray (unless [quit] already
  /// destroyed it) and closes the state stream. Idempotent; the controller
  /// must not be reused afterwards.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _clicks?.cancel();
    final platform = _platform;
    if (platform != null && !_state.quitting) {
      await platform.destroy();
    }
    if (!_states.isClosed) {
      await _states.close();
    }
  }

  void _setState(TrayControllerState next) {
    _state = next;
    if (!_states.isClosed) {
      _states.add(next);
    }
  }
}
