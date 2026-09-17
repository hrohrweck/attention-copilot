import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:oauth2/oauth2.dart' as oauth2;

import '../../domain/models/calendar_event.dart';
import '../../domain/models/calendar_source_id.dart';
import '../../domain/models/event_occurrence.dart';
import '../../domain/models/meeting_join_info.dart';
import '../storage/secret_store.dart';
import 'source.dart';

/// Thrown when the Google OAuth credentials are missing or can no longer be
/// refreshed: the user must re-authorise (reconnect) this source. The UI
/// surfaces the message verbatim and offers the reconnect action instead of a
/// pointless retry.
class GoogleAuthorizationException implements Exception {
  const GoogleAuthorizationException(this.message);

  final String message;

  @override
  String toString() => 'GoogleAuthorizationException: $message';
}

/// Thrown when `events.list` fails for any reason other than the specific
/// recoverable ones ([_UnauthorizedException], [_InvalidSyncTokenException]).
class GoogleCalendarApiException implements Exception {
  const GoogleCalendarApiException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'GoogleCalendarApiException($statusCode): $message';
}

/// Internal: the API answered 401, so the access token is stale.
class _UnauthorizedException implements Exception {
  const _UnauthorizedException();
}

/// Internal: the API answered 410, so the sync token is no longer valid and
/// Google requires a full wipe plus a new full sync.
class _InvalidSyncTokenException implements Exception {
  const _InvalidSyncTokenException();
}

/// Read-only Google Calendar source over the REST v3 API, authenticated with a
/// **user-supplied** OAuth client via the Authorization Code + PKCE loopback
/// flow (RFC 8252 / [Google's native-app guidance][]).
///
/// The client id is a constructor parameter (bring-your-own): this app ships
/// no client id and no client secret. The token exchange is a PKCE public
/// client - `code_verifier` in, no `client_secret` ever.
///
/// Incremental sync: the first fetch is a full `events.list` over the agenda
/// window and every page's `nextSyncToken` becomes the next [SourceCursor].
/// Subsequent fetches send only the `syncToken`; a `410 GONE` (invalidated
/// token) triggers exactly one full resync and replaces the cursor. A `401`
/// refreshes the access token and retries once; if that still fails, a
/// [GoogleAuthorizationException] telling the user to reconnect is thrown.
///
/// **Desktop only.** Google blocks loopback redirects for Android clients
/// (all pre-existing ones since 2022-10-21), so on Android Google calendars
/// are read through CalendarContract instead. Do not wire this source on
/// Android.
///
/// [Google's native-app guidance]: https://developers.google.com/identity/protocols/oauth2/native-app
class GoogleCalendarSource extends CalendarSource {
  GoogleCalendarSource({
    required this.clientId,
    required this.calendarId,
    required this.secretStore,
    http.Client? httpClient,
    Future<void> Function(Uri authorizationUrl)? openBrowser,
    DateTime Function()? clock,
    this.agendaWindow = const Duration(days: 30),
    String displayName = 'Google Calendar',
    int priority = 20,
  })  : _httpClient = httpClient ?? http.Client(),
        _openBrowser = openBrowser ?? _openInSystemBrowser,
        _clock = clock ?? DateTime.now,
        sourceId = CalendarSourceId(
          id: 'google:$calendarId',
          displayName: displayName,
          priority: priority,
        );

  /// OAuth 2.0 endpoints.
  static final Uri authorizationEndpoint =
      Uri.parse('https://accounts.google.com/o/oauth2/v2/auth');
  static final Uri tokenEndpoint =
      Uri.parse('https://oauth2.googleapis.com/token');

  /// Narrowest scopes that cover reading: no write access, never the broad
  /// `calendar.readonly` scope.
  static const List<String> scopes = [
    'https://www.googleapis.com/auth/calendar.events.readonly',
    'https://www.googleapis.com/auth/calendar.calendarlist.readonly',
  ];

  /// User-supplied OAuth client id (BYO). Never embedded in this app.
  final String clientId;

  /// Google calendar id (`primary`, an email address, or a raw id).
  final String calendarId;

  /// Token backend seam: access + refresh tokens live in the platform
  /// keychain, never in plaintext storage.
  final SecretStore secretStore;

  /// Rolling agenda window fetched on a full sync: `timeMin` is now and
  /// `timeMax` is now + [agendaWindow].
  final Duration agendaWindow;

