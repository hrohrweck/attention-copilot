import 'dart:convert';
import 'dart:io';

import 'package:attention_copilot/data/storage/agenda_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ac_cache_test_');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  File cacheFile() => File('${tempDir.path}/${AgendaCache.fileName}');

  group('AgendaSourceCursor', () {
    test('round-trips google syncToken and ics etag/lastModified', () {
      const cursor = AgendaSourceCursor(
        syncToken: 'CMi9x...',
        etag: '"abc123"',
        lastModified: 'Thu, 17 Sep 2026 10:00:00 GMT',
      );

      final restored = AgendaSourceCursor.fromJson(cursor.toJson());

      expect(restored.syncToken, 'CMi9x...');
      expect(restored.etag, '"abc123"');
      expect(restored.lastModified, 'Thu, 17 Sep 2026 10:00:00 GMT');
    });

    test('omits null fields from JSON', () {
      const cursor = AgendaSourceCursor(syncToken: 'only-token');

      final json = cursor.toJson();

      expect(json, {'syncToken': 'only-token'});
    });
  });

  group('AgendaCache', () {
    test('load returns an empty cache when the file does not exist', () async {
      final cache = AgendaCache(directoryProvider: FixedDirectoryProvider(tempDir));

      final result = await cache.load();

      expect(result.loadIssue, isNull);
      expect(result.data.cursors, isEmpty);
      expect(result.data.fetchedAt, isNull);
      expect(result.data.schemaVersion, AgendaCacheData.currentSchemaVersion);
    });

    test('save writes a single document and load reads it back', () async {
      final cache = AgendaCache(directoryProvider: FixedDirectoryProvider(tempDir));
      final fetchedAt = DateTime.utc(2026, 9, 17, 12, 34, 56);

      await cache.save(AgendaCacheData(
        schemaVersion: AgendaCacheData.currentSchemaVersion,
        fetchedAt: fetchedAt,
        cursors: {
          'google:primary':
              const AgendaSourceCursor(syncToken: 'sync-token-1'),
          'ics:team-feed': const AgendaSourceCursor(
            etag: '"v7"',
            lastModified: 'Wed, 16 Sep 2026 08:00:00 GMT',
          ),
        },
      ));

      final file = cacheFile();
      expect(file.existsSync(), isTrue);

      final onDisk = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(onDisk['schemaVersion'], AgendaCacheData.currentSchemaVersion);
      expect(onDisk['fetchedAt'], '2026-09-17T12:34:56.000Z');

      final result = await cache.load();
      expect(result.loadIssue, isNull);
      expect(result.data.fetchedAt, fetchedAt);
      expect(result.data.cursors['google:primary']!.syncToken, 'sync-token-1');
      expect(result.data.cursors['ics:team-feed']!.etag, '"v7"');
      expect(
          result.data.cursors['ics:team-feed']!.lastModified,
          'Wed, 16 Sep 2026 08:00:00 GMT');
    });

    test('atomic write leaves no temp file behind after a successful save',
        () async {
      final cache = AgendaCache(directoryProvider: FixedDirectoryProvider(tempDir));

      await cache.save(AgendaCacheData(
        schemaVersion: AgendaCacheData.currentSchemaVersion,
        fetchedAt: DateTime.utc(2026, 9, 17),
        cursors: const {},
      ));

      final entries = tempDir.listSync().map((e) => e.path).toList();
      expect(entries, hasLength(1));
      expect(entries.single, endsWith(AgendaCache.fileName));
      expect(entries.single, isNot(endsWith('.tmp')));
    });

    test('save creates the support directory when it is missing', () async {
      final nested = Directory('${tempDir.path}/does/not/exist/yet');
      final cache = AgendaCache(directoryProvider: FixedDirectoryProvider(nested));

      await cache.save(AgendaCacheData(
        schemaVersion: AgendaCacheData.currentSchemaVersion,
        fetchedAt: DateTime.utc(2026, 9, 17),
        cursors: const {},
      ));

      expect(File('${nested.path}/${AgendaCache.fileName}').existsSync(), isTrue);
    });

    test('a truncated cache file yields an empty cache plus corrupt-cache',
        () async {
      cacheFile().writeAsStringSync('{"schemaVersion": 1, "fetchedAt": "2026-0');

      final cache = AgendaCache(directoryProvider: FixedDirectoryProvider(tempDir));
      final result = await cache.load();

      expect(result.loadIssue, 'corrupt-cache');
      expect(result.data.cursors, isEmpty);
      expect(result.data.fetchedAt, isNull);
      expect(cacheFile().existsSync(), isFalse,
          reason: 'corrupt file must be discarded');
    });

    test('syntactically invalid JSON yields corrupt-cache, never throws',
        () async {
      cacheFile().writeAsStringSync('not json at all {{{');

      final cache = AgendaCache(directoryProvider: FixedDirectoryProvider(tempDir));
      final result = await cache.load();

      expect(result.loadIssue, 'corrupt-cache');
      expect(result.data.schemaVersion, AgendaCacheData.currentSchemaVersion);
    });

    test('a JSON document that is not an object yields corrupt-cache',
        () async {
      cacheFile().writeAsStringSync('[1, 2, 3]');

      final cache = AgendaCache(directoryProvider: FixedDirectoryProvider(tempDir));
      final result = await cache.load();

      expect(result.loadIssue, 'corrupt-cache');
      expect(result.data.cursors, isEmpty);
    });

    test('unknown future keys in the cache document are preserved on rewrite',
        () async {
      cacheFile().writeAsStringSync(jsonEncode({
        'schemaVersion': 1,
        'fetchedAt': '2026-09-17T08:00:00.000Z',
        'cursors': {'google:primary': {'syncToken': 'old-sync'}},
        'futureExtension': {'nested': true},
      }));
      final cache = AgendaCache(directoryProvider: FixedDirectoryProvider(tempDir));

      final loaded = await cache.load();
      expect(loaded.loadIssue, isNull);

      await cache.save(AgendaCacheData(
        schemaVersion: AgendaCacheData.currentSchemaVersion,
        fetchedAt: DateTime.utc(2026, 9, 17, 9),
        cursors: {
          'google:primary': const AgendaSourceCursor(syncToken: 'new-sync'),
        },
        unknown: loaded.data.unknown,
      ));

      final onDisk = jsonDecode(cacheFile().readAsStringSync()) as Map<String, dynamic>;
      expect(onDisk['futureExtension'], {'nested': true});
      expect(
          (onDisk['cursors'] as Map<String, dynamic>)['google:primary'],
          {'syncToken': 'new-sync'});
    });

    test('works through a mocked directory provider (path-provider seam)',
        () async {
      final provider = MockCacheDirectoryProvider();
      when(provider.getDirectory).thenAnswer((_) async => tempDir);
      final cache = AgendaCache(directoryProvider: provider);

      await cache.save(AgendaCacheData(
        schemaVersion: AgendaCacheData.currentSchemaVersion,
        fetchedAt: DateTime.utc(2026, 9, 17),
        cursors: const {},
      ));
      final result = await cache.load();

      expect(result.loadIssue, isNull);
      expect(result.data.fetchedAt, DateTime.utc(2026, 9, 17));
      verify(() => provider.getDirectory()).called(2);
    });

    test('cursor round-trip: overwriting with empty cursors clears old data',
        () async {
      final cache = AgendaCache(directoryProvider: FixedDirectoryProvider(tempDir));
      await cache.save(AgendaCacheData(
        schemaVersion: AgendaCacheData.currentSchemaVersion,
        fetchedAt: DateTime.utc(2026, 9, 17),
        cursors: {
          'google:primary': const AgendaSourceCursor(syncToken: 'gone'),
        },
      ));

      await cache.save(AgendaCacheData(
        schemaVersion: AgendaCacheData.currentSchemaVersion,
        fetchedAt: DateTime.utc(2026, 9, 17, 1),
        cursors: const {},
      ));

      final result = await cache.load();
      expect(result.data.cursors, isEmpty);
    });
  });
}
