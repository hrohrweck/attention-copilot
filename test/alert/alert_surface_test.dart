import 'dart:async';

import 'package:attention_copilot/alert/alert_surface.dart';
import 'package:attention_copilot/domain/alert_policy.dart';
import 'package:flutter_test/flutter_test.dart';

/// Recording fake of the low-level window/audio seam. [DesktopAlertSurface]
/// never touches window_manager or audioplayers directly — everything goes
/// through [AlertPlatformDriver], so these tests exercise the real surface
/// logic against a fully controllable driver.
class FakeAlertPlatformDriver implements AlertPlatformDriver {
  FakeAlertPlatformDriver({List<AlertDisplay>? displays})
      : displays = displays ?? [const AlertDisplay(id: 'd0', name: 'Main')];

  final List<AlertDisplay> displays;

  /// Every window handle handed out, in creation order.
  final List<AlertWindowHandle> windows = [];

  /// display ids passed to [createWindow], in order.
  final List<String> createdDisplays = [];

  /// Every window operation, in order, as `op` strings like `top:true`,
  /// `show`, `focus`, `preventClose:true`, `accent:red`, `close`.
  final List<(AlertWindowHandle, String)> windowOps = [];

  /// audioIds passed to [playAudio], in order.
  final List<String> played = [];

  /// Volumes passed to [playAudio], in order.
  final List<double> playedVolumes = [];

  /// Volumes passed to [setAudioVolume], in order.
  final List<double> setVolumes = [];

  int stopAudioCalls = 0;

  final StreamController<AlertWindowHandle> _closeRequested =
      StreamController<AlertWindowHandle>.broadcast(sync: true);
  final StreamController<void> _audioCompleted =
      StreamController<void>.broadcast(sync: true);

  int _windowSeq = 0;

  @override
  Stream<AlertWindowHandle> get windowCloseRequested =>
      _closeRequested.stream;

  @override
  Stream<void> get audioCycleCompleted => _audioCompleted.stream;

  @override
  Future<List<AlertDisplay>> listDisplays() async => displays;

  @override
  Future<AlertWindowHandle> createWindow(AlertDisplay display) async {
    createdDisplays.add(display.id);
    final window = AlertWindowHandle(
      id: 'w${_windowSeq++}',
      displayId: display.id,
    );
    windows.add(window);
    return window;
  }

  @override
  Future<void> showWindow(AlertWindowHandle window) async {
    windowOps.add((window, 'show'));
  }

  @override
  Future<void> focusWindow(AlertWindowHandle window) async {
    windowOps.add((window, 'focus'));
  }

  @override
  Future<void> setAlwaysOnTop(AlertWindowHandle window, bool value) async {
    windowOps.add((window, 'top:$value'));
  }

  @override
  Future<void> setFullScreen(AlertWindowHandle window, bool value) async {
    windowOps.add((window, 'fullscreen:$value'));
  }

  @override
  Future<void> setPreventClose(AlertWindowHandle window, bool value) async {
    windowOps.add((window, 'preventClose:$value'));
  }

  @override
  Future<void> setAccent(AlertWindowHandle window, String accent) async {
    windowOps.add((window, 'accent:$accent'));
  }

  @override
  Future<void> closeWindow(AlertWindowHandle window) async {
    windowOps.add((window, 'close'));
  }

  @override
  Future<void> playAudio(String audioId, {required double volume}) async {
    played.add(audioId);
    playedVolumes.add(volume);
  }

  @override
  Future<void> setAudioVolume(double volume) async {
    setVolumes.add(volume);
  }

  @override
  Future<void> stopAudio() async {
    stopAudioCalls++;
  }

  @override
  Future<void> dispose() async {}

  /// Simulates the user pressing the OS close button on [window].
  void emitCloseRequest(AlertWindowHandle window) {
    _closeRequested.add(window);
  }

  /// Simulates the audio cycle reaching its end.
  void emitAudioCompleted() {
    _audioCompleted.add(null);
  }

