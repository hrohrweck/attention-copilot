import Cocoa
import EventKit
import FlutterMacOS

/// Native EventKit calendar adapter for macOS (plan todo 11).
///
/// Read-only access through the macOS 14+ split-access API. The plugin never
/// requests write access and never calls the deprecated `requestAccess(to:)`:
/// with the legacy single-access API a declined upgrade prompt silently made
/// reads return nothing (TN3153), so the plugin reports the *actual* posture
/// instead and lets the Dart side act on it.
///
/// Method channel (`attention_copilot/eventkit`):
///  * `authorizationStatus` -> String: `notDetermined`, `fullAccess`,
///    `writeOnly`, `denied`, `restricted`, `unsupported` or `unknown`.
///    `EKAuthorizationStatus` is compared by rawValue so the build never
///    references the `.authorized` symbol deprecated in macOS 14; on macOS
///    12/13 a granted legacy read is still reported as `fullAccess`.
///  * `requestFullAccess()` -> String: the authorization posture after the
///    macOS 14+ full-access prompt. On macOS 12/13, where the split-access
///    prompt does not exist, the current posture is reported unchanged.
///  * `openSystemSettings()` -> opens the macOS calendar-privacy pane.
///  * `listOccurrences(fromIso, toIso)` -> JSON occurrences (id, stable
///    calendar-item id, calendar title, title, start/end as UTC ISO-8601,
///    all-day flag, location, timezone, conference URL when present). The
///    conference URL comes from the EventKit `URL` property, else from the
///    first recognised meeting-provider link in notes or location; raw notes
///    are never transmitted. Throws a `permission-denied` platform error
///    when access is not granted — never an empty list.
///
/// Event channel (`attention_copilot/eventkit_events`): pushes `changed`
/// whenever `EKEventStoreChanged` fires, so the Dart side can refresh
/// without polling.
///
/// All-day end dates: EventKit stores the inclusive 23:59:59 end; the plugin
/// shifts it to the following midnight so the Dart side keeps its exclusive
/// end boundary invariant.
class EventKitPlugin: NSObject, FlutterStreamHandler {
  static let methodChannelName = "attention_copilot/eventkit"
  static let eventChannelName = "attention_copilot/eventkit_events"

  /// Raw `EKAuthorizationStatus` values (see the header notes above):
  /// `.fullAccess` (macOS 14+) aliases the legacy `.authorized`.
  private static let rawNotDetermined = 0
  private static let rawRestricted = 1
  private static let rawDenied = 2
  private static let rawFullAccess = 3
  private static let rawWriteOnly = 4

  private let eventStore = EKEventStore()
  private var eventSink: FlutterEventSink?
  private var changeObserverToken: NSObjectProtocol?

  private static let fractionalFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private static let plainFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = EventKitPlugin()

    let methodChannel = FlutterMethodChannel(
      name: methodChannelName, binaryMessenger: registrar.messenger)
    methodChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "authorizationStatus":
        result(instance.authorizationStatusString())
      case "requestFullAccess":
        instance.requestFullAccess(result: result)
      case "openSystemSettings":
        instance.openSystemSettings()
        result(nil)
      case "listOccurrences":
        guard let arguments = call.arguments as? [String: Any],
          let fromIso = arguments["fromIso"] as? String,
          let toIso = arguments["toIso"] as? String,
          let fromDate = EventKitPlugin.parseIso(fromIso),
          let toDate = EventKitPlugin.parseIso(toIso)
        else {
          result(
            FlutterError(
              code: "bad-arguments",
              message: "listOccurrences expects fromIso and toIso ISO-8601 strings",
              details: nil))
          return
        }
        instance.listOccurrences(from: fromDate, to: toDate, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let eventChannel = FlutterEventChannel(
      name: eventChannelName, binaryMessenger: registrar.messenger)
    eventChannel.setStreamHandler(instance)
  }

  // MARK: - FlutterStreamHandler

