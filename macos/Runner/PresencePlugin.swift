import Cocoa
import CoreGraphics
import FlutterMacOS

/// Native presence detection for macOS (plan todo 14).
///
/// Lock detection:
///  * `CGSessionCopyCurrentDictionary()` with the documented
///    `kCGSessionOnConsoleKey` as the primary signal. The dictionary key is
///    referenced by its literal name because the CFString constant is not
///    exported to Swift.
///  * `CGSSessionScreenIsLocked` (undocumented) is read for DETECTION ONLY —
///    never to defeat the lock — when this OS version provides it. When the
///    key is absent the plugin falls back to the console/screensaver signals
///    and flags the result as degraded instead of failing.
///  * The screensaver state (distributed notifications
///    `com.apple.screensaver.didstart`/`didstop`) counts as "screen not
///    visible".
///
/// Idle detection: `CGEventSourceSecondsSinceLastEventType` on the combined
/// session state with `kCGAnyInputEventType` (rawValue `UInt32.max`).
///
/// Push: the lock/screensaver distributed notifications are forwarded over
/// an event channel so the Dart side can react to lock transitions without
/// waiting for its next 2 s poll.
class PresencePlugin: NSObject, FlutterStreamHandler {
  static let methodChannelName = "attention_copilot/presence"
  static let eventChannelName = "attention_copilot/presence_events"

  private let notificationCenter = DistributedNotificationCenter.default()
  private var observerTokens: [NSObjectProtocol] = []
  private var eventSink: FlutterEventSink?
  private var screensaverRunning = false

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = PresencePlugin()

    let methodChannel = FlutterMethodChannel(
      name: methodChannelName, binaryMessenger: registrar.messenger)
    methodChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "readPresence":
        result(instance.readPresence())
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let eventChannel = FlutterEventChannel(
      name: eventChannelName, binaryMessenger: registrar.messenger)
    eventChannel.setStreamHandler(instance)
  }

  deinit {
    removeObservers()
  }

  // MARK: - FlutterStreamHandler

  func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    observeLockNotifications()
    // Kick the Dart side so it performs an immediate initial read.
    events("initial")
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    removeObservers()
    eventSink = nil
    return nil
  }

  // MARK: - Lock/screensaver notifications

  private func observeLockNotifications() {
    removeObservers()
    registerObserver(name: "com.apple.screenIsLocked") { [weak self] _ in
      self?.eventSink?("lock")
    }
    registerObserver(name: "com.apple.screenIsUnlocked") { [weak self] _ in
      self?.eventSink?("unlock")
    }
    registerObserver(name: "com.apple.screensaver.didstart") { [weak self] _ in
      self?.screensaverRunning = true
      self?.eventSink?("screensaverStart")
    }
    registerObserver(name: "com.apple.screensaver.didstop") { [weak self] _ in
      self?.screensaverRunning = false
      self?.eventSink?("screensaverStop")
    }
  }

  private func registerObserver(
    name: String, handler: @escaping (Notification) -> Void
  ) {
    let token = notificationCenter.addObserver(
      forName: Notification.Name(name),
      object: nil,
      suspensionBehavior: .deliverImmediately,
      queue: .main,
      using: handler
    )
    observerTokens.append(token)
  }

  private func removeObservers() {
    for token in observerTokens {
      notificationCenter.removeObserver(token)
    }
    observerTokens.removeAll()
  }

  // MARK: - Presence read

  /// Reads the current lock/idle state. Never throws; on failure the result
  /// reports `locked=true` and `degraded=true` so the Dart side degrades
  /// loudly instead of ringing an alert on a possibly hidden screen.
  private func readPresence() -> [String: Any] {
    var locked = false
    var degraded = false

    if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
      let onConsole =
        (session["kCGSSessionOnConsoleKey"] as? NSNumber)?.boolValue ?? false
      if let screenIsLocked = session["CGSSessionScreenIsLocked"] as? NSNumber {
        locked = !onConsole || screenIsLocked.boolValue
      } else {
        // The undocumented key is absent on this OS version: fall back to
        // the console + screensaver signals and report the degradation.
        locked = !onConsole
        degraded = true
      }
    } else {
      // Cannot read the session dictionary at all: treat as locked rather
      // than risk a hidden alert.
      locked = true
      degraded = true
    }

    if screensaverRunning {
      locked = true
    }

    let idleSeconds = CGEventSourceSecondsSinceLastEventType(
      CGEventSourceStateID.combinedSessionState,
      // kCGAnyInputEventType == ((CGEventType)(~0)).
      CGEventType(rawValue: UInt32.max)
    )

    return [
      "locked": locked,
      "idleSeconds": max(idleSeconds, 0),
      "degraded": degraded,
      "mechanism": "cgssession",
    ]
  }
}
