import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../domain/models/calendar_event.dart';
import '../../domain/models/calendar_source_id.dart';
import '../../domain/models/event_occurrence.dart';
import '../../domain/models/meeting_join_info.dart';
import '../ics/ics.dart';
import '../storage/agenda_cache.dart';
import '../storage/secret_store.dart';
import 'source.dart';

/// Normalises a user-supplied ICS feed URL for HTTP: the `webcal`/`webcals`
/// schemes (provisional IANA schemes, not fetchable) map to `https`; other
/// schemes pass through untouched.
Uri normalizeFeedUrl(String url) {
  final uri = Uri.parse(url);
  if (uri.scheme == 'webcal' || uri.scheme == 'webcals') {
    return uri.replace(scheme: 'https');
  }
  return uri;
}

/// Minimal HTTP seam so the source is testable against a scripted fake
/// without a network.
abstract interface class IcsHttpClient {
  Future<IcsHttpResponse> get(Uri url, {Map<String, String>? headers});
}

/// Status, body and headers of one conditional GET.
class IcsHttpResponse {
  const IcsHttpResponse({
    required this.statusCode,
    this.body = '',
    this.headers = const {},
  });

  final int statusCode;
  final String body;
  final Map<String, String> headers;

  /// Case-insensitive header lookup.
  String? header(String name) {
    final lower = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == lower) {
        return entry.value;
      }
    }
    return null;
  }
}

/// Production HTTP adapter over `package:http`.
class HttpIcsClient implements IcsHttpClient {
  HttpIcsClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  @override
  Future<IcsHttpResponse> get(Uri url, {Map<String, String>? headers}) async {
    final response = await _client.get(url, headers: headers);
    return IcsHttpResponse(
      statusCode: response.statusCode,
      body: response.body,
      headers: response.headers,
    );
  }
}

/// Logging seam: the bearer URL must never reach a log line, so the source
/// logs only its stable hashed identity plus status metadata.
typedef IcsLogSink = void Function(String message);

void _defaultLogSink(String message) => debugPrint(message);

/// Incremental-sync cursor for an ICS feed: the content hash of the last
/// parsed body (so a 200 that repeats the previous body causes no reparse and
/// no event churn) plus the HTTP cache validators for conditional requests.
///
/// Immutable value type with structural equality; never contains the feed
/// URL itself - the bearer URL lives in [SecretStore].
class IcsSourceCursor {
  const IcsSourceCursor({this.contentHash, this.etag, this.lastModified});

  factory IcsSourceCursor.fromJson(Map<String, dynamic> json) {
    return IcsSourceCursor(
      contentHash:
          json['contentHash'] is String ? json['contentHash'] as String : null,
      etag: json['etag'] is String ? json['etag'] as String : null,
      lastModified: json['lastModified'] is String
          ? json['lastModified'] as String
          : null,
    );
  }

  /// Wraps a cursor restored from the agenda cache (which only persists the
  /// HTTP validators); the content hash is an in-memory optimisation and is
  /// rebuilt on the next fetch.
  factory IcsSourceCursor.fromAgendaCursor(AgendaSourceCursor cursor) {
    return IcsSourceCursor(
      etag: cursor.etag,
      lastModified: cursor.lastModified,
    );
  }

  /// SHA-256-style digest (FNV-1a 64) of the last parsed body; null when
  /// nothing has been parsed yet.
  final String? contentHash;

  final String? etag;
  final String? lastModified;

  bool get isEmpty => contentHash == null && etag == null && lastModified == null;

  /// The persisted agenda-cache shape: HTTP validators only, never the URL.
  AgendaSourceCursor toAgendaCursor() =>
      AgendaSourceCursor(etag: etag, lastModified: lastModified);

  Map<String, dynamic> toJson() => {
        if (contentHash != null) 'contentHash': contentHash,
        if (etag != null) 'etag': etag,
        if (lastModified != null) 'lastModified': lastModified,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is IcsSourceCursor &&
          other.contentHash == contentHash &&
          other.etag == etag &&
          other.lastModified == lastModified;

  @override
  int get hashCode => Object.hash(contentHash, etag, lastModified);

  @override
  String toString() =>
      'IcsSourceCursor(hash: $contentHash, etag: $etag, '
      'lastModified: $lastModified)';
}

/// Read-only calendar source for a user-supplied ICS/`webcal` URL.
///
/// Conditional requests (`If-None-Match` / `If-Modified-Since`) make the
/// common case a `304` with no reparse and no event churn; when the server
/// ignores the validators and returns the body anyway, the content hash still
/// suppresses a redundant reparse. The bearer URL (which may embed an
/// authentication parameter, as with Google's "secret address in iCal
/// format") is persisted through the [SecretStore] seam and never logged.
class IcsSource extends CalendarSource {
  IcsSource({
    required String url,
    SecretStore? secretStore,
    IcsHttpClient? httpClient,
    IcsParser? parser,
    DateTime Function()? clock,
    this.lookAhead = const Duration(hours: 24),
    double Function()? jitter,
    this.jitterFraction = 1.0,
    IcsLogSink? logger,
  })  : assert(jitterFraction >= 0),
        _feedUri = normalizeFeedUrl(url),
        _secretStore = secretStore ?? SecretStore(),
        _httpClient = httpClient ?? HttpIcsClient(),
        _parser = parser ?? IcsParser(),
        _clock = clock ?? DateTime.now,
        _jitter = jitter ?? (() => math.Random().nextDouble()),
        _log = logger ?? _defaultLogSink,
        _displayName =
            (normalizeFeedUrl(url).host.isEmpty ? 'ICS calendar' : normalizeFeedUrl(url).host),
        _sourceKey = 'ics:${_fnv1a64(normalizeFeedUrl(url).toString())}';

