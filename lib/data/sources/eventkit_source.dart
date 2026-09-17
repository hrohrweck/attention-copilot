/// EventKit calendar source (macOS), backed by the native `EventKitPlugin`
/// (`macos/Runner/EventKitPlugin.swift`).
///
/// Permission model: both a declined grant and a never-answered prompt surface
/// as `permission-denied` (the orchestrator records
/// `SourceStatusKind.permissionDenied`, never a generic error), and are told
/// apart through [checkAuthorization] (`.denied` vs `.notDetermined`) and the
/// thrown exception message (`permission-denied:` vs `needs-permission:`), so
/// the UI can choose between "open settings" and "connect".
///
/// Conference heuristic: the native plugin transmits `conferenceUrl` (from the
/// EventKit `URL` property, else the first recognised meeting-provider link in
/// notes or location — raw notes never leave the plugin). This side maps it to
/// a [MeetingJoinInfo] and, as a fallback, scans the `location` field for a
/// recognised provider link on its own.
///
/// Sync: EventKit is a local full read — the fetch cursor is intentionally
/// unused and [SourceSnapshot.nextCursor] is always `null`. The plugin pushes
/// `EKEventStoreChanged` over an event channel; subscribe to [externalChanges]
/// to trigger an out-of-band refresh instead of waiting for the next poll.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import '../../domain/models/calendar_event.dart';
import '../../domain/models/calendar_source_id.dart';
import '../../domain/models/event_occurrence.dart';
import '../../domain/models/meeting_join_info.dart';
import 'source.dart';

const String kEventKitMethodChannel = 'attention_copilot/eventkit';
const String kEventKitEventChannel = 'attention_copilot/eventkit_events';

/// Native EventKit authorization postures as reported by the plugin.
enum EventKitAuthorization {
  /// The full-access prompt has never been answered.
  notDetermined,

  /// Read access is granted (full access on macOS 14+; a granted legacy
  /// read on macOS 12/13 is reported by the plugin as `fullAccess` too).
  granted,

  /// Only write access was granted (macOS 14+ split access).
  writeOnly,

  /// The user declined calendar access.
  denied,

  /// The OS restricted calendar access (e.g. parental controls).
  restricted,

  /// The request API is unavailable on this OS (macOS < 14).
  unsupported,

  /// The plugin answered with an unrecognised status.
  unknown;

  /// Maps the plugin's native status string to a posture.
  static EventKitAuthorization fromNative(String? value) => switch (value) {
    'notDetermined' => EventKitAuthorization.notDetermined,
    'fullAccess' || 'authorized' => EventKitAuthorization.granted,
    'writeOnly' => EventKitAuthorization.writeOnly,
    'denied' => EventKitAuthorization.denied,
    'restricted' => EventKitAuthorization.restricted,
    'unsupported' => EventKitAuthorization.unsupported,
    _ => EventKitAuthorization.unknown,
  };
}

/// Meeting providers recognised by the conference-link heuristic, keyed by a
/// host fragment. Keep in sync with the native plugin's `provider(for:)`.
const Map<String, String> _kMeetingProviders = {
  'zoom.us': 'zoom',
  'meet.google.com': 'google_meet',
  'teams.microsoft.com': 'teams',
  'teams.live.com': 'teams',
  'webex.com': 'webex',
};

/// Candidate URL inside free text, stopping at whitespace or an angle
/// bracket. Trailing punctuation is stripped after the match.
final RegExp _kUrlPattern = RegExp(r"https?://[^\s<>]+");

/// [CalendarSource] over the macOS system calendar (EventKit).
///
/// macOS-only: on other platforms every call hits a missing plugin, which is
/// reported as a `permission-denied`-style failure rather than a generic one.
class EventKitSource extends CalendarSource {
  EventKitSource({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    CalendarSourceId? sourceId,
  }) : _methodChannel =
           methodChannel ?? const MethodChannel(kEventKitMethodChannel),
       _eventChannel =
           eventChannel ?? const EventChannel(kEventKitEventChannel),
       sourceId =
           sourceId ??
           const CalendarSourceId(
             id: 'eventkit',
             displayName: 'macOS Calendar',
             priority: 0,
           );

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;

