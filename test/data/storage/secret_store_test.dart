import 'dart:convert';
import 'dart:io';

import 'package:attention_copilot/data/storage/agenda_cache.dart';
import 'package:attention_copilot/data/storage/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'test_support.dart';

class MockSecureBackend extends Mock implements SecureKeyValueBackend {}

/// In-memory backend that records everything written, so tests can prove
/// which values the store handed to the secure layer.
class RecordingBackend implements SecureKeyValueBackend {
  final Map<String, String> data = {};

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async {
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    data.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SecretStore key mapping', () {
    late MockSecureBackend backend;

    setUp(() {
      backend = MockSecureBackend();
    });

    test('saveRefreshToken writes to oauth.refresh_token', () async {
      when(() => backend.write(any(), any()))
          .thenAnswer((_) async {});

      await SecretStore(backend: backend).saveRefreshToken('tok-1');

      verify(() => backend.write('oauth.refresh_token', 'tok-1')).called(1);
    });

    test('readRefreshToken reads from oauth.refresh_token', () async {
      when(() => backend.read('oauth.refresh_token'))
          .thenAnswer((_) async => 'tok-2');

      final value = await SecretStore(backend: backend).readRefreshToken();

      expect(value, 'tok-2');
    });

    test('saveAccessToken with null deletes instead of writing', () async {
      when(() => backend.delete(any())).thenAnswer((_) async {});

      await SecretStore(backend: backend).saveAccessToken(null);

      verify(() => backend.delete('oauth.access_token')).called(1);
      verifyNever(() => backend.write(any(), any()));
    });

    test('saveIcsBearerUrl writes to ics.bearer_url', () async {
      when(() => backend.write(any(), any())).thenAnswer((_) async {});

      await SecretStore(backend: backend)
          .saveIcsBearerUrl('https://cal.example.com/feed?auth=secret');

      verify(() => backend.write(
          'ics.bearer_url', 'https://cal.example.com/feed?auth=secret'))
          .called(1);
    });

    test('clearAll removes every stored secret key', () async {
      when(() => backend.delete(any())).thenAnswer((_) async {});

      await SecretStore(backend: backend).clearAll();

      verify(() => backend.delete('oauth.refresh_token')).called(1);
      verify(() => backend.delete('oauth.access_token')).called(1);
      verify(() => backend.delete('ics.bearer_url')).called(1);
    });
  });

  group('SecretStore plaintext isolation', () {
    test(
        'a token written via SecretStore is NOT present in the plaintext '
        'cache JSON on disk', () async {
      final tempDir = await Directory.systemTemp.createTemp('ac_plaintext_');
      addTearDown(() => tempDir.delete(recursive: true));

      const refreshToken = '1//SECRET-REFRESH-TOKEN-DO-NOT-LEAK';
      const accessToken = 'ya29.SECRET-ACCESS-TOKEN-DO-NOT-LEAK';
      const bearerUrl = 'https://ics.example.com/private?t=BEARER-SECRET';

      final backend = RecordingBackend();
      final secretStore = SecretStore(backend: backend);
      await secretStore.saveRefreshToken(refreshToken);
      await secretStore.saveAccessToken(accessToken);
      await secretStore.saveIcsBearerUrl(bearerUrl);

      final cache = AgendaCache(
        directoryProvider: FixedDirectoryProvider(tempDir),
      );
      await cache.save(AgendaCacheData(
        schemaVersion: AgendaCacheData.currentSchemaVersion,
        fetchedAt: DateTime.utc(2026, 9, 17, 12, 0, 0),
        cursors: {
          'google:primary': const AgendaSourceCursor(syncToken: 'sync-abc'),
          'ics:feed-1': const AgendaSourceCursor(
            etag: '"v1"',
            lastModified: 'Thu, 17 Sep 2026 10:00:00 GMT',
          ),
        },
      ));

      final file = File('${tempDir.path}/${AgendaCache.fileName}');
      expect(file.existsSync(), isTrue);
      final onDisk = file.readAsStringSync();

      expect(onDisk, isNot(contains(refreshToken)));
      expect(onDisk, isNot(contains(accessToken)));
      expect(onDisk, isNot(contains(bearerUrl)));

      // The secret layer itself did receive the values, so this is a real
      // separation test and not a no-op.
      expect(backend.data.values, containsAll([refreshToken, accessToken, bearerUrl]));

      // And the round-tripped cache data still has the cursors intact.
      final loaded = await cache.load();
      expect(loaded.loadIssue, isNull);
      expect(loaded.data.cursors['google:primary']!.syncToken, 'sync-abc');
    });

    test('AgendaCacheData serialisation has no field that can carry a token',
        () {
      final json = AgendaCacheData(
        schemaVersion: AgendaCacheData.currentSchemaVersion,
        fetchedAt: DateTime.utc(2026, 9, 17),
        cursors: {
          'google:primary': const AgendaSourceCursor(syncToken: 'sync-abc'),
        },
      ).toJson();

      final raw = jsonEncode(json);
      expect(raw, isNot(contains('token')));
      expect(raw, isNot(contains('secret')));
      expect(raw, isNot(contains('bearer')));
    });
  });
}