  func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    observeStoreChanges()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    removeStoreObserver()
    eventSink = nil
    return nil
  }

  // MARK: - EKEventStoreChanged observation

  private func observeStoreChanges() {
    guard changeObserverToken == nil else {
      return
    }
    changeObserverToken = NotificationCenter.default.addObserver(
      forName: .EKEventStoreChanged,
      object: eventStore,
      queue: .main
    ) { [weak self] _ in
      self?.eventSink?("changed")
    }
  }

  private func removeStoreObserver() {
    if let token = changeObserverToken {
      NotificationCenter.default.removeObserver(token)
      changeObserverToken = nil
    }
  }

  // MARK: - Authorization

  private func authorizationStatusString() -> String {
    switch EKEventStore.authorizationStatus(for: .event).rawValue {
    case EventKitPlugin.rawNotDetermined:
      return "notDetermined"
    case EventKitPlugin.rawRestricted:
      return "restricted"
    case EventKitPlugin.rawDenied:
      return "denied"
    case EventKitPlugin.rawFullAccess:
      return "fullAccess"
    case EventKitPlugin.rawWriteOnly:
      return "writeOnly"
    default:
      return "unknown"
    }
  }

  private func requestFullAccess(result: @escaping FlutterResult) {
    if #available(macOS 14.0, *) {
      eventStore.requestFullAccessToEvents { [weak self] _, _ in
        DispatchQueue.main.async {
          // Report the resulting posture, not the callback's `granted` flag:
          // the store is the source of truth and reflects the prompt's outcome
          // even when the callback carries an error.
          result(self?.authorizationStatusString() ?? "unknown")
        }
      }
    } else {
      // macOS 12/13: the split full-access prompt does not exist there.
      // Report the current posture unchanged; reads keep working when access
      // was granted before (e.g. by a legacy build).
      result(authorizationStatusString())
    }
  }

  private func openSystemSettings() {
    guard let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
    ) else {
      return
    }
    NSWorkspace.shared.open(url)
  }

  // MARK: - Occurrence listing

  private func listOccurrences(
    from: Date, to: Date, result: @escaping FlutterResult
  ) {
    guard EKEventStore.authorizationStatus(for: .event).rawValue
      == EventKitPlugin.rawFullAccess
    else {
      // Never an empty list when permission was declined: the Dart side maps
      // this platform error to its `permission-denied` status.
      result(
        FlutterError(
          code: "permission-denied",
          message: authorizationStatusString(),
          details: nil))
      return
    }
    let calendars = eventStore.calendars(for: .event)
    let predicate = eventStore.predicateForEvents(
      withStart: from, end: to, calendars: calendars)
    let events = eventStore.events(matching: predicate)
    result(events.map { entry(for: $0) })
  }

  private func entry(for event: EKEvent) -> [String: Any] {
    var entry: [String: Any] = [
      "id": event.eventIdentifier ?? "",
      "calendarItemIdentifier": event.calendarItemIdentifier,
      "calendarTitle": event.calendar?.title ?? "",
      "title": event.title ?? "",
      "start": EventKitPlugin.plainFormatter.string(from: event.startDate),
      "end": EventKitPlugin.plainFormatter.string(from: exclusiveEnd(for: event)),
      "allDay": event.isAllDay,
    ]
    if let location = event.location, !location.isEmpty {
      entry["location"] = location
    }
    if let timeZone = event.timeZone {
      entry["timeZone"] = timeZone.identifier
    }
    if let conference = conferenceInfo(for: event) {
      entry["conferenceUrl"] = conference.url
      entry["conferenceProvider"] = conference.provider
    }
    return entry
  }

  /// EventKit stores the all-day end as the inclusive 23:59:59 of the last
  /// day; the Dart side expects an exclusive boundary, so the end is shifted
  /// to the following midnight in the event's own timezone (DST-safe).
  private func exclusiveEnd(for event: EKEvent) -> Date {
    guard event.isAllDay else {
      return event.endDate
    }
    var calendar = Calendar(identifier: .gregorian)
    if let timeZone = event.timeZone {
      calendar.timeZone = timeZone
    }
    let lastDayStart = calendar.startOfDay(for: event.endDate)
    return calendar.date(byAdding: .day, value: 1, to: lastDayStart)
      ?? event.endDate
  }

  // MARK: - Conference link detection

  /// The meeting join point of an event: the EventKit `URL` property first,
  /// then the first recognised meeting-provider link in notes or location.
  /// Raw notes stay inside the plugin — only the extracted link is sent.
  private func conferenceInfo(for event: EKEvent) -> (url: String, provider: String)? {
    if let url = event.url {
      return (url.absoluteString, EventKitPlugin.provider(for: url) ?? "unknown")
    }
    if let link = firstMeetingLink(in: event.notes) {
      return link
    }
    return firstMeetingLink(in: event.location)
  }

  private func firstMeetingLink(in text: String?) -> (url: String, provider: String)? {
    guard let text = text, !text.isEmpty else {
      return nil
    }
    let range = NSRange(location: 0, length: text.utf16.count)
    guard let detector = try? NSDataDetector(
      types: NSTextCheckingResult.CheckingType.link.rawValue)
    else {
      return nil
    }
    for match in detector.matches(in: text, options: [], range: range) {
      guard let url = match.url, let provider = EventKitPlugin.provider(for: url) else {
        continue
      }
      return (url.absoluteString, provider)
    }
    return nil
  }

  /// Meeting provider for a URL host, or nil when it is not a recognised
  /// provider. Keep in sync with the Dart-side `_kMeetingProviders`.
  private static func provider(for url: URL) -> String? {
    let host = url.host?.lowercased() ?? ""
    if host.contains("zoom.us") {
      return "zoom"
    }
    if host.contains("meet.google.com") {
      return "google_meet"
    }
    if host.contains("teams.microsoft.com") || host.contains("teams.live.com") {
      return "teams"
    }
    if host.contains("webex.com") {
      return "webex"
    }
    return nil
  }

  // MARK: - ISO-8601 helpers

  /// Parses an ISO-8601 instant with or without fractional seconds (Dart's
  /// `toIso8601String()` always emits milliseconds).
  private static func parseIso(_ value: String) -> Date? {
    if let date = fractionalFormatter.date(from: value) {
      return date
    }
    return plainFormatter.date(from: value)
  }
}