  /// The operations recorded for one window, in order.
  List<String> opsFor(AlertWindowHandle window) =>
      [for (final (w, op) in windowOps) if (identical(w, window)) op];
}

/// Builds an [AlertTrigger] with a controllable profile.
AlertTrigger trigger(
  String alarmId, {
  String audioId = 'alarm',
  double volume = 1.0,
  String accent = 'red',
  bool fullscreen = true,
  bool loopAudio = true,
}) {
  return AlertTrigger(
    alarmId: alarmId,
    occurrenceId: 'occ-$alarmId',
    instant: DateTime.utc(2026, 9, 17, 10, 0),
    lead: AlertLeadTime(
      const Duration(minutes: 1),
      AlertProfile(
        audioId: audioId,
        volume: volume,
        accent: accent,
        fullscreen: fullscreen,
        loopAudio: loopAudio,
      ),
    ),
  );
}

EscalationStep step(EscalationAction action, {Duration? repeatEvery}) =>
    EscalationStep(after: Duration.zero, action: action, repeatEvery: repeatEvery);

/// Flushes the surface's fire-and-forget driver futures.
Future<void> flush() => pumpEventQueue();

void main() {
  group('DesktopAlertSurface.ring', () {
    test('raises an always-on-top window, locks close, and starts audio', () async {
      final driver = FakeAlertPlatformDriver();
      final surface = DesktopAlertSurface(driver: driver);

      surface.ring(trigger('a1'), actions: const [AcknowledgementAction.dismiss]);
      await flush();

      expect(surface.isRinging('a1'), isTrue);
      expect(driver.played, ['alarm']);
      expect(driver.playedVolumes, [1.0]);
      expect(driver.createdDisplays, ['d0']);
      expect(driver.windows, hasLength(1));

      final window = driver.windows.single;
      expect(driver.opsFor(window), [
        'top:true',
        'fullscreen:true',
        'accent:red',
        'preventClose:true',
        'show',
        'focus',
      ]);
    });

    test('never rings until ring() is called (deferred alerts stay silent)',
        () async {
      // The engine reports a deferred alert by simply not calling ring();
      // the surface must not produce any window or audio on its own.
      final driver = FakeAlertPlatformDriver();
      final surface = DesktopAlertSurface(driver: driver);

      surface.escalate('a1', step(EscalationAction.repeatAudioCycle));
      surface.stop('a1');
      await flush();

      expect(driver.played, isEmpty);
      expect(driver.createdDisplays, isEmpty);
      expect(driver.stopAudioCalls, 0);
    });
  });

  group('DesktopAlertSurface.escalate', () {
    test('maps the default escalation ladder in order', () async {
      final driver = FakeAlertPlatformDriver();
      final surface = DesktopAlertSurface(driver: driver);
      surface.ring(
        trigger('a1', volume: 0.6, accent: 'amber'),
        actions: const [AcknowledgementAction.dismiss],
      );
      await flush();
      final playsBefore = driver.played.length;
      final window = driver.windows.single;

      // Step 1: repeat the audio cycle at its 30 s cadence.
      surface.escalate(
        'a1',
        const EscalationStep(
          after: Duration.zero,
          action: EscalationAction.repeatAudioCycle,
          repeatEvery: Duration(seconds: 30),
        ),
      );
      await flush();
      expect(driver.played.length, playsBefore + 1,
          reason: 'repeatAudioCycle replays the audio cycle');
      expect(driver.playedVolumes.last, 0.6);

      // Step 2: raise the volume one step.
      surface.escalate(
        'a1',
        const EscalationStep(
          after: Duration(seconds: 30),
          action: EscalationAction.raiseVolume,
        ),
      );
      await flush();
      expect(driver.setVolumes.last, closeTo(0.7, 0.0001));
      expect(surface.volumeFor('a1'), closeTo(0.7, 0.0001));

      // Step 3: re-raise the window (re-assert always-on-top, re-show, refocus).
      final opsBefore = driver.windowOps.length;
      surface.escalate(
        'a1',
        const EscalationStep(
          after: Duration(seconds: 60),
          action: EscalationAction.reRaiseWindow,
        ),
      );
      await flush();
      expect(driver.windowOps.sublist(opsBefore), [
        (window, 'top:true'),
        (window, 'show'),
        (window, 'focus'),
      ]);

      // Step 4: change the accent to the next intensity.
      surface.escalate(
        'a1',
        const EscalationStep(
          after: Duration(seconds: 90),
          action: EscalationAction.changeAccent,
        ),
      );
      await flush();
      expect(surface.accentFor('a1'), 'orange');
      expect(driver.opsFor(window), contains('accent:orange'));

      // Step 5: hold the window and remind — the window is re-asserted.
      final opsBeforeHold = driver.windowOps.length;
      surface.escalate(
        'a1',
        const EscalationStep(
          after: Duration(minutes: 5),
          action: EscalationAction.holdWindowAndRemind,
          repeatEvery: Duration(seconds: 30),
        ),
      );
      await flush();
      expect(driver.windowOps.sublist(opsBeforeHold), [
        (window, 'top:true'),
        (window, 'show'),
        (window, 'focus'),
      ]);

      expect(
        surface.escalationLog('a1'),
        const [
          EscalationAction.repeatAudioCycle,
          EscalationAction.raiseVolume,
          EscalationAction.reRaiseWindow,
          EscalationAction.changeAccent,
          EscalationAction.holdWindowAndRemind,
        ],
      );
    });

    test('volume ramp clamps at 1.0', () async {
      final driver = FakeAlertPlatformDriver();
      final surface = DesktopAlertSurface(driver: driver);
      surface.ring(
        trigger('a1', volume: 0.95),
        actions: const [AcknowledgementAction.dismiss],
      );
      await flush();

      surface.escalate('a1', step(EscalationAction.raiseVolume));
      await flush();
      expect(surface.volumeFor('a1'), 1.0);
      expect(driver.setVolumes.last, 1.0);

      surface.escalate('a1', step(EscalationAction.raiseVolume));
      await flush();
      expect(surface.volumeFor('a1'), 1.0, reason: 'never exceeds 1.0');
    });

    test('escalate on an unknown (never-rung) alarm is a no-op', () async {
      final driver = FakeAlertPlatformDriver();
      final surface = DesktopAlertSurface(driver: driver);

      surface.escalate('ghost', step(EscalationAction.raiseVolume));
      surface.escalate('ghost', step(EscalationAction.reRaiseWindow));
      await flush();

      expect(driver.setVolumes, isEmpty);
      expect(driver.windowOps, isEmpty);
      expect(surface.escalationLog('ghost'), isEmpty);
    });
  });

  group('DesktopAlertSurface close prevention', () {
    test('close attempt re-raises, does not stop audio, is counted', () async {
      final driver = FakeAlertPlatformDriver();
      final surface = DesktopAlertSurface(driver: driver);
      surface.ring(trigger('a1'), actions: const [AcknowledgementAction.dismiss]);
      await flush();
      final window = driver.windows.single;
      final opsBefore = driver.windowOps.length;

      driver.emitCloseRequest(window);
      await flush();

      expect(surface.closeAttemptsFor('a1'), 1);
      // Re-arms close prevention and re-raises: top, show, focus.
      expect(driver.windowOps.sublist(opsBefore), [
        (window, 'preventClose:true'),
        (window, 'show'),
        (window, 'top:true'),
        (window, 'focus'),
      ]);
      // Acknowledgement is the only way to stop audio — closing must not.
      expect(driver.stopAudioCalls, 0);
      expect(surface.isRinging('a1'), isTrue);
    });

    test('repeated close attempts keep re-raising and counting', () async {
      final driver = FakeAlertPlatformDriver();
      final surface = DesktopAlertSurface(driver: driver);
      surface.ring(trigger('a1'), actions: const [AcknowledgementAction.dismiss]);
      await flush();
      final window = driver.windows.single;

      driver.emitCloseRequest(window);
      driver.emitCloseRequest(window);
      driver.emitCloseRequest(window);
      await flush();

      expect(surface.closeAttemptsFor('a1'), 3);
      expect(driver.stopAudioCalls, 0);
    });
  });

  group('DesktopAlertSurface.stop', () {
    test('stop is the only path that stops audio', () async {
      final driver = FakeAlertPlatformDriver();
      final surface = DesktopAlertSurface(driver: driver);
      surface.ring(trigger('a1'), actions: const [AcknowledgementAction.dismiss]);
      await flush();

      // Escalations and close attempts must never stop audio.
      surface.escalate('a1', step(EscalationAction.repeatAudioCycle));
      surface.escalate('a1', step(EscalationAction.raiseVolume));
      driver.emitCloseRequest(driver.windows.single);
      driver.emitAudioCompleted();
      await flush();
      expect(driver.stopAudioCalls, 0);

      surface.stop('a1');
      await flush();
      expect(driver.stopAudioCalls, 1);
      expect(surface.isRinging('a1'), isFalse);

      // Idempotent: a second stop changes nothing.
      surface.stop('a1');
      await flush();
      expect(driver.stopAudioCalls, 1);
    });

    test('stop unlocks close and closes the windows', () async {
      final driver = FakeAlertPlatformDriver();
      final surface = DesktopAlertSurface(driver: driver);
      surface.ring(trigger('a1'), actions: const [AcknowledgementAction.dismiss]);
      await flush();
      final window = driver.windows.single;

      surface.stop('a1');
      await flush();

      expect(driver.opsFor(window), contains('preventClose:false'));
      expect(driver.opsFor(window).last, 'close');
    });

    test('stopping one of two ringing alarms restarts the other one', () async {
      final driver = FakeAlertPlatformDriver();
      final surface = DesktopAlertSurface(driver: driver);
      surface.ring(trigger('a1', audioId: 'alarm'), actions: const []);
      surface.ring(trigger('a2', audioId: 'chime', loopAudio: false), actions: const []);
      await flush();
      final playsBefore = driver.played.length;
      expect(driver.played.last, 'chime');

      surface.stop('a2');
      await flush();
      expect(driver.stopAudioCalls, 1);
      expect(driver.played.length, playsBefore + 1,
          reason: 'the still-ringing alarm takes over the audio channel');
      expect(driver.played.last, 'alarm');
      expect(surface.isRinging('a1'), isTrue);
      expect(surface.isRinging('a2'), isFalse);
    });
  });

  group('DesktopAlertSurface acknowledgement', () {
    test('requestAcknowledgement forwards to the wired handler, which stops',
        () async {
      final driver = FakeAlertPlatformDriver();
      final surface = DesktopAlertSurface(driver: driver);
      final handled = <String>[];
      surface.setOnAcknowledgement((alarmId) {
        handled.add(alarmId);
        // The app wires this to the engine, which calls stop() — the only
        // path that ends the audio.
        surface.stop(alarmId);
      });
      surface.ring(trigger('a1'), actions: const [AcknowledgementAction.dismiss]);
      await flush();

      surface.requestAcknowledgement('a1');
      await flush();

      expect(handled, ['a1']);
      expect(driver.stopAudioCalls, 1);
      expect(surface.isRinging('a1'), isFalse);
    });

    test('requestAcknowledgement for an unknown alarm does nothing', () async {
      final driver = FakeAlertPlatformDriver();
      final surface = DesktopAlertSurface(driver: driver);
      final handled = <String>[];
      surface.setOnAcknowledgement(handled.add);

      surface.requestAcknowledgement('ghost');
      await flush();

      expect(handled, isEmpty);
      expect(driver.stopAudioCalls, 0);
    });
  });

  group('DesktopAlertSurface multi-display', () {
    test('two displays create one window per display, each always-on-top',
        () async {
      final driver = FakeAlertPlatformDriver(
        displays: const [
          AlertDisplay(id: 'd0', name: 'Main'),
          AlertDisplay(id: 'd1', name: 'Secondary'),
        ],
      );
      final surface = DesktopAlertSurface(driver: driver);

      surface.ring(trigger('a1'), actions: const [AcknowledgementAction.dismiss]);
      await flush();

      expect(driver.createdDisplays, ['d0', 'd1']);
      expect(driver.windows, hasLength(2));
      for (final window in driver.windows) {
        expect(driver.opsFor(window), contains('top:true'));
        expect(driver.opsFor(window), contains('preventClose:true'));
        expect(driver.opsFor(window), contains('show'));
        expect(driver.opsFor(window), contains('focus'));
      }
    });

    test('alertOnAllDisplays defaults ON when 2+ displays exist', () async {
      final driver = FakeAlertPlatformDriver(
        displays: const [
          AlertDisplay(id: 'd0'),
          AlertDisplay(id: 'd1'),
        ],
      );
      final surface = DesktopAlertSurface(driver: driver); // setting: null

      surface.ring(trigger('a1'), actions: const []);
      await flush();

      expect(driver.createdDisplays, ['d0', 'd1']);
    });

    test('alertOnAllDisplays: false covers only the primary display', () async {
      final driver = FakeAlertPlatformDriver(
        displays: const [
          AlertDisplay(id: 'd0'),
          AlertDisplay(id: 'd1'),
        ],
      );
      final surface = DesktopAlertSurface(
        driver: driver,
        alertOnAllDisplays: false,
      );

      surface.ring(trigger('a1'), actions: const []);
      await flush();

      expect(driver.createdDisplays, ['d0']);
    });

    test('a single display always yields exactly one window', () async {
      final driver = FakeAlertPlatformDriver(
        displays: const [AlertDisplay(id: 'd0')],
      );
      final surface = DesktopAlertSurface(
        driver: driver,
        alertOnAllDisplays: true,
      );

      surface.ring(trigger('a1'), actions: const []);
      await flush();

      expect(driver.createdDisplays, ['d0']);
    });
  });

  group('DesktopAlertSurface audio looping', () {
    test('loopAudio:true replays the cycle on completion', () async {
      final driver = FakeAlertPlatformDriver();
      final surface = DesktopAlertSurface(driver: driver);
      surface.ring(trigger('a1', loopAudio: true), actions: const []);
      await flush();
      expect(driver.played, ['alarm']);

      driver.emitAudioCompleted();
      await flush();
      expect(driver.played, ['alarm', 'alarm'],
          reason: 'replays on completion — no reliance on a gapless loop');

      // Once acknowledged, a completion no longer replays.
      surface.stop('a1');
      await flush();
      final plays = driver.played.length;
      driver.emitAudioCompleted();
      await flush();
      expect(driver.played.length, plays);
    });

    test('loopAudio:false plays once and does not self-repeat', () async {
      final driver = FakeAlertPlatformDriver();
      final surface = DesktopAlertSurface(driver: driver);
      surface.ring(trigger('a1', loopAudio: false), actions: const []);
      await flush();

      driver.emitAudioCompleted();
      await flush();
      expect(driver.played, ['alarm'],
          reason: 'the engine re-triggers the cycle via repeatAudioCycle');
    });
  });

  group('FakeAlertSurface', () {
    test('records ring, escalate, stop and acknowledgement', () async {
      final surface = FakeAlertSurface();
      final acknowledged = <String>[];
      surface.setOnAcknowledgement(acknowledged.add);

      final t = trigger('a1');
      surface.ring(t, actions: const [AcknowledgementAction.dismiss]);
      final s = const EscalationStep(
        after: Duration(seconds: 30),
        action: EscalationAction.raiseVolume,
      );
      surface.escalate('a1', s);

      expect(surface.rung, [t]);
      expect(surface.escalations, [('a1', s)]);
      expect(surface.isRinging('a1'), isTrue);

      surface.requestAcknowledgement('a1');
      expect(acknowledged, ['a1']);

      surface.stop('a1');
      expect(surface.stopped, ['a1']);
      expect(surface.isRinging('a1'), isFalse);
    });
  });
}
