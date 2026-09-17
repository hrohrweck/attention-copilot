/// The real [AlertPlatformDriver]: windows through `window_manager` +
/// `screen_retriever`, audio through `audioplayers`.
library;

import 'dart:async';

import 'package:attention_copilot/alert/alert_surface.dart';
import 'package:audioplayers/audioplayers.dart';
// screen_retriever is window_manager's own display dependency (the plan
// refers to it as "window_manager's screenRetriever"); importing it directly
// is the supported path, so the depend_on_referenced_packages lint is not
// actionable here.
// ignore: depend_on_referenced_packages
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

/// Honest capability note (read before trusting multi-display behaviour):
///
/// `window_manager` manages exactly ONE native window — the application's
/// main window — and exposes no API to create additional ones. On a
/// multi-display setup, [createWindow] therefore returns an `unmanaged`
/// [AlertWindowHandle] for every display beyond the first: the surface keeps
/// issuing the same commands (which no-op for unmanaged handles) so the
/// escalation logic stays uniform, and the `managed` flag lets diagnostics
/// (todo 27) state the limitation instead of pretending every display is
/// covered. True per-display windows need native runner support.
class WindowManagerAudioDriver
    with WindowListener
    implements AlertPlatformDriver {
  WindowManagerAudioDriver({AudioPlayer Function()? audioPlayerFactory})
      : _player = (audioPlayerFactory ?? AudioPlayer.new)() {
    windowManager.addListener(this);
  }

  final AudioPlayer _player;
  final StreamController<AlertWindowHandle> _closeRequested =
      StreamController<AlertWindowHandle>.broadcast();

  AlertWindowHandle? _mainWindow;
  String? _accent;
  bool _disposed = false;

  /// The accent currently rendered on the managed alert window. The window
  /// content itself lands with the alert UI todo; the surface drives this
  /// value and the widget reads it when it renders.
  String? get accent => _accent;

  @override
  Stream<AlertWindowHandle> get windowCloseRequested =>
      _closeRequested.stream;

  @override
  Stream<void> get audioCycleCompleted => _player.onPlayerComplete;

  @override
  Future<List<AlertDisplay>> listDisplays() async {
    final displays = await ScreenRetriever.instance.getAllDisplays();
    if (displays.isEmpty) {
      return const [AlertDisplay(id: 'primary', name: 'Primary display')];
    }
    return [
      for (final display in displays)
        AlertDisplay(id: display.id, name: display.name),
    ];
  }

  @override
  Future<AlertWindowHandle> createWindow(AlertDisplay display) async {
    if (_mainWindow == null) {
      await windowManager.waitUntilReadyToShow();
      _mainWindow = AlertWindowHandle(id: 'main', displayId: display.id);
      return _mainWindow!;
    }
    // See the class doc: window_manager cannot create further windows.
    return AlertWindowHandle(
      id: 'display-${display.id}',
      displayId: display.id,
      managed: false,
    );
  }

  @override
  Future<void> showWindow(AlertWindowHandle window) async {
    if (!window.managed) return;
    await windowManager.show();
  }

  @override
  Future<void> focusWindow(AlertWindowHandle window) async {
    if (!window.managed) return;
    await windowManager.focus();
  }

  @override
  Future<void> setAlwaysOnTop(AlertWindowHandle window, bool value) async {
    if (!window.managed) return;
    await windowManager.setAlwaysOnTop(value);
  }

  @override
  Future<void> setFullScreen(AlertWindowHandle window, bool value) async {
    if (!window.managed) return;
    await windowManager.setFullScreen(value);
  }

  @override
  Future<void> setPreventClose(AlertWindowHandle window, bool value) async {
    if (!window.managed) return;
    await windowManager.setPreventClose(value);
  }

  @override
  Future<void> setAccent(AlertWindowHandle window, String accent) async {
    if (!window.managed) return;
    _accent = accent;
  }

  @override
  Future<void> closeWindow(AlertWindowHandle window) async {
    if (!window.managed) return;
    await windowManager.close();
  }

  @override
  Future<void> playAudio(String audioId, {required double volume}) async {
    // Restart the cycle from the top rather than resuming: looping is
    // deliberately replay-on-completion, never a gapless native loop.
    await _player.stop();
    await _player.setVolume(volume);
    // Asset registration (`flutter: assets:` in pubspec.yaml) and the audio
    // files themselves land with the audio-asset todo; the path convention
    // is fixed here so the asset pipeline only has to drop files in.
    await _player.play(AssetSource('assets/audio/$audioId.mp3'));
  }

  @override
  Future<void> setAudioVolume(double volume) => _player.setVolume(volume);

  @override
  Future<void> stopAudio() => _player.stop();

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    windowManager.removeListener(this);
    await _player.dispose();
    await _closeRequested.close();
  }

  /// [window_manager] reports a close attempt on the managed window; forward
  /// it so the surface can re-raise the still-ringing alert.
  @override
  void onWindowClose() {
    final window = _mainWindow;
    if (window == null) return;
    _closeRequested.add(window);
  }
}
