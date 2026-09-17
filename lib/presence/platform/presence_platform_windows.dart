/// Windows presence reader via Dart FFI (`win32` package + a few manual
/// bindings where the package has no coverage). No C++ plugin, no window
/// proc: a plain 2 s poll of the session state and the last-input timestamp.
///
/// Lock/disconnect: `WTSQuerySessionInformation(WTS_CURRENT_SERVER_HANDLE,
/// WTS_CURRENT_SESSION, WTSConnectState)` — anything but `WTSActive` means
/// the session left the console ("the user has chosen to exit to the lock
/// screen" for `WTSDisconnected`).
///
/// Idle: `GetLastInputInfo` compared against `GetTickCount64` (the plan's
/// anti-wrap instruction; the 32-bit `dwTime` wrap is reconciled inline).
///
/// This file is only ever LOADED on Windows (the factory imports it
/// deferred) because `package:win32` opens its DLLs at import time.
library;

// ignore_for_file: non_constant_identifier_names

import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import '../presence_platform.dart';
import '../presence_state.dart';

// --- Manual bindings (wtsapi32.dll / kernel32.dll) ---------------------------
//
// `win32` 5.15 ships only the session-notification registration functions
// for wtsapi32 and only 32-bit `GetTickCount` for kernel32, so the three
// functions below are declared directly against `package:ffi`.

typedef _WTSQuerySessionInformationC = Int32 Function(
  IntPtr hServer,
  Uint32 sessionId,
  Int32 wtsInfoClass,
  Pointer<Pointer<Utf16>> ppBuffer,
  Pointer<Uint32> pBytesReturned,
);
typedef _WTSQuerySessionInformationDart = int Function(
  int hServer,
  int sessionId,
  int wtsInfoClass,
  Pointer<Pointer<Utf16>> ppBuffer,
  Pointer<Uint32> pBytesReturned,
);
typedef _WTSFreeMemoryC = Void Function(Pointer<Void> pMemory);
typedef _WTSFreeMemoryDart = void Function(Pointer<Void> pMemory);
typedef _GetTickCount64C = Uint64 Function();
typedef _GetTickCount64Dart = int Function();

final DynamicLibrary _wtsapi32 = DynamicLibrary.open('wtsapi32.dll');
final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

final _WTSQuerySessionInformationDart _WTSQuerySessionInformation =
    _wtsapi32.lookupFunction<_WTSQuerySessionInformationC,
        _WTSQuerySessionInformationDart>('WTSQuerySessionInformationW');

final _WTSFreeMemoryDart _WTSFreeMemory =
    _wtsapi32.lookupFunction<_WTSFreeMemoryC, _WTSFreeMemoryDart>(
        'WTSFreeMemory');

final _GetTickCount64Dart _getTickCount64 = _kernel32
    .lookupFunction<_GetTickCount64C, _GetTickCount64Dart>('GetTickCount64');

/// WTS_CURRENT_SERVER_HANDLE: the local machine (NULL).
const int _wtsCurrentServerHandle = 0;

/// WTS_CURRENT_SESSION: 0xFFFFFFFF.
const int _wtsCurrentSession = 0xFFFFFFFF;

/// WTS_INFO_CLASS.WTSConnectState.
const int _wtsConnectStateInfoClass = 8;

/// WTS_CONNECTSTATE_CLASS.WTSActive — the session is on the console. Every
/// other state (WTSDisconnected = lock screen, WTSConnected, WTSShadow, ...)
/// is treated as locked/absent.
const int _wtsActive = 0;

// --- Platform ----------------------------------------------------------------

PresencePlatform createWindowsPresencePlatform() =>
    _WindowsPresencePlatform();

class _WindowsPresencePlatform implements PresencePlatform {
  final StreamController<PresencePlatformEvent> _controller =
      StreamController<PresencePlatformEvent>.broadcast(sync: true);

  Timer? _pollTimer;
  bool _started = false;
  bool _unavailable = false;

  @override
  bool get supported => true;

  @override
  String? get unsupportedReason => null;

  @override
  String get mechanism => 'win32-wts';

  @override
  Stream<PresencePlatformEvent> samples() => _controller.stream;

  @override
  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;
    try {
      _poll();
      // Contract: never poll faster than 2 s.
      _pollTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _poll(),
      );
    } catch (error) {
      _reportUnavailable('win32 presence unavailable: $error');
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
  }

  void _poll() {
    if (_unavailable) {
      return;
    }
    try {
      final locked = _readLocked();
      final idleMilliseconds = _readIdleMilliseconds();
      _controller.add(
        PresenceSampleEvent(
          PresenceSample(
            locked: locked,
            idleFor: Duration(milliseconds: idleMilliseconds),
          ),
        ),
      );
    } catch (error) {
      _reportUnavailable('win32 presence read failed: $error');
    }
  }

  /// `WTSActive` (0) → unlocked; anything else → locked. A failed query
  /// degrades to "locked" rather than risk ringing an alert on a hidden
  /// screen.
  bool _readLocked() {
    final ppBuffer = calloc<Pointer<Utf16>>();
    final pBytes = calloc<Uint32>();
    try {
      final ok = _WTSQuerySessionInformation(
        _wtsCurrentServerHandle,
        _wtsCurrentSession,
        _wtsConnectStateInfoClass,
        ppBuffer,
        pBytes,
      );
      if (ok == 0 || ppBuffer.value == nullptr) {
        return true;
      }
      final state = ppBuffer.value.cast<Int32>().value;
      return state != _wtsActive;
    } finally {
      if (ppBuffer.value != nullptr) {
        _WTSFreeMemory(ppBuffer.value.cast<Void>());
      }
      calloc.free(ppBuffer);
      calloc.free(pBytes);
    }
  }

  /// Milliseconds since the last input event, from the 64-bit tick count
  /// (the documented comparison target for `LASTINPUTINFO.dwTime`).
  int _readIdleMilliseconds() {
    final info = calloc<LASTINPUTINFO>()..ref.cbSize = sizeOf<LASTINPUTINFO>();
    try {
      if (GetLastInputInfo(info) == 0) {
        return 0;
      }
      final tick = _getTickCount64();
      final last = info.ref.dwTime; // 32-bit; wraps every ~49.7 days.
      if (last > tick) {
        // dwTime wrapped between reads (or the counters disagree): report
        // not-idle rather than a bogus multi-week duration.
        return 0;
      }
      return tick - last;
    } finally {
      calloc.free(info);
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
}
