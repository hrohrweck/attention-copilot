/// macOS presence reader over a MethodChannel/EventChannel pair wired to the
/// native `PresencePlugin` (macos/Runner/PresencePlugin.swift).
///
/// Native side computes `locked` from `CGSessionCopyCurrentDictionary()`
/// (`kCGSessionOnConsoleKey` primary, `CGSSessionScreenIsLocked` as an
/// optional detection-only enhancement) plus screensaver state, and idle
/// from `CGEventSourceSecondsSinceLastEventType`. This side polls the
/// native read every 2 s and, on lock/unlock/screensaver push events,
/// reads immediately so lock transitions are visible without waiting for
/// the next poll tick.
///
/// If the plugin is missing or the native read fails, the platform reports
/// `PresenceUnavailableEvent` — it never throws into the service.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import '../presence_platform.dart';
import '../presence_state.dart';

const String kPresenceMethodChannel = 'attention_copilot/presence';
const String kPresenceEventChannel = 'attention_copilot/presence_events';

/// Lock/screensaver events pushed by the native plugin.
enum _NativeEvent {
  lock('lock'),
  unlock('unlock'),
  screensaverStart('screensaverStart'),
  screensaverStop('screensaverStop'),
  initial('initial');

  const _NativeEvent(this.name);

  final String name;

  static _NativeEvent? tryParse(String value) {
    for (final event in values) {
      if (event.name == value) {
        return event;
      }
    }
    return null;
  }
}

PresencePlatform createMacOSPresencePlatform() => _MacOSPresencePlatform();

class _MacOSPresencePlatform implements PresencePlatform {
  static const MethodChannel _methodChannel =
      MethodChannel(kPresenceMethodChannel);
  static const EventChannel _eventChannel =
      EventChannel(kPresenceEventChannel);

  final StreamController<PresencePlatformEvent> _controller =
      StreamController<PresencePlatformEvent>.broadcast(sync: true);

  StreamSubscription<Object?>? _eventsSubscription;
  Timer? _pollTimer;
  bool _started = false;
  bool _reading = false;
  bool _unavailable = false;
  Duration _lastIdle = Duration.zero;

  /// Guards the event-triggered reads so a burst of notifications (lock +
  /// screensaver) does not stampede the channel.
  static const Duration _readThrottle = Duration(milliseconds: 500);
  DateTime? _lastReadAt;

  @override
  bool get supported => true;

  @override
  String? get unsupportedReason => null;

  @override
  String get mechanism => 'cgssession';

  @override
  Stream<PresencePlatformEvent> samples() => _controller.stream;

  @override
  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;
    try {
      _eventsSubscription = _eventChannel
          .receiveBroadcastStream()
          .listen(_onNativeEvent, onError: _onEventChannelError);
      // Kick off immediately, then poll every 2 s (never faster — contract).
      await _readAndEmit();
      _pollTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _readAndEmit(),
      );
    } on MissingPluginException {
      _reportUnavailable('presence plugin not registered on this build');
    }
  }

  @override
  Future<void> stop() async {
    if (!_started) {
      return;
    }
    _started = false;
    _pollTimer?.cancel();
    _pollTimer = null;
    await _eventsSubscription?.cancel();
    _eventsSubscription = null;
  }

  void _onNativeEvent(Object? rawEvent) {
    if (rawEvent is! String) {
      return;
    }
    final event = _NativeEvent.tryParse(rawEvent);
    if (event == null) {
      return;
    }
    switch (event) {
      case _NativeEvent.lock || _NativeEvent.screensaverStart:
        // The console switch races the notification: trust the event over a
        // read that may still report the pre-lock state.
        _emit(
          PresenceSample(
            locked: true,
            idleFor: _lastIdle,
          ),
        );
      case _NativeEvent.unlock ||
            _NativeEvent.screensaverStop ||
            _NativeEvent.initial:
        // Fresh read: CGSession now reflects the real state.
        _readAndEmit();
    }
  }

  void _onEventChannelError(Object error) {
    // Event push is an optimisation; the 2 s poll still runs. Only if the
    // METHOD channel also fails do we degrade to unavailable.
  }

  Future<void> _readAndEmit() async {
    if (_unavailable || _reading) {
      return;
    }
    final now = DateTime.now();
    if (_lastReadAt != null &&
        now.difference(_lastReadAt!) < _readThrottle) {
      return;
    }
    _reading = true;
    try {
      _lastReadAt = DateTime.now();
      final map = await _methodChannel
          .invokeMapMethod<String, Object?>('readPresence');
      if (map == null) {
        _reportUnavailable('presence plugin returned no data');
        return;
      }
      final locked = map['locked'] == true;
      final idleSeconds = (map['idleSeconds'] as num?)?.toDouble() ?? 0;
      final degraded = map['degraded'] == true;
      _lastIdle = Duration(
        milliseconds: (idleSeconds.clamp(0, double.infinity) * 1000).round(),
      );
      _emit(
        PresenceSample(
          locked: locked,
          idleFor: _lastIdle,
          degraded: degraded,
          degradedReason: degraded
              ? 'CGSSessionScreenIsLocked key not provided by this OS; '
                  'using console + screensaver signals'
              : null,
        ),
      );
    } on MissingPluginException {
      _reportUnavailable('presence plugin not registered on this build');
    } catch (error) {
      _reportUnavailable('presence read failed: $error');
    } finally {
      _reading = false;
    }
  }

  void _reportUnavailable(String reason) {
    if (_unavailable) {
      return;
    }
    _unavailable = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    _controller.add(PresenceUnavailableEvent(reason));
  }

  void _emit(PresenceSample sample) {
    if (!_unavailable) {
      _controller.add(PresenceSampleEvent(sample));
    }
  }
}