  @override
  final CalendarSourceId sourceId;

  /// Fetch window: from the local start of today. The agenda only renders the
  /// current day, but a two-week window keeps recurring expansions and
  /// recently ended meetings present without re-reading the store on every
  /// refresh (EventKit is a full read; see the class docs).
  static const Duration fetchWindow = Duration(days: 14);

  /// Last native status string, or `null` until the first native check
  /// completes.
  String? _lastAuthorizationStatus;

  Stream<String>? _externalChanges;

  @override
  bool get needsAuthentication => false;

  /// Last-known permission posture.
  ///
  /// Only a confirmed `denied`/`restricted` reports
  /// [SourcePermissionState.denied] (which makes the orchestrator skip the
  /// fetch). Everything else — including the unknown initial state and a
  /// not-yet-answered prompt — reports `granted` so the fetch runs and the
  /// native side surfaces the truth as a [SourcePermissionDeniedException]
  /// instead of a silently empty agenda.
  @override
  SourcePermissionState get permissionState {
    switch (_lastAuthorizationStatus) {
      case 'denied' || 'restricted':
        return SourcePermissionState.denied;
      default:
        return SourcePermissionState.granted;
    }
  }

  /// Stream of native `EKEventStoreChanged` pushes (the single value
  /// `"changed"`). Subscribe to trigger an out-of-band refresh; the plugin
  /// only observes the store while this stream is listened to.
  Stream<String> get externalChanges => _externalChanges ??= _eventChannel
      .receiveBroadcastStream()
      .cast<String>();

  /// Asks the plugin for the current EventKit authorization posture and
  /// caches it for [permissionState].
  ///
  /// Throws [SourcePermissionDeniedException] on builds without the native
  /// plugin, so a non-macOS build still surfaces as actionable rather than
  /// as a generic transport error.
  Future<EventKitAuthorization> checkAuthorization() async {
    try {
      final status = await _methodChannel.invokeMethod<String>(
        'authorizationStatus',
      );
      _lastAuthorizationStatus = status;
      return EventKitAuthorization.fromNative(status);
    } on MissingPluginException {
      throw const SourcePermissionDeniedException(
        'eventkit plugin is not registered on this build',
      );
    }
  }

  /// Shows the macOS full-access prompt and reports whether read access is
  /// now granted. Updates the [permissionState] cache.
  ///
  /// On macOS < 14 the split-access prompt does not exist; the current
  /// posture is reported unchanged (see the native plugin docs).
  Future<bool> requestFullAccess() async {
    final status = await _methodChannel.invokeMethod<String>(
      'requestFullAccess',
    );
    _lastAuthorizationStatus = status;
    return EventKitAuthorization.fromNative(status) ==
        EventKitAuthorization.granted;
  }

  /// Opens the macOS calendar-privacy system settings pane.
  Future<void> openSystemSettings() =>
      _methodChannel.invokeMethod<void>('openSystemSettings');