  final Uri _feedUri;
  final SecretStore _secretStore;
  final IcsHttpClient _httpClient;
  final IcsParser _parser;
  final DateTime Function() _clock;
  final double Function() _jitter;
  final IcsLogSink _log;
  final String _sourceKey;
  final String _displayName;

  /// Agenda window length fetched ahead of "now" on every refresh.
  final Duration lookAhead;

  /// Jitter multiplier applied to [nextPollInterval]: the cadence is scaled
  /// by `1 + jitterFraction * jitter()` (RFC 7986 §7 suggests 1.0-2.0).
  final double jitterFraction;

  Duration _pollInterval = kDefaultPollInterval;

  @override
  CalendarSourceId get sourceId =>
      CalendarSourceId(id: _sourceKey, displayName: _displayName);

  @override
  SourcePermissionState get permissionState => SourcePermissionState.notRequired;

  /// The feed-advertised cadence (REFRESH-INTERVAL, else X-PUBLISHED-TTL,
  /// else 30 minutes), already clamped to the 15-minute floor by the parser.
  /// Before the first successful parse this is the 30-minute default.
  Duration get pollInterval => _pollInterval;

  /// The cadence to actually use for the next poll: [pollInterval] scaled up
  /// by jitter, never below the clamped base.
  Duration get nextPollInterval {
    final raw = _jitter();
    final value = raw.isNaN ? 0.0 : raw.clamp(0.0, 1.0).toDouble();
    return _pollInterval * (1 + jitterFraction * value);
  }

  @override
  Future<SourceSnapshot> fetch(SourceCursor? cursor) async {
    await _persistBearerUrl();
    final previous = _cursorOf(cursor);
    final headers = <String, String>{'accept': 'text/calendar'};
    if (previous?.etag != null) {
      headers['if-none-match'] = previous!.etag!;
    }
    if (previous?.lastModified != null) {
      headers['if-modified-since'] = previous!.lastModified!;
    }

    final response = await _httpClient.get(_feedUri, headers: headers);

    if (response.statusCode == 304) {
      _log('ics source $_sourceKey: not modified (304), no reparse');
      return SourceSnapshot(
        occurrences: const [],
        nextCursor: previous == null ? null : SourceCursor(previous),
      );
    }
    if (response.statusCode != 200) {
      throw Exception(
        'ics source $_sourceKey: unexpected HTTP ${response.statusCode}',
      );
    }

    final body = response.body;
    final hash = _fnv1a64(body);
    if (previous?.contentHash != null && previous!.contentHash == hash) {
      // Server ignored the validators but the body is byte-identical:
      // keep the validators fresh and skip the parse entirely.
      _log('ics source $_sourceKey: content unchanged, no reparse');
      final unchangedCursor = IcsSourceCursor(
        contentHash: hash,
        etag: response.header('etag') ?? previous.etag,
        lastModified: response.header('last-modified') ?? previous.lastModified,
      );
      return SourceSnapshot(
        occurrences: const [],
        nextCursor: SourceCursor(unchangedCursor),
      );
    }

    final calendar = _parser.parse(body);
    _pollInterval = calendar.pollInterval;
    final conferenceByUid = _googleConferenceUris(body);
    final windowStart = _clock().toUtc();
    final occurrences = <EventOccurrence>[];
    for (final occurrence in calendar.expandOccurrences(
      windowStart,
      windowStart.add(lookAhead),
    )) {
      occurrences.add(
        _toOccurrence(occurrence, conferenceByUid[occurrence.uid]),
      );
    }
    _log('ics source $_sourceKey: parsed ${occurrences.length} occurrences, '
        'poll interval ${_pollInterval.inMinutes} min');

    final nextCursor = IcsSourceCursor(
      contentHash: hash,
      etag: response.header('etag'),
      lastModified: response.header('last-modified'),
    );
    return SourceSnapshot(
      occurrences: occurrences,
      nextCursor: SourceCursor(nextCursor),
    );
  }

  /// Persists the configured URL into the [SecretStore] seam (so it never
  /// rests in plaintext settings) and returns it for fetching.
  Future<void> _persistBearerUrl() async {
    final target = _feedUri.toString();
    final stored = await _secretStore.readIcsBearerUrl();
    if (stored != target) {
      await _secretStore.saveIcsBearerUrl(target);
      _log('ics source $_sourceKey: bearer URL stored securely');
    }
  }

