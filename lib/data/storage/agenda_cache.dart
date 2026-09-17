import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Incremental-sync cursor for a single calendar source. A Google source
/// carries a `syncToken`; an ICS source carries the HTTP cache validators
/// (`etag` / `lastModified`). Only the fields a source actually has are
/// serialised.
class AgendaSourceCursor {
  const AgendaSourceCursor({this.syncToken, this.etag, this.lastModified});

  factory AgendaSourceCursor.fromJson(Map<String, dynamic> json) {
    return AgendaSourceCursor(
      syncToken: json['syncToken'] is String ? json['syncToken'] as String : null,
      etag: json['etag'] is String ? json['etag'] as String : null,
      lastModified: json['lastModified'] is String
          ? json['lastModified'] as String
          : null,
    );
  }

  final String? syncToken;
  final String? etag;
  final String? lastModified;

  bool get isEmpty => syncToken == null && etag == null && lastModified == null;

  Map<String, dynamic> toJson() => {
        if (syncToken != null) 'syncToken': syncToken,
        if (etag != null) 'etag': etag,
        if (lastModified != null) 'lastModified': lastModified,
      };
}

/// The cached-agenda document: schema version, when it was fetched and the
/// per-source cursors. Plain data only - no tokens, no credentials, nothing
/// secret may ever be stored here (see SecretStore for secrets).
class AgendaCacheData {
  static const int currentSchemaVersion = 1;

  const AgendaCacheData({
    required this.schemaVersion,
    required this.fetchedAt,
    required this.cursors,
    this.unknown = const {},
  });

  const AgendaCacheData.empty()
      : schemaVersion = currentSchemaVersion,
        fetchedAt = null,
        cursors = const {},
        unknown = const {};

  factory AgendaCacheData.fromJson(Map<String, dynamic> json) {
    final cursors = <String, AgendaSourceCursor>{};
    final cursorsRaw = json['cursors'];
    if (cursorsRaw is Map<String, dynamic>) {
      for (final entry in cursorsRaw.entries) {
        if (entry.value is Map<String, dynamic>) {
          cursors[entry.key] =
              AgendaSourceCursor.fromJson(entry.value as Map<String, dynamic>);
        }
      }
    }
    final fetchedRaw = json['fetchedAt'];
    return AgendaCacheData(
      schemaVersion: currentSchemaVersion,
      fetchedAt:
          fetchedRaw is String ? DateTime.tryParse(fetchedRaw) : null,
      cursors: cursors,
      unknown: _unknownKeys(json),
    );
  }

  final int schemaVersion;

  /// Instant of the last successful fetch, UTC, or null when never fetched.
  final DateTime? fetchedAt;

  /// Cursors keyed by a stable source identifier
  /// (e.g. `google:primary`, `ics:<url-hash>`).
  final Map<String, AgendaSourceCursor> cursors;

  /// Unknown top-level keys from the stored document, preserved on rewrite.
  final Map<String, dynamic> unknown;

  Map<String, dynamic> toJson() => {
        ...unknown,
        'schemaVersion': currentSchemaVersion,
        if (fetchedAt != null) 'fetchedAt': fetchedAt!.toUtc().toIso8601String(),
        'cursors': {
          for (final entry in cursors.entries) entry.key: entry.value.toJson(),
        },
      };

  static Map<String, dynamic> _unknownKeys(Map<String, dynamic> json) {
    const known = {'schemaVersion', 'fetchedAt', 'cursors'};
    return {
      for (final entry in json.entries)
        if (!known.contains(entry.key)) entry.key: entry.value,
    };
  }
}

/// Result of loading the cache: [data] is always usable (empty when nothing
/// is cached), and [loadIssue] carries a machine-readable reason when the
/// cached document had to be discarded (`corrupt-cache`).
class CacheLoadResult {
  const CacheLoadResult(this.data, this.loadIssue);

  final AgendaCacheData data;
  final String? loadIssue;
}

/// Seam over path_provider so tests can point the cache at a temp directory
/// or mock the provider entirely.
abstract interface class CacheDirectoryProvider {
  Future<Directory> getDirectory();
}

/// Production provider: the platform application-support directory.
class AppSupportCacheDirectoryProvider implements CacheDirectoryProvider {
  @override
  Future<Directory> getDirectory() => getApplicationSupportDirectory();
}

/// A single JSON document in the application-support directory, written
/// atomically (temp file + rename) so a crash mid-write can never leave a
/// half-written document. A corrupt or truncated file is discarded and
/// reported as `corrupt-cache` instead of throwing.
class AgendaCache {
  AgendaCache({CacheDirectoryProvider? directoryProvider})
      : _directoryProvider =
            directoryProvider ?? AppSupportCacheDirectoryProvider();

  static const String fileName = 'agenda_cache.json';

  final CacheDirectoryProvider _directoryProvider;

  File _mainFile(Directory dir) => File('${dir.path}/$fileName');

  File _tmpFile(Directory dir) => File('${dir.path}/$fileName.tmp');

  Future<CacheLoadResult> load() async {
    final dir = await _directoryProvider.getDirectory();
    final file = _mainFile(dir);
    final bool exists;
    try {
      exists = await file.exists();
    } on FileSystemException {
      return const CacheLoadResult(AgendaCacheData.empty(), 'corrupt-cache');
    }
    if (!exists) {
      return const CacheLoadResult(AgendaCacheData.empty(), null);
    }
    final Object? decoded;
    try {
      final content = await file.readAsString();
      decoded = jsonDecode(content);
    } on FormatException {
      await _discard(file);
      return const CacheLoadResult(AgendaCacheData.empty(), 'corrupt-cache');
    } on FileSystemException {
      await _discard(file);
      return const CacheLoadResult(AgendaCacheData.empty(), 'corrupt-cache');
    }
    if (decoded is! Map<String, dynamic>) {
      await _discard(file);
      return const CacheLoadResult(AgendaCacheData.empty(), 'corrupt-cache');
    }
    return CacheLoadResult(
        AgendaCacheData.fromJson(Map<String, dynamic>.of(decoded)), null);
  }

  Future<void> save(AgendaCacheData data) async {
    final dir = await _directoryProvider.getDirectory();
    await dir.create(recursive: true);
    final tmp = _tmpFile(dir);
    await tmp.writeAsString(jsonEncode(data.toJson()), flush: true);
    try {
      await tmp.rename(_mainFile(dir).path);
    } on FileSystemException {
      // Windows cannot rename over an existing file.
      final target = _mainFile(dir);
      if (await target.exists()) {
        await target.delete();
      }
      await tmp.rename(target.path);
    }
  }

  /// Best-effort removal of a corrupt document; a failed delete must not
  /// mask the corruption report.
  Future<void> _discard(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException {
      // Ignored: the next load will report corrupt-cache again.
    }
  }
}