  @override
  Future<SourceSnapshot> fetch(SourceCursor? cursor) async {
    final authorization = await checkAuthorization();
    switch (authorization) {
      case EventKitAuthorization.granted:
        break;
      case EventKitAuthorization.notDetermined:
        // Never asked yet — not a generic failure: the UI should offer the
        // request flow, not a retry.
        throw const SourcePermissionDeniedException(
          'needs-permission: calendar access has not been requested yet',
        );
      case EventKitAuthorization.denied || EventKitAuthorization.restricted:
        throw const SourcePermissionDeniedException(
          'permission-denied: calendar access was declined',
        );
      case EventKitAuthorization.writeOnly:
        throw const SourcePermissionDeniedException(
          'permission-denied: only write access was granted',
        );
      case EventKitAuthorization.unsupported:
        throw const SourcePermissionDeniedException(
          'permission-denied: the full-access prompt requires macOS 14+',
        );
      case EventKitAuthorization.unknown:
        throw StateError('eventkit reported an unknown authorization posture');
    }

    final now = DateTime.now();
    final windowStart = DateTime(now.year, now.month, now.day);
    final List<Object?> raw;
    try {
      raw =
          await _methodChannel.invokeListMethod<Object?>(
            'listOccurrences',
            <String, Object?>{
              'fromIso': windowStart.toUtc().toIso8601String(),
              'toIso': windowStart.add(fetchWindow).toUtc().toIso8601String(),
            },
          ) ??
          const <Object?>[];
    } on PlatformException catch (error) {
      if (error.code == 'permission-denied') {
        // The grant was revoked between the check and the read: report the
        // truth, never a silently empty agenda.
        _lastAuthorizationStatus = error.message;
        throw SourcePermissionDeniedException(
          'permission-denied: '
          '${error.message ?? 'calendar access was declined'}',
        );
      }
      rethrow;
    }

    final occurrences = <EventOccurrence>[];
    for (final entry in raw) {
      if (entry is! Map) {
        throw const FormatException(
          'eventkit returned a non-map occurrence entry',
        );
      }
      occurrences.add(_occurrenceFrom(Map<String, Object?>.from(entry)));
    }
    return SourceSnapshot(occurrences: List.unmodifiable(occurrences));
  }

  EventOccurrence _occurrenceFrom(Map<String, Object?> json) {
    final instanceId = json['id'] as String? ?? '';
    final masterId = json['calendarItemIdentifier'] as String? ?? instanceId;
    final eventTitle = json['title'] as String? ?? '';
    final calendarTitle = json['calendarTitle'] as String? ?? '';
    final start = _parseUtc(json['start']);
    final end = _parseUtc(json['end']);
    if (start == null || end == null) {
      throw FormatException('eventkit occurrence lacks start/end: $json');
    }
    return EventOccurrence(
      id: instanceId,
      event: CalendarEvent(
        id: masterId,
        // Some system events (e.g. subscribed holidays) carry no title; fall
        // back to the calendar title so the agenda never renders a blank line.
        title: eventTitle.isNotEmpty ? eventTitle : calendarTitle,
        location: json['location'] as String?,
        originalTimezoneId: json['timeZone'] as String?,
        joinInfo: _joinInfoFrom(json),
      ),
      source: sourceId,
      startUtc: start,
      endUtc: end,
      isAllDay: json['allDay'] == true,
    );
  }

  DateTime? _parseUtc(Object? value) {
    if (value is! String) {
      return null;
    }
    return DateTime.tryParse(value)?.toUtc();
  }

  MeetingJoinInfo? _joinInfoFrom(Map<String, Object?> json) {
    final conferenceUrl = json['conferenceUrl'] as String?;
    if (conferenceUrl != null && conferenceUrl.isNotEmpty) {
      return MeetingJoinInfo(
        url: conferenceUrl,
        provider:
            (json['conferenceProvider'] as String?) ??
            providerForUrl(conferenceUrl),
      );
    }
    // Fallback heuristic: a recognised meeting-provider link hidden in the
    // location text. Notes never reach this side (see the class docs), so
    // the native plugin scans them.
    return meetingLinkFromText(json['location'] as String?);
  }
}

/// Labels a URL with its meeting provider, or `null` when the host is not a
/// recognised provider. Exposed for tests and reused by [meetingLinkFromText].
String? providerForUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) {
    return null;
  }
  final host = uri.host.toLowerCase();
  for (final MapEntry(key: fragment, value: provider)
      in _kMeetingProviders.entries) {
    if (host.contains(fragment)) {
      return provider;
    }
  }
  return null;
}

/// The first recognised meeting-provider link found in [text], or `null`.
MeetingJoinInfo? meetingLinkFromText(String? text) {
  if (text == null || text.isEmpty) {
    return null;
  }
  for (final match in _kUrlPattern.allMatches(text)) {
    final rawUrl = match.group(0);
    if (rawUrl == null) {
      continue;
    }
    final url = rawUrl.replaceFirst(RegExp(r'[)\],.;:]+$'), '');
    final provider = providerForUrl(url);
    if (provider != null) {
      return MeetingJoinInfo(url: url, provider: provider);
    }
  }
  return null;
}
