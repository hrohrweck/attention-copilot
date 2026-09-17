import 'dart:io';

import 'package:attention_copilot/diagnostics/log_sink.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('log_sink_test_');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  String onDisk() => dir
      .listSync()
      .whereType<File>()
      .map((f) => f.readAsStringSync())
      .join('\n');

  test('rotates at the size cap: active -> .1 -> .2, oldest dropped', () {
    final sink = LogSink(directory: dir, maxBytes: 200);
    for (var i = 0; i < 20; i++) {
      sink.write('message-$i-${'x' * 40}');
    }

    final names = dir
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .toSet();
    expect(names, {'diagnostics.log', 'diagnostics.log.1', 'diagnostics.log.2'});

    // Every file stays at or under the cap.
    for (final file in dir.listSync().whereType<File>()) {
      expect(
        file.lengthSync(),
        lessThanOrEqualTo(200),
        reason: '${file.uri.pathSegments.last} over cap',
      );
    }

    final disk = onDisk();
    expect(disk, contains('message-19'));
    expect(disk, isNot(contains('message-0')));
  });

  test('a written token, client id and ICS URL never appear on disk', () {
    final sink = LogSink(directory: dir);
    sink.write(
      'oauth refresh_token=sekret-refresh access_token=sekret-access '
      'client 123456789-abc123def.apps.googleusercontent.com '
      'ics https://calendar.example.com/private/feed.ics?token=sekret-ics&sig=zzz',
    );

    final disk = onDisk();
    expect(disk, contains('[REDACTED]'));
    expect(disk, isNot(contains('sekret-refresh')));
    expect(disk, isNot(contains('sekret-access')));
    expect(disk, isNot(contains('sekret-ics')));
    expect(disk, isNot(contains('zzz')));
    expect(disk, isNot(contains('123456789-abc123def.apps.googleusercontent.com')));
  });

  test('redactSecrets redacts bearer authorization headers', () {
    const line = 'GET /ics Authorization: Bearer ya29.super-sekret';
    expect(redactSecrets(line), 'GET /ics Authorization: Bearer [REDACTED]');
  });
}
