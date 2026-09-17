import 'dart:io';

import 'package:attention_copilot/data/storage/agenda_cache.dart';
import 'package:mocktail/mocktail.dart';

/// Test-only directory provider pointing at a real, throw-away directory so
/// tests can inspect the actual bytes written to disk.
class FixedDirectoryProvider implements CacheDirectoryProvider {
  FixedDirectoryProvider(this.directory);

  final Directory directory;

  @override
  Future<Directory> getDirectory() async => directory;
}

class MockCacheDirectoryProvider extends Mock
    implements CacheDirectoryProvider {}
