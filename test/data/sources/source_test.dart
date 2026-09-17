import 'package:attention_copilot/data/sources/source.dart';
import 'package:attention_copilot/domain/models/calendar_source_id.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

void main() {
  group('SourceStatus', () {
    test('distinguishes kinds and carries error reasons', () {
      expect(const SourceStatus.idle().kind, SourceStatusKind.idle);
      expect(const SourceStatus.refreshing().isRefreshing, isTrue);

      const error = SourceStatus.error('boom');
      expect(error.isError, isTrue);
      expect(error.isPermissionDenied, isFalse);
      expect(error.reason, 'boom');

      const denied = SourceStatus.permissionDenied();
      expect(denied.isPermissionDenied, isTrue);
      expect(denied.isError, isFalse);
      expect(denied.reason, isNull);

      const deniedWithReason = SourceStatus.permissionDenied('declined');
      expect(deniedWithReason.reason, 'declined');
    });

    test('has structural equality', () {
      expect(const SourceStatus.error('x'), const SourceStatus.error('x'));
      expect(const SourceStatus.error('x'), isNot(const SourceStatus.error('y')));
      expect(const SourceStatus.error('x'), isNot(const SourceStatus.idle()));
      expect(
        const SourceStatus.permissionDenied(),
        const SourceStatus.permissionDenied(),
      );
      expect(const SourceStatus.error('x'), isNot(const SourceStatus.permissionDenied('x')));
      expect(
        const SourceStatus.idle().hashCode,
        const SourceStatus.idle().hashCode,
      );
    });

    test('toString includes the kind and the reason', () {
      expect(const SourceStatus.idle().toString(), contains('idle'));
      expect(const SourceStatus.refreshing().toString(), contains('refreshing'));
      expect(const SourceStatus.error('boom').toString(), contains('boom'));
      expect(
        const SourceStatus.permissionDenied('nope').toString(),
        contains('nope'),
      );
    });
  });

  group('SourcePermissionState', () {
    test('exposes the three states', () {
      expect(SourcePermissionState.values, [
        SourcePermissionState.notRequired,
        SourcePermissionState.granted,
        SourcePermissionState.denied,
      ]);
    });
  });

  group('SourcePermissionDeniedException', () {
    test('carries a message into toString', () {
      expect(
        const SourcePermissionDeniedException('declined').toString(),
        contains('declined'),
      );
      expect(
        const SourcePermissionDeniedException().toString(),
        isNotEmpty,
      );
    });
  });

  group('SourceCursor', () {
    test('is opaque and compares by wrapped value', () {
      expect(const SourceCursor('tok'), const SourceCursor('tok'));
      expect(const SourceCursor('a'), isNot(const SourceCursor('b')));
      expect(const SourceCursor(null), const SourceCursor(null));
      expect(const SourceCursor(1), const SourceCursor(1));
      expect(const SourceCursor(null), isNot(const SourceCursor('null')));
    });

    test('toString renders the wrapped value', () {
      expect(const SourceCursor('tok').toString(), contains('tok'));
      expect(const SourceCursor(null).toString(), contains('null'));
    });
  });

  group('SourceSnapshot', () {
    test('carries occurrences and an optional next cursor', () {
      final event = occurrence(sourceId: 'a', eventId: 'e@example.com');
      final snapshot = SourceSnapshot(
        occurrences: [event],
        nextCursor: const SourceCursor('next'),
      );
      expect(snapshot.occurrences, [event]);
      expect(snapshot.nextCursor, const SourceCursor('next'));
      expect(const SourceSnapshot(occurrences: []).nextCursor, isNull);
    });
  });

  group('CalendarSource', () {
    test('a minimal source exposes identity, read-only capability and defaults', () {
      final source = FakeCalendarSource(
        id: 'google',
        displayName: 'Google Calendar',
        priority: 3,
      );
      expect(source.id, 'google');
      expect(source.displayName, 'Google Calendar');
      expect(source.priority, 3);
      expect(
        source.sourceId,
        const CalendarSourceId(
          id: 'google',
          displayName: 'Google Calendar',
          priority: 3,
        ),
      );
      expect(source.isReadOnly, isTrue);
      expect(source.needsAuthentication, isFalse);
      expect(source.permissionState, SourcePermissionState.notRequired);
    });
  });
}