  IcsSourceCursor? _cursorOf(SourceCursor? cursor) {
    final value = cursor?.value;
    if (value == null) {
      return null;
    }
    if (value is IcsSourceCursor) {
      return value;
    }
    if (value is AgendaSourceCursor) {
      return IcsSourceCursor.fromAgendaCursor(value);
    }
    // Unknown payload (e.g. a foreign cursor): full fetch without validators.
    return null;
  }

  EventOccurrence _toOccurrence(
    IcsOccurrence occurrence,
    String? googleConference,
  ) {
    final joinInfo = _joinInfoFor(occurrence, googleConference);
    return EventOccurrence(
      id: '${occurrence.uid}@${occurrence.startUtc.toUtc().toIso8601String()}',
      event: CalendarEvent(
        id: occurrence.uid,
        title: _nonEmpty(occurrence.summary) ?? '(untitled)',
        location: occurrence.location,
        originalTimezoneId: occurrence.timezoneName,
        joinInfo: joinInfo,
      ),
      source: sourceId,
      startUtc: occurrence.startUtc,
      endUtc: occurrence.endUtc,
      isAllDay: occurrence.isAllDay,
    );
  }

  /// Join-URL heuristic: the `URL` property wins; otherwise
  /// `X-GOOGLE-CONFERENCE`; otherwise the first *recognised* meeting-provider
  /// link in LOCATION, then DESCRIPTION.
  MeetingJoinInfo? _joinInfoFor(
    IcsOccurrence occurrence,
    String? googleConference,
  ) {
    final ownUrl = _nonEmpty(occurrence.url);
    if (ownUrl != null) {
      return MeetingJoinInfo(url: ownUrl, provider: _providerFor(ownUrl));
    }
    final conference = _nonEmpty(googleConference);
    if (conference != null) {
      return MeetingJoinInfo(url: conference, provider: 'google_meet');
    }
    for (final text in [occurrence.location, occurrence.description]) {
      final candidate = _nonEmpty(text);
      if (candidate == null) {
        continue;
      }
      for (final match in _urlPattern.allMatches(candidate)) {
        final url = match.group(0)!.replaceAll(RegExp(r'[.,;]+$'), '');
        final provider = _providerFor(url);
        if (provider != null) {
          return MeetingJoinInfo(url: url, provider: provider);
        }
      }
    }
    return null;
  }

  /// Maps each VEVENT UID to its `X-GOOGLE-CONFERENCE` URI, straight from the
  /// raw body (the parser does not model that property).
  Map<String, String> _googleConferenceUris(String body) {
    final result = <String, String>{};
    String? currentUid;
    var inVevent = false;
    for (final line in unfoldIcsLines(body)) {
      final upper = line.toUpperCase();
      if (upper.startsWith('BEGIN:VEVENT')) {
        inVevent = true;
        currentUid = null;
        continue;
      }
      if (upper.startsWith('END:VEVENT')) {
        inVevent = false;
        currentUid = null;
        continue;
      }
      if (!inVevent) {
        continue;
      }
      if (upper.startsWith('UID:')) {
        currentUid = line.substring(4).trim();
        continue;
      }
      if (upper.startsWith('X-GOOGLE-CONFERENCE')) {
        final colon = line.indexOf(':');
        if (colon < 0 || currentUid == null || currentUid.isEmpty) {
          continue;
        }
        result[currentUid] = line.substring(colon + 1).trim();
      }
    }
    return result;
  }

  /// Recognised meeting providers whose links in free text (LOCATION /
  /// DESCRIPTION) are worth surfacing as a join URL.
  static final RegExp _urlPattern =
      RegExp(r'https?://[^\s<>()\x22\x27,;\[\]]+');

  String? _providerFor(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (host == 'meet.google.com' || host.endsWith('.meet.google.com')) {
      return 'google_meet';
    }
    if (host == 'zoom.us' || host.endsWith('.zoom.us')) {
      return 'zoom';
    }
    if (host == 'teams.microsoft.com' || host == 'teams.live.com') {
      return 'teams';
    }
    if (host == 'meet.jit.si') {
      return 'jitsi';
    }
    if (host == 'webex.com' || host.endsWith('.webex.com')) {
      return 'webex';
    }
    if (host == 'gotomeeting.com' || host.endsWith('.gotomeeting.com')) {
      return 'gotomeeting';
    }
    if (host == 'bluejeans.com') {
      return 'bluejeans';
    }
    if (host == 'chime.aws') {
      return 'chime';
    }
    if (host == 'whereby.com' || host.endsWith('.whereby.com')) {
      return 'whereby';
    }
    return null;
  }

  static String? _nonEmpty(String? value) {
    final trimmed = value?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }

  /// FNV-1a 64-bit digest: cheap, deterministic change detection without an
  /// extra crypto dependency. Not cryptographic - the feed is public data.
  static String _fnv1a64(String input) {
    var hash = 0xcbf29ce484222325;
    const mask = 0xFFFFFFFFFFFFFFFF;
    for (final unit in input.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x100000001b3) & mask;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}