  @override
  final CalendarSourceId sourceId;

  final http.Client _httpClient;
  final Future<void> Function(Uri authorizationUrl) _openBrowser;
  final DateTime Function() _clock;

  /// Cached knowledge that credentials exist; drives [permissionState]
  /// (which is synchronous, while the store is async).
  bool _hasCredentials = false;

  @override
  bool get needsAuthentication => true;

  @override
  SourcePermissionState get permissionState => _hasCredentials
      ? SourcePermissionState.granted
      : SourcePermissionState.notRequired;

  /// Runs the interactive Authorization Code + PKCE loopback flow:
  ///
  ///  1. binds an [HttpServer] to `127.0.0.1` on an ephemeral port,
  ///  2. builds the authorization URL with `code_challenge`/`S256` (via the
  ///     [oauth2.AuthorizationCodeGrant] primitives) and opens the system
  ///     browser on it,
  ///  3. captures the redirect (code or error) on the loopback,
  ///  4. exchanges the code at [tokenEndpoint] as a **public client** (no
  ///     client secret) and stores access + refresh tokens via [SecretStore].
  ///
  /// Throws [GoogleAuthorizationException] when the user denies or the flow
  /// times out; [FormatException]/[oauth2.AuthorizationException] for a
  /// malformed authorization response.
  Future<void> authenticate({Duration timeout = const Duration(minutes: 5)}) {
    return _runAuthorizationFlow(timeout: timeout);
  }

