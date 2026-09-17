/// The rolling, size-capped diagnostics log.
///
/// Writes plain text lines to `diagnostics.log` inside an injected
/// [Directory] (tests inject [Directory.systemTemp]; the app injects its
/// application-support directory). When the active file would exceed
/// [maxBytes], it rotates: active -> `.1`, `.1` -> `.2`, and the oldest
/// (`.2`) is dropped.
///
/// Every line is passed through [redactSecrets] before it touches disk, so
/// OAuth tokens, Google client ids and bearer ICS URLs never reach the log.
library;

import 'dart:io';

/// Redacts secrets from a string before it is written anywhere:
///
///   * bearer ICS URLs — any URL whose query carries a secret parameter
///     (`token`, `access_token`, `refresh_token`, `key`, `auth`, `sig`,
///     `signature`, `secret`, `authz`, `jwt`) becomes `[REDACTED]`;
///   * OAuth tokens: `refresh_token=...`, `access_token=...`, `id_token=...`
///     (and the JSON-ish `"access_token": "..."` form);
///   * `Authorization: Bearer <token>` headers;
///   * Google client ids (`<digits>-<alnum>.apps.googleusercontent.com`).
///
/// Used by both [LogSink] and the diagnostics report.
String redactSecrets(String input) {
  var output = input;

  // Whole bearer URLs first, so a secret query param cannot survive even
  // partially inside an otherwise redacted URL.
  output = output.replaceAllMapped(_url, (match) {
    final url = match[0]!;
    return _secretQueryParam.hasMatch(url) ? '[REDACTED]' : url;
  });

  output = output.replaceAllMapped(
    _oauthToken,
    (match) => '${match[1]}=[REDACTED]',
  );

  output = output.replaceAllMapped(
    _bearerHeader,
    (match) => '${match[1]}[REDACTED]',
  );

  output = output.replaceAllMapped(_googleClientId, (_) => '[REDACTED]');

  return output;
}

final RegExp _url = RegExp(r'''https?://[^\s"'<>]+''');

final RegExp _secretQueryParam = RegExp(
  r'[?&](token|access_token|refresh_token|key|auth|sig|signature|secret|authz|jwt)=',
  caseSensitive: false,
);

final RegExp _oauthToken = RegExp(
  r'(refresh_token|access_token|id_token)\s*[:=]\s*[^\s&",;]+',
  caseSensitive: false,
);

final RegExp _bearerHeader = RegExp(
  r'(authorization\s*:\s*bearer\s+)[^\s,;]+',
  caseSensitive: false,
);

final RegExp _googleClientId = RegExp(r'\d+-\w+\.apps\.googleusercontent\.com');

/// A rolling, size-capped, redacting log sink.
///
/// Rotation is strictly bounded: a line is only ever appended when
/// `current size + line length <= maxBytes`, so every file on disk stays at
/// or under the cap. At most [maxRotations] archived files exist
/// (`diagnostics.log.N`), oldest dropped first.
class LogSink {
  LogSink({
    required this.directory,
    this.fileName = 'diagnostics.log',
    this.maxBytes = 256 * 1024,
    this.maxRotations = 2,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Where the log files live. Created on first write if missing.
  final Directory directory;

  /// Base file name; archived copies are `$fileName.1`, `$fileName.2`, ...
  final String fileName;

  /// Size cap in bytes for every file (active and archived).
  final int maxBytes;

  /// How many archived files to keep (`.1` .. `.$maxRotations`).
  final int maxRotations;

  final DateTime Function() _clock;

  File get _active => File('${directory.path}/$fileName');

  File _rotated(int n) => File('${directory.path}/$fileName.$n');

  /// Appends one redacted, timestamped line, rotating first when the line
  /// would push the active file over [maxBytes].
  void write(String message) {
    final line = '[${_clock().toUtc().toIso8601String()}] '
        '${redactSecrets(message)}\n';
    _rotateIfNeeded(line.length);
    final active = _active;
    active.parent.createSync(recursive: true);
    if (active.existsSync()) {
      active.writeAsStringSync(line, mode: FileMode.append);
    } else {
      active.writeAsStringSync(line);
    }
  }

  void _rotateIfNeeded(int incomingLength) {
    final current = _active.existsSync() ? _active.lengthSync() : 0;
    if (current + incomingLength <= maxBytes) return;

    // Shift the archive: drop the oldest, then move each file one slot up.
    for (var n = maxRotations; n >= 1; n--) {
      final file = _rotated(n);
      if (n == maxRotations) {
        if (file.existsSync()) file.deleteSync();
      } else if (file.existsSync()) {
        file.renameSync(_rotated(n + 1).path);
      }
    }
    if (_active.existsSync()) {
      _active.renameSync(_rotated(1).path);
    }
  }
}
