import 'package:attention_copilot/data/sources/refresh_orchestrator.dart';
import 'package:attention_copilot/data/sources/registry.dart';
import 'package:attention_copilot/data/sources/source.dart';
import 'package:attention_copilot/domain/models/meeting_join_info.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

void main() {
  final start = DateTime.utc(2026, 9, 18, 9);
  final hour = const Duration(hours: 1);

  RefreshOrchestrator buildOrchestrator(
    List<FakeCalendarSource> sources, {
    TestClock? clock,
    double Function() jitter = _zeroJitter,
    Duration minRefreshInterval = Duration.zero,
    Duration minIntervalJitterSpan = Duration.zero,
    Duration initialBackoff = const Duration(milliseconds: 100),
  }) {
    final registry = CalendarSourceRegistry();
    for (final source in sources) {
      registry.register(source);
    }
    return RefreshOrchestrator(
      registry: registry,
      clock: clock?.call,
      jitter: jitter,
      minRefreshInterval: minRefreshInterval,
      minIntervalJitterSpan: minIntervalJitterSpan,
      initialBackoff: initialBackoff,
      backoffFactor: 2,
      backoffJitterFraction: 0.25,
    );
  }

  group('merge and dedupe', () {
    test('two sources returning the same iCalUID merge into one occurrence',
        () async {
      final google = FakeCalendarSource(id: 'google');
      final ics = FakeCalendarSource(id: 'ics');
      google.occurrences = [
        occurrence(
          sourceId: 'google',
          eventId: 'meet-1@example.com',
          startUtc: start,
          endUtc: start.add(hour),
          instanceSuffix: '-g',
        ),
      ];
      ics.occurrences = [
        occurrence(
          sourceId: 'ics',
          eventId: 'meet-1@example.com',
          startUtc: start,
          endUtc: start.add(hour),
          instanceSuffix: '-i',
        ),
      ];
      final orchestrator = buildOrchestrator([google, ics]);

      final result = await orchestrator.refresh();

      expect(result.wasSkipped, isFalse);
      expect(result.occurrences, hasLength(1));
      final merged = result.occurrences.single;
      expect(merged.event.id, 'meet-1@example.com');
      // Deterministic winner: equal priority and no join info -> the smaller
      // occurrence id ('-g' < '-i') wins, independent of input order.
      expect(merged.source.id, 'google');
    });

    test('the winner keeps join info even from the lower-priority source',
        () async {
      final plain = FakeCalendarSource(id: 'plain', priority: 0);
      final rich = FakeCalendarSource(id: 'rich', priority: 9);
      plain.occurrences = [
        occurrence(
          sourceId: 'plain',
          eventId: 'meet-2@example.com',
          startUtc: start,
          instanceSuffix: '-a',
        ),
      ];
      rich.occurrences = [
        occurrence(
          sourceId: 'rich',
          eventId: 'meet-2@example.com',
          startUtc: start,
          instanceSuffix: '-b',
          joinInfo: const MeetingJoinInfo(url: 'https://meet.example.com/x'),
        ),
      ];
      final orchestrator = buildOrchestrator([plain, rich]);

      final result = await orchestrator.refresh();

      expect(result.occurrences, hasLength(1));
      expect(result.occurrences.single.source.id, 'rich');
      expect(result.occurrences.single.joinInfo, isNotNull);
    });

    test('fallback (no iCalUID) merges duplicates inside one source',
        () async {
      final a = FakeCalendarSource(id: 'a');
      a.occurrences = [
        occurrence(
          sourceId: 'a',
          eventId: 'local',
          startUtc: start,
          endUtc: start.add(hour),
          instanceSuffix: '-1',
          title: 'Standup',
        ),
        occurrence(
          sourceId: 'a',
          eventId: 'local',
          startUtc: start,
          endUtc: start.add(hour),
          instanceSuffix: '-2',
          title: 'Standup',
        ),
      ];
      final orchestrator = buildOrchestrator([a]);

      final result = await orchestrator.refresh();

      expect(result.occurrences, hasLength(1));
      // Deterministic winner: smaller occurrence id.
      expect(result.occurrences.single.id, 'local-1');
    });

    test(
        'occurrences without iCalUID from different sources are not merged '
        '(title + start + source fallback)', () async {
      final a = FakeCalendarSource(id: 'a');
      final b = FakeCalendarSource(id: 'b');
      a.occurrences = [
        occurrence(
          sourceId: 'a',
          eventId: 'local',
          startUtc: start,
          endUtc: start.add(hour),
          instanceSuffix: '-a',
          title: 'Standup',
        ),
      ];
      b.occurrences = [
        occurrence(
          sourceId: 'b',
          eventId: 'local',
          startUtc: start,
          endUtc: start.add(hour),
          instanceSuffix: '-b',
          title: 'Standup',
        ),
      ];
      final orchestrator = buildOrchestrator([a, b]);

      final result = await orchestrator.refresh();

      expect(result.occurrences, hasLength(2));
      expect(result.occurrences.map((o) => o.source.id).toSet(), {'a', 'b'});
    });

    test('fallback matching normalizes the title (case and whitespace)',
        () async {
      final a = FakeCalendarSource(id: 'a');
      a.occurrences = [
        occurrence(
          sourceId: 'a',
          eventId: 'local',
          startUtc: start,
          instanceSuffix: '-1',
          title: '  Stand UP  \nMeeting ',
        ),
        occurrence(
          sourceId: 'a',
          eventId: 'local',
          startUtc: start,
          instanceSuffix: '-2',
          title: 'stand up meeting',
        ),
      ];
      final orchestrator = buildOrchestrator([a]);

      final result = await orchestrator.refresh();

      expect(result.occurrences, hasLength(1));
      expect(result.occurrences.single.id, 'local-1');
    });

    test('the merged result is sorted by start, then priority, then id',
        () async {
      final a = FakeCalendarSource(id: 'a');
      final b = FakeCalendarSource(id: 'b', priority: 1);
      final lateStart = start.add(const Duration(hours: 2));
      final alsoLateStart = lateStart;
      a.occurrences = [
        occurrence(
          sourceId: 'a',
          eventId: 'late@example.com',
          startUtc: lateStart,
          instanceSuffix: '-a',
        ),
        occurrence(
          sourceId: 'a',
          eventId: 'z-first@example.com',
          startUtc: alsoLateStart,
          instanceSuffix: '-z',
        ),
      ];
      b.occurrences = [
        occurrence(
          sourceId: 'b',
          eventId: 'early@example.com',
          startUtc: start,
          instanceSuffix: '-b',
        ),
      ];
      final orchestrator = buildOrchestrator([a, b]);

      final result = await orchestrator.refresh();

      expect(
        result.occurrences.map((o) => o.event.id).toList(),
        // 'early' starts first; 'late' and 'z-first' tie on start, tie on
        // priority (same source), so id order decides.
        ['early@example.com', 'late@example.com', 'z-first@example.com'],
      );
    });

    test('one source is enough for a single merged result when others fail',
        () async {
      final a = FakeCalendarSource(id: 'a');
      final b = FakeCalendarSource(id: 'b')..thrownError = Exception('down');
      final event = occurrence(
        sourceId: 'a',
        eventId: 'ok@example.com',
        startUtc: start,
      );
      a.occurrences = [event];
      final orchestrator = buildOrchestrator([a, b]);

      final result = await orchestrator.refresh();

      expect(result.wasSkipped, isFalse);
      expect(result.occurrences, [event]);
      expect(result.statuses['a'], const SourceStatus.idle());
      expect(result.statuses['b']!.isError, isTrue);
      expect(result.statuses['b']!.reason, contains('down'));
      expect(orchestrator.latestOccurrences, [event]);
    });
  });

  group('failure isolation', () {
    test('a fully failing refresh never blanks the previous agenda',
        () async {
      final a = FakeCalendarSource(id: 'a');
      final e1 = occurrence(sourceId: 'a', eventId: 'one@example.com', startUtc: start);
      final e2 = occurrence(
        sourceId: 'a',
        eventId: 'two@example.com',
        startUtc: start.add(hour),
      );
      a.occurrences = [e1, e2];
      final orchestrator = buildOrchestrator([a]);

      await orchestrator.refresh();
      expect(orchestrator.latestOccurrences, hasLength(2));

      a.thrownError = Exception('down');
      final result = await orchestrator.refresh();

      expect(result.occurrences, isEmpty);
      expect(result.statuses['a']!.isError, isTrue);
      // The stale agenda survives: a failure must never blank it.
      expect(orchestrator.latestOccurrences, hasLength(2));
    });

    test('per-source errors do not fail the refresh future', () async {
      final a = FakeCalendarSource(id: 'a')..thrownError = Exception('x');
      final b = FakeCalendarSource(id: 'b')..thrownError = Exception('y');
      final orchestrator = buildOrchestrator([a, b]);

      final result = await orchestrator.refresh();

      expect(result.occurrences, isEmpty);
      expect(result.statuses['a']!.isError, isTrue);
      expect(result.statuses['b']!.isError, isTrue);
      expect(orchestrator.statusFor('a').isError, isTrue);
    });
  });

  group('concurrency', () {
    test('a refresh already in flight is not started a second time',
        () async {
      final a = FakeCalendarSource(id: 'a');
      final b = FakeCalendarSource(id: 'b');
      final orchestrator = buildOrchestrator([a, b]);

      final first = orchestrator.refresh();
      final second = orchestrator.refresh();
      final forced = orchestrator.refresh(force: true);

      expect(identical(first, second), isTrue);
      expect(identical(first, forced), isTrue);
      await first;

      expect(a.fetchCount, 1);
      expect(b.fetchCount, 1);
    });

    test('a refresh can run again once the previous one completed',
        () async {
      final clock = TestClock();
      final a = FakeCalendarSource(id: 'a');
      final orchestrator = buildOrchestrator([a], clock: clock);

      await orchestrator.refresh(now: clock());
      clock.current = clock.current.add(const Duration(milliseconds: 1));
      await orchestrator.refresh(now: clock());

      expect(a.fetchCount, 2);
    });
  });

  group('minimum refresh interval', () {
    test('a refresh inside the jittered interval is skipped, force bypasses',
        () async {
      final clock = TestClock();
      final a = FakeCalendarSource(id: 'a');
      final orchestrator = buildOrchestrator(
        [a],
        clock: clock,
        jitter: () => 0.5,
        minRefreshInterval: const Duration(seconds: 1),
        minIntervalJitterSpan: const Duration(milliseconds: 100),
      );

      final t0 = clock.current;
      await orchestrator.refresh(now: clock());
      expect(a.fetchCount, 1);
      expect(
        orchestrator.nextRefreshAllowedAt,
        t0.add(const Duration(milliseconds: 1050)),
      );

      clock.current = t0.add(const Duration(milliseconds: 500));
      final gated = await orchestrator.refresh(now: clock());
      expect(gated.wasSkipped, isTrue);
      expect(gated.occurrences, isEmpty);
      expect(a.fetchCount, 1);

      // Past the gate: fetch proceeds.
      clock.current = t0.add(const Duration(milliseconds: 1100));
      await orchestrator.refresh(now: clock());
      expect(a.fetchCount, 2);

      // Still inside the new gate, but force bypasses it.
      final forced = await orchestrator.refresh(force: true, now: clock());
      expect(forced.wasSkipped, isFalse);
      expect(a.fetchCount, 3);
    });

    test('a skipped refresh does not advance the interval anchor', () async {
      final clock = TestClock();
      final a = FakeCalendarSource(id: 'a');
      final orchestrator = buildOrchestrator(
        [a],
        clock: clock,
        minRefreshInterval: const Duration(seconds: 1),
      );

      final t0 = clock.current;
      await orchestrator.refresh(now: clock());

      clock.current = t0.add(const Duration(milliseconds: 900));
      await orchestrator.refresh(now: clock()); // skipped
      clock.current = t0.add(const Duration(milliseconds: 950));
      await orchestrator.refresh(now: clock()); // still skipped
      expect(a.fetchCount, 1);

      clock.current = t0.add(const Duration(seconds: 1));
      await orchestrator.refresh(now: clock());
      expect(a.fetchCount, 2);
    });
  });

  group('backoff', () {
    test('the backoff delay grows exponentially across failures', () async {
      final clock = TestClock();
      final a = FakeCalendarSource(id: 'a')..thrownError = Exception('boom');
      final orchestrator = buildOrchestrator([a], clock: clock);

      final t0 = clock.current;
      await orchestrator.refresh(now: clock());
      expect(a.fetchCount, 1);
      expect(orchestrator.consecutiveFailures('a'), 1);
      expect(
        orchestrator.nextRetryAllowedAt('a'),
        t0.add(const Duration(milliseconds: 100)),
      );

      // Inside the backoff window: not fetched again, error status kept.
      clock.current = t0.add(const Duration(milliseconds: 99));
      await orchestrator.refresh(now: clock());
      expect(a.fetchCount, 1);
      expect(orchestrator.statusFor('a').isError, isTrue);

      // Window elapsed: refetched, fails again, delay doubles.
      clock.current = t0.add(const Duration(milliseconds: 100));
      await orchestrator.refresh(now: clock());
      expect(a.fetchCount, 2);
      expect(orchestrator.consecutiveFailures('a'), 2);
      expect(
        orchestrator.nextRetryAllowedAt('a'),
        clock.current.add(const Duration(milliseconds: 200)),
      );
    });

    test('the backoff delay is jittered by the injected jitter function',
        () async {
      final clock0 = TestClock();
      final failing0 = FakeCalendarSource(id: 'a')
        ..thrownError = Exception('boom');
      final unjittered = buildOrchestrator([failing0], clock: clock0);

      await unjittered.refresh(now: clock0());
      final plainDelay =
          unjittered.nextRetryAllowedAt('a')!.difference(clock0.current);

      final clock1 = TestClock();
      final failing1 = FakeCalendarSource(id: 'a')
        ..thrownError = Exception('boom');
      final jittered = buildOrchestrator([failing1], clock: clock1, jitter: () => 1);

      await jittered.refresh(now: clock1());
      final jitteredDelay =
          jittered.nextRetryAllowedAt('a')!.difference(clock1.current);

      // 100 ms base, jitter fraction 0.25: 100 -> 125.
      expect(plainDelay, const Duration(milliseconds: 100));
      expect(jitteredDelay, const Duration(milliseconds: 125));

      // Growth holds even under maximum jitter (factor 2 beats fraction 0.25).
      clock1.current = clock1.current.add(jitteredDelay);
      await jittered.refresh(now: clock1());
      final secondJittered =
          jittered.nextRetryAllowedAt('a')!.difference(clock1.current);
      expect(secondJittered, const Duration(milliseconds: 250));
      expect(secondJittered, greaterThan(jitteredDelay));
    });

    test('a source recovers once its backoff elapses and its error clears',
        () async {
      final clock = TestClock();
      final a = FakeCalendarSource(id: 'a');
      final b = FakeCalendarSource(id: 'b')..thrownError = Exception('flaky');
      final bEvent = occurrence(
        sourceId: 'b',
        eventId: 'recovers@example.com',
        startUtc: start,
      );
      final orchestrator = buildOrchestrator([a, b], clock: clock);

      await orchestrator.refresh(now: clock());
      expect(orchestrator.statusFor('b').isError, isTrue);

      clock.current = clock.current.add(const Duration(milliseconds: 50));
      await orchestrator.refresh(now: clock());
      expect(b.fetchCount, 1);
      expect(orchestrator.statusFor('b').isError, isTrue);

      b.thrownError = null;
      b.occurrences = [bEvent];
      clock.current = clock.current.add(const Duration(milliseconds: 100));
      final result = await orchestrator.refresh(now: clock());

      expect(b.fetchCount, 2);
      expect(orchestrator.statusFor('b'), const SourceStatus.idle());
      expect(orchestrator.consecutiveFailures('b'), 0);
      expect(orchestrator.nextRetryAllowedAt('b'), isNull);
      expect(result.occurrences, contains(bEvent));
    });
  });

  group('permission handling', () {
    test('a source with permission state denied is surfaced and not fetched',
        () async {
      final a = FakeCalendarSource(
        id: 'a',
        permission: SourcePermissionState.denied,
      );
      final b = FakeCalendarSource(id: 'b');
      final orchestrator = buildOrchestrator([a, b]);

      final result = await orchestrator.refresh();

      expect(a.fetchCount, 0);
      expect(b.fetchCount, 1);
      expect(result.statuses['a']!.isPermissionDenied, isTrue);
      expect(result.statuses['a']!.isError, isFalse);
      expect(orchestrator.statusFor('a').isPermissionDenied, isTrue);
      // Permission denial is not a failure: no backoff, no failure count.
      expect(orchestrator.consecutiveFailures('a'), 0);
      expect(orchestrator.nextRetryAllowedAt('a'), isNull);
    });

    test('a SourcePermissionDeniedException thrown by fetch maps to '
        'permission-denied, not error', () async {
      final a = FakeCalendarSource(id: 'a')..throwPermissionDenied = true;
      final orchestrator = buildOrchestrator([a]);

      final result = await orchestrator.refresh();

      expect(a.fetchCount, 1);
      expect(result.statuses['a']!.isPermissionDenied, isTrue);
      expect(result.statuses['a']!.isError, isFalse);
      expect(orchestrator.consecutiveFailures('a'), 0);
      expect(orchestrator.nextRetryAllowedAt('a'), isNull);
    });
  });

  group('cursors', () {
    test('passes the stored cursor into fetch and stores the returned one',
        () async {
      final clock = TestClock();
      final a = FakeCalendarSource(id: 'a')
        ..nextCursor = const SourceCursor('tok-1');
      final orchestrator = buildOrchestrator([a], clock: clock);

      await orchestrator.refresh(now: clock());
      expect(a.receivedCursors, [null]);
      expect(orchestrator.cursors['a'], const SourceCursor('tok-1'));

      a.nextCursor = const SourceCursor('tok-2');
      clock.current = clock.current.add(const Duration(milliseconds: 1));
      await orchestrator.refresh(now: clock());
      expect(a.receivedCursors, [null, const SourceCursor('tok-1')]);
      expect(orchestrator.cursors['a'], const SourceCursor('tok-2'));
    });

    test('a source returning no cursor leaves the stored cursor untouched',
        () async {
      final a = FakeCalendarSource(id: 'a')
        ..nextCursor = const SourceCursor('only-once');
      final orchestrator = buildOrchestrator([a]);

      await orchestrator.refresh();
      a.nextCursor = null;
      await orchestrator.refresh();

      expect(orchestrator.cursors['a'], const SourceCursor('only-once'));
    });
  });

  group('registry interaction', () {
    test('disabled sources are not fetched and not reported', () async {
      final a = FakeCalendarSource(id: 'a');
      final b = FakeCalendarSource(id: 'b');
      final registry = CalendarSourceRegistry()
        ..register(a)
        ..register(b);
      registry.setEnabled('b', false);
      final orchestrator = RefreshOrchestrator(
        registry: registry,
        jitter: _zeroJitter,
        minRefreshInterval: Duration.zero,
        minIntervalJitterSpan: Duration.zero,
      );

      final result = await orchestrator.refresh();

      expect(a.fetchCount, 1);
      expect(b.fetchCount, 0);
      expect(result.statuses.containsKey('b'), isFalse);
    });

    test('refreshing with no enabled sources yields an empty result',
        () async {
      final orchestrator = RefreshOrchestrator(
        registry: CalendarSourceRegistry(),
      );

      final result = await orchestrator.refresh();

      expect(result.wasSkipped, isFalse);
      expect(result.occurrences, isEmpty);
      expect(orchestrator.latestOccurrences, isEmpty);
    });

    test('statusFor defaults to idle for unknown sources', () async {
      final a = FakeCalendarSource(id: 'a');
      final orchestrator = buildOrchestrator([a]);

      expect(orchestrator.statusFor('ghost'), const SourceStatus.idle());
      await orchestrator.refresh();
      expect(orchestrator.statusFor('a'), const SourceStatus.idle());
      expect(orchestrator.statusFor('ghost'), const SourceStatus.idle());
    });
  });
}

double _zeroJitter() => 0;