  Future<void> _runAuthorizationFlow({required Duration timeout}) async {
    // Public client: no secret, PKCE verifier generated by the grant.
    final grant = oauth2.AuthorizationCodeGrant(
      clientId,
      authorizationEndpoint,
      tokenEndpoint,
      httpClient: _httpClient,
    );

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final redirect = Uri.parse('http://127.0.0.1:${server.port}/callback');
      final authorizationUrl =
          grant.getAuthorizationUrl(redirect, scopes: scopes);

      // Not awaited: browser launchers (and test doubles that complete the
      // redirect) may only return once the loopback has answered. The first
      // listener is attached below; the request is buffered until then.
      unawaited(_openBrowser(authorizationUrl));

      final request = await server.first.timeout(timeout);
      final params = request.uri.queryParameters;
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write(_landingPageHtml);
      await request.response.close();

      final error = params['error'];
      if (error != null) {
        throw GoogleAuthorizationException(
          'Google authorization was not completed: $error. '
          'Reconnect the calendar source in settings to try again.',
        );
      }

      final client = await grant.handleAuthorizationResponse(params);
      final credentials = client.credentials;
      await secretStore.saveAccessToken(credentials.accessToken);
      final refreshToken = credentials.refreshToken;
      if (refreshToken != null) {
        await secretStore.saveRefreshToken(refreshToken);
      }
      _hasCredentials = true;
    } on TimeoutException {
      throw const GoogleAuthorizationException(
        'Google authorization timed out. '
        'Reconnect the calendar source in settings to try again.',
      );
    } on oauth2.AuthorizationException catch (error) {
      throw GoogleAuthorizationException(
        'Google authorization failed: ${error.description ?? error.error}.',
      );
    } finally {
      await server.close(force: true);
    }
  }

  @override
  Future<SourceSnapshot> fetch(SourceCursor? cursor) async {
    final accessToken = await secretStore.readAccessToken();
    if (accessToken == null) {
      throw const SourcePermissionDeniedException(
        'Google Calendar source is not authorised yet: reconnect it in '
        'settings to run the sign-in flow.',
      );
    }
    try {
      final snapshot = await _fetchWithAccessToken(accessToken, cursor);
      _hasCredentials = true;
      return snapshot;
    } on _UnauthorizedException {
      final refreshed = await _refreshAccessToken();
      if (refreshed == null) {
        throw const GoogleAuthorizationException(
          'Google authorisation expired - reconnect the calendar source in '
          'settings.',
        );
      }
      try {
        return await _fetchWithAccessToken(refreshed, cursor);
      } on _UnauthorizedException {
        // One refresh-and-retry, then stop: a second 401 means the grants
        // themselves are gone, and only the user can fix that.
        throw const GoogleAuthorizationException(
          'Google authorisation expired - reconnect the calendar source in '
          'settings.',
        );
      }
    }
  }

  /// One events.list sync with [accessToken]. A 410 on an incremental sync is
  /// answered with exactly one full resync (the cursor is dropped: the full
  /// fetch starts from scratch and its fresh `nextSyncToken` replaces it).
  Future<SourceSnapshot> _fetchWithAccessToken(
    String accessToken,
    SourceCursor? cursor,
  ) async {
    final syncToken = cursor?.value as String?;
    if (syncToken != null) {
      try {
        return await _fetchPages(accessToken, syncToken: syncToken);
      } on _InvalidSyncTokenException {
        // HTTP 410 GONE: Google invalidated the sync token and requires a
        // full wipe of the client's store plus a new full sync.
        return _fetchPages(accessToken, syncToken: null);
      }
    }
    return _fetchPages(accessToken, syncToken: null);
  }

  /// Pages through `events.list`, following `nextPageToken`, and returns the
  /// merged occurrences plus the last page's `nextSyncToken` as the cursor.
  Future<SourceSnapshot> _fetchPages(
    String accessToken, {
    required String? syncToken,
  }) async {
    final occurrences = <EventOccurrence>[];
    String? pageToken;
    String? nextSyncToken;
    while (true) {
      final response = await _httpClient.get(
        _listEventsUri(syncToken: syncToken, pageToken: pageToken),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Accept': 'application/json',
        },
      );
      if (response.statusCode == 401) {
        throw const _UnauthorizedException();
      }
      if (response.statusCode == 410) {
        throw const _InvalidSyncTokenException();
      }
      if (response.statusCode != 200) {
        throw GoogleCalendarApiException(
          response.statusCode,
          'events.list failed for calendar "$calendarId"',
        );
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      for (final item in (body['items'] as List<dynamic>? ?? const [])) {
        if (item is! Map<String, dynamic>) {
          continue;
        }
        final occurrence = _parseOccurrence(item);
        if (occurrence != null) {
          occurrences.add(occurrence);
        }
      }
      pageToken = body['nextPageToken'] as String?;
      final token = body['nextSyncToken'] as String?;
      if (token != null) {
        // Google only returns nextSyncToken on the final page; keeping the
        // last one seen means a stray token on an earlier page can never win.
        nextSyncToken = token;
      }
      if (pageToken == null) {
        break;
      }
    }
    return SourceSnapshot(
      occurrences: occurrences,
      nextCursor: nextSyncToken == null ? null : SourceCursor(nextSyncToken),
    );
  }

  /// events.list URL for one page.
  ///
  /// Constraints (Google rejects the request with 400 otherwise):
  ///  * `orderBy=startTime` requires `singleEvents=true`;
  ///  * `syncToken` must never be combined with `timeMin`/`timeMax`/`orderBy`;
  ///  * `pageToken` is allowed in both modes.
  /// `conferenceDataVersion=1` asks for `conferenceData` (the Meet entry
  /// point) in the response.
  Uri _listEventsUri({String? syncToken, String? pageToken}) {
    final query = <String, String>{
      'singleEvents': 'true',
      'maxResults': '250',
      'conferenceDataVersion': '1',
    };
    if (syncToken != null) {
      query['syncToken'] = syncToken;
    } else {
      query['orderBy'] = 'startTime';
      final timeMin = _clock().toUtc();
      query['timeMin'] = timeMin.toIso8601String();
      query['timeMax'] = timeMin.add(agendaWindow).toIso8601String();
    }
    if (pageToken != null) {
      query['pageToken'] = pageToken;
    }
    return Uri.https(
      'www.googleapis.com',
      '/calendar/v3/calendars/${Uri.encodeComponent(calendarId)}/events',
      query,
    );
  }

  /// Refreshes the access token with the stored refresh token.
  ///
  /// Returns the new access token, or `null` when there is no refresh token
  /// or the refresh was rejected (in which case the stored credentials are
  /// cleared so the next fetch surfaces the reconnect state cleanly).
  Future<String?> _refreshAccessToken() async {
    final refreshToken = await secretStore.readRefreshToken();
    if (refreshToken == null) {
      return null;
    }
    final response = await _httpClient.post(
      tokenEndpoint,
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        'client_id': clientId,
      },
    );
    if (response.statusCode != 200) {
      await secretStore.clearAuth();
      return null;
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final accessToken = body['access_token'] as String?;
    if (accessToken == null) {
      await secretStore.clearAuth();
      return null;
    }
    await secretStore.saveAccessToken(accessToken);
    final rotated = body['refresh_token'] as String?;
    if (rotated != null) {
      await secretStore.saveRefreshToken(rotated);
    }
    return accessToken;
  }

  EventOccurrence? _parseOccurrence(Map<String, dynamic> item) {
    if (item['status'] == 'cancelled') {
      return null;
    }
    final id = item['id'] as String?;
    final start = item['start'];
    final end = item['end'];
    if (id == null ||
        start is! Map<String, dynamic> ||
        end is! Map<String, dynamic>) {
      return null;
    }
    final startInstant = _parseInstant(start);
    final endInstant = _parseInstant(end);
    if (startInstant == null || endInstant == null) {
      return null;
    }
    final startUtc = startInstant.toUtc();
    final endUtc = endInstant.toUtc();
    if (!endUtc.isAfter(startUtc)) {
      return null;
    }
    final isAllDay = start.containsKey('date');
    return EventOccurrence(
      id: '$id::${startUtc.toIso8601String()}',
      event: CalendarEvent(
        id: id,
        title: (item['summary'] as String?) ?? '(no title)',
        location: item['location'] as String?,
        originalTimezoneId:
            (start['timeZone'] as String?) ?? (end['timeZone'] as String?),
        joinInfo: _parseJoinInfo(item),
      ),
      source: sourceId,
      startUtc: startUtc,
      endUtc: endUtc,
      isAllDay: isAllDay,
    );
  }

  /// Parses a Google `start`/`end` bound: an RFC 3339 `dateTime`, or a
  /// date-only `date` for all-day events. Google all-day events carry no
  /// timezone, so their day boundaries materialise as UTC midnight (the
  /// calendar-level timezone would need a separate calendarList call).
  DateTime? _parseInstant(Map<String, dynamic> bounds) {
    final dateTime = bounds['dateTime'] as String?;
    if (dateTime != null) {
      return DateTime.tryParse(dateTime);
    }
    final date = bounds['date'] as String?;
    if (date != null) {
      return DateTime.tryParse('${date}T00:00:00Z');
    }
    return null;
  }

  /// Maps `conferenceData.entryPoints` (video entry point first) into a
  /// [MeetingJoinInfo]; falls back to `hangoutLink` for events created before
  /// conference data existed.
  MeetingJoinInfo? _parseJoinInfo(Map<String, dynamic> item) {
    final conferenceData = item['conferenceData'];
    if (conferenceData is Map<String, dynamic>) {
      for (final raw in (conferenceData['entryPoints'] as List<dynamic>? ??
          const [])) {
        if (raw is! Map<String, dynamic>) {
          continue;
        }
        if (raw['entryPointType'] == 'video' && raw['uri'] is String) {
          final uri = raw['uri'] as String;
          return MeetingJoinInfo(
            url: uri,
            provider: uri.contains('meet.google.com') ? 'google_meet' : null,
          );
        }
      }
    }
    final hangoutLink = item['hangoutLink'] as String?;
    if (hangoutLink != null && hangoutLink.isNotEmpty) {
      return MeetingJoinInfo(url: hangoutLink, provider: 'google_meet');
    }
    return null;
  }

  /// Opens [url] in the default system browser (desktop platforms only;
  /// Google blocks loopback redirects on Android, where CalendarContract is
  /// the supported path instead).
  static Future<void> _openInSystemBrowser(Uri url) async {
    final List<String> command;
    if (Platform.isMacOS) {
      command = ['open', url.toString()];
    } else if (Platform.isLinux) {
      command = ['xdg-open', url.toString()];
    } else if (Platform.isWindows) {
      command = ['cmd', '/c', 'start', '', url.toString()];
    } else {
      throw UnsupportedError(
        'Google Calendar OAuth loopback is desktop-only (unsupported '
        'platform ${Platform.operatingSystem}); on Android read Google '
        'calendars through CalendarContract.',
      );
    }
    await Process.start(command.first, command.sublist(1),
        mode: ProcessStartMode.detached);
  }
}

const String _landingPageHtml = '''
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>Attention Copilot</title></head>
<body>
<p>Authorisation complete - you can close this window and return to
Attention Copilot.</p>
</body>
</html>
''';
