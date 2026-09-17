import 'dart:io';

import 'package:attention_copilot/data/sources/source.dart';
import 'package:attention_copilot/domain/models/calendar_event.dart';
import 'package:attention_copilot/domain/models/calendar_source_id.dart';
import 'package:attention_copilot/domain/models/event_occurrence.dart';
import 'package:attention_copilot/domain/models/meeting_join_info.dart';
import 'package:attention_copilot/ui/agenda_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Widget + golden tests for the today-first agenda screen.
///
/// Goldens are rendered with Roboto and MaterialIcons loaded from the bundled
/// copies in `test/fonts/` (taken from the Flutter SDK artifact cache), so
/// the captured pixels are identical on the macOS host and Linux CI.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late tz.Location berlin;

  /// The calendar-day boundaries of 2026-09-18 in Europe/Berlin (CEST, UTC+2).
  late DateTime berlinDayStartUtc;
  late DateTime berlinDayEndUtc;

  setUpAll(() async {
    tzdata.initializeTimeZones();
    berlin = tz.getLocation('Europe/Berlin');
    berlinDayStartUtc = tz.TZDateTime(berlin, 2026, 9, 18).toUtc();
    berlinDayEndUtc = tz.TZDateTime(berlin, 2026, 9, 19).toUtc();
    await _loadTestFonts();
  });

  final work = CalendarSourceId(
    id: 'eventkit',
    displayName: 'Work',
    priority: 0,
  );
  final personal = CalendarSourceId(
    id: 'google:acct',
    displayName: 'Google Calendar',
    priority: 10,
  );

  EventOccurrence occ({
    required String id,
    String title = 'Meeting',
    CalendarSourceId source = const CalendarSourceId(
      id: 'eventkit',
      displayName: 'Work',
    ),
    required DateTime startUtc,
    required DateTime endUtc,
    String? location,
    MeetingJoinInfo? joinInfo,
    bool isAllDay = false,
  }) {
    return EventOccurrence(
      id: id,
      event: CalendarEvent(
        id: 'evt-$id',
        title: title,
        location: location,
        joinInfo: joinInfo,
      ),
      source: source,
      startUtc: startUtc,
      endUtc: endUtc,
      isAllDay: isAllDay,
    );
  }

  /// Pumps the screen inside a MaterialApp using the bundled Roboto font so
  /// text metrics (and therefore goldens) are host-independent.
  Future<void> pumpAgenda(
    WidgetTester tester, {
    required List<EventOccurrence> occurrences,
    Map<String, SourceStatus> statuses = const {},
    Map<String, String> sourceDisplayNames = const {},
    bool anySourcesEnabled = true,
    DateTime? lastRefreshedAt,
    Future<void> Function()? onRefresh,
    required DateTime Function() clock,
    void Function(String url)? onJoinMeeting,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
          fontFamily: 'Roboto',
          useMaterial3: true,
        ),
        home: AgendaScreen(
          occurrences: occurrences,
          statuses: statuses,
          sourceDisplayNames: sourceDisplayNames,
          anySourcesEnabled: anySourcesEnabled,
          lastRefreshedAt: lastRefreshedAt,
          onRefresh: onRefresh ?? () async {},
          clock: clock,
          timezone: berlin,
          onJoinMeeting: onJoinMeeting ?? (_) {},
        ),
      ),
    );
    await tester.pump();
  }

  group('next meeting card', () {
    // All times on 2026-09-18 in UTC; Berlin local = UTC + 2 hours.
    testWidgets('is dominant and shows the correct countdown at three '
        'fixed clocks', (tester) async {
      var now = DateTime.utc(2026, 9, 18, 8, 55);
      final meeting = occ(
        id: 'sync',
        title: 'Design sync',
        source: work,
        startUtc: DateTime.utc(2026, 9, 18, 9),
        endUtc: DateTime.utc(2026, 9, 18, 10),
      );
      await pumpAgenda(
        tester,
        occurrences: [meeting],
        clock: () => now,
        lastRefreshedAt: now,
      );

      expect(find.byKey(const ValueKey('next-meeting-card')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('next-meeting-card')),
          matching: find.text('Design sync'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('next-meeting-countdown')),
        findsOneWidget,
      );
      expect(find.text('5m 00s'), findsOneWidget);

      // Second clock: 90 minutes before the meeting.
      now = DateTime.utc(2026, 9, 18, 7, 30);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('1h 30m'), findsOneWidget);

      // Third clock: under a minute before the meeting.
      now = DateTime.utc(2026, 9, 18, 8, 59, 15);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('45s'), findsOneWidget);
    });

    testWidgets('re-renders the countdown at most once per second and only '
        'when the clock advances', (tester) async {
      var now = DateTime.utc(2026, 9, 18, 8, 55);
      final meeting = occ(
        id: 'sync',
        title: 'Design sync',
        source: work,
        startUtc: DateTime.utc(2026, 9, 18, 9),
        endUtc: DateTime.utc(2026, 9, 18, 10),
      );
      await pumpAgenda(
        tester,
        occurrences: [meeting],
        clock: () => now,
      );
      expect(find.text('5m 00s'), findsOneWidget);

      // One second later the label ticks down exactly once.
      now = DateTime.utc(2026, 9, 18, 8, 55, 1);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('4m 59s'), findsOneWidget);

      now = DateTime.utc(2026, 9, 18, 8, 55, 2);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('4m 58s'), findsOneWidget);

      // A second without clock movement leaves the label untouched.
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('4m 58s'), findsOneWidget);
    });

    testWidgets('labels a running meeting "In progress"', (tester) async {
      final now = DateTime.utc(2026, 9, 18, 9);
      final running = occ(
        id: 'running',
        title: 'Retro',
        source: work,
        startUtc: DateTime.utc(2026, 9, 18, 8, 30),
        endUtc: DateTime.utc(2026, 9, 18, 9, 30),
        joinInfo: const MeetingJoinInfo(
          url: 'https://meet.example.com/retro',
        ),
      );
      final past = occ(
        id: 'past',
        title: 'Standup',
        source: work,
        startUtc: DateTime.utc(2026, 9, 18, 7),
        endUtc: DateTime.utc(2026, 9, 18, 7, 30),
      );
      await pumpAgenda(
        tester,
        occurrences: [past, running],
        clock: () => now,
      );

      expect(find.byKey(const ValueKey('in-progress-badge')), findsOneWidget);
      expect(find.text('In progress'), findsOneWidget);
      expect(find.byKey(const ValueKey('next-meeting-countdown')),
          findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('next-meeting-card')),
          matching: find.text('Retro'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('shows the Join button only when a conference URL exists '
        'and opens it on tap', (tester) async {
      final now = DateTime.utc(2026, 9, 18, 8);
      final withJoin = occ(
        id: 'joinable',
        title: 'Client call',
        source: work,
        startUtc: DateTime.utc(2026, 9, 18, 9),
        endUtc: DateTime.utc(2026, 9, 18, 10),
        joinInfo: const MeetingJoinInfo(
          url: 'https://meet.example.com/abc',
          provider: 'zoom',
        ),
      );
      final withoutJoin = occ(
        id: 'plain',
        title: 'Deep work',
        source: work,
        startUtc: DateTime.utc(2026, 9, 18, 11),
        endUtc: DateTime.utc(2026, 9, 18, 12),
      );

      final joined = <String>[];
      await pumpAgenda(
        tester,
        occurrences: [withJoin, withoutJoin],
        clock: () => now,
        onJoinMeeting: joined.add,
      );
      expect(find.text('Join'), findsOneWidget);

      await tester.tap(find.text('Join'));
      await tester.pump();
      expect(joined, ['https://meet.example.com/abc']);

      // A meeting without a conference URL has no Join affordance.
      await pumpAgenda(
        tester,
        occurrences: [withoutJoin],
        clock: () => now,
        onJoinMeeting: joined.add,
      );
      expect(find.text('Join'), findsNothing);
    });

    testWidgets('shows start/end times, calendar name and location',
        (tester) async {
      final now = DateTime.utc(2026, 9, 18, 8);
      final meeting = occ(
        id: 'sync',
        title: 'Design sync',
        source: work,
        startUtc: DateTime.utc(2026, 9, 18, 9),
        endUtc: DateTime.utc(2026, 9, 18, 10),
        location: 'Room B',
      );
      await pumpAgenda(
        tester,
        occurrences: [meeting],
        clock: () => now,
      );

      // 09:00-10:00 UTC == 11:00-12:00 Europe/Berlin.
      expect(find.text('11:00 – 12:00'), findsOneWidget);
      expect(find.text('Work'), findsOneWidget);
      expect(find.text('Room B'), findsOneWidget);
    });
  });

  group('today list', () {
    testWidgets('keeps all-day events in a separate strip and never in the '
        'timed list', (tester) async {
      final now = DateTime.utc(2026, 9, 18, 8);
      final allDay = occ(
        id: 'offsite',
        title: 'Team offsite',
        source: work,
        startUtc: berlinDayStartUtc,
        endUtc: berlinDayEndUtc,
        isAllDay: true,
      );
      final timed = occ(
        id: 'standup',
        title: 'Standup',
        source: work,
        startUtc: DateTime.utc(2026, 9, 18, 9),
        endUtc: DateTime.utc(2026, 9, 18, 9, 30),
      );
      // A second timed event so `standup` (the next meeting, shown in the
      // dominant card) does not hide the timed list entirely.
      final laterTimed = occ(
        id: 'review',
        title: 'Review',
        source: work,
        startUtc: DateTime.utc(2026, 9, 18, 10),
        endUtc: DateTime.utc(2026, 9, 18, 10, 30),
      );
      await pumpAgenda(
        tester,
        occurrences: [allDay, timed, laterTimed],
        clock: () => now,
      );

      expect(find.byKey(const ValueKey('all-day-strip')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('all-day-chip-offsite')),
        findsOneWidget,
      );
      // The all-day title appears exactly once: in the strip, never as a
      // timed row.
      expect(find.text('Team offsite'), findsOneWidget);
      expect(find.byKey(const ValueKey('agenda-row-offsite')), findsNothing);
      expect(find.byKey(const ValueKey('agenda-row-review')), findsOneWidget);
    });

    testWidgets('mutes past meetings but not upcoming ones', (tester) async {
      final now = DateTime.utc(2026, 9, 18, 8);
      final past = occ(
        id: 'past',
        title: 'Morning standup',
        source: work,
        startUtc: DateTime.utc(2026, 9, 18, 6, 30),
        endUtc: DateTime.utc(2026, 9, 18, 7, 15),
      );
      final upcoming = occ(
        id: 'next',
        title: 'Planning',
        source: work,
        startUtc: DateTime.utc(2026, 9, 18, 9),
        endUtc: DateTime.utc(2026, 9, 18, 10),
      );
      // `upcoming` is the next meeting and lives in the dominant card; this
      // later event is the un-muted row to compare against.
      final laterUpcoming = occ(
        id: 'later',
        title: 'Workshop',
        source: work,
        startUtc: DateTime.utc(2026, 9, 18, 11),
        endUtc: DateTime.utc(2026, 9, 18, 12),
      );
      await pumpAgenda(
        tester,
        occurrences: [past, upcoming, laterUpcoming],
        clock: () => now,
      );

      final pastOpacity = tester.widget<Opacity>(
        find
            .descendant(
              of: find.byKey(const ValueKey('agenda-row-past')),
              matching: find.byType(Opacity),
            )
            .first,
      );
      expect(pastOpacity.opacity, lessThan(1.0));

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('agenda-row-later')),
          matching: find.byType(Opacity),
        ),
        findsNothing,
      );
    });

    testWidgets('bounds the list to today plus a 24h look-ahead',
        (tester) async {
      final now = DateTime.utc(2026, 9, 18, 8);
      final today = occ(
        id: 'today',
        title: 'Today sync',
        source: work,
        startUtc: DateTime.utc(2026, 9, 18, 10),
        endUtc: DateTime.utc(2026, 9, 18, 11),
      );
      final withinWindow = occ(
        id: 'early-tomorrow',
        title: 'Tomorrow early',
        source: work,
        startUtc: DateTime.utc(2026, 9, 19, 7),
        endUtc: DateTime.utc(2026, 9, 19, 8),
      );
      final beyondWindow = occ(
        id: 'late-tomorrow',
        title: 'Tomorrow late',
        source: work,
        startUtc: DateTime.utc(2026, 9, 19, 12),
        endUtc: DateTime.utc(2026, 9, 19, 13),
      );
      await pumpAgenda(
        tester,
        occurrences: [today, withinWindow, beyondWindow],
        clock: () => now,
      );

      expect(find.text('Today sync'), findsOneWidget);
      expect(find.byKey(const ValueKey('later-section')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('agenda-row-early-tomorrow')),
        findsOneWidget,
      );
      expect(find.text('Tomorrow late'), findsNothing);
    });
  });

  group('empty states', () {
    testWidgets('distinguishes "no sources enabled"', (tester) async {
      final now = DateTime.utc(2026, 9, 18, 8);
      await pumpAgenda(
        tester,
        occurrences: const [],
        anySourcesEnabled: false,
        clock: () => now,
      );
      expect(
        find.byKey(const ValueKey('empty-noSourcesEnabled')),
        findsOneWidget,
      );
      expect(find.text('No calendars enabled'), findsOneWidget);
      expect(find.byKey(const ValueKey('empty-noEventsToday')), findsNothing);
      expect(find.byKey(const ValueKey('empty-sourceError')), findsNothing);
    });

    testWidgets('distinguishes "no events today"', (tester) async {
      final now = DateTime.utc(2026, 9, 18, 8);
      await pumpAgenda(
        tester,
        occurrences: const [],
        anySourcesEnabled: true,
        clock: () => now,
      );
      expect(
        find.byKey(const ValueKey('empty-noEventsToday')),
        findsOneWidget,
      );
      expect(find.text('Nothing on the agenda today'), findsOneWidget);
    });

    testWidgets('distinguishes "source error" and names the source',
        (tester) async {
      final now = DateTime.utc(2026, 9, 18, 8);
      await pumpAgenda(
        tester,
        occurrences: const [],
        anySourcesEnabled: true,
        statuses: const {
          'google:acct': SourceStatus.error('HTTP 401'),
        },
        sourceDisplayNames: const {'google:acct': 'Google Calendar'},
        clock: () => now,
      );
      expect(find.byKey(const ValueKey('empty-sourceError')), findsOneWidget);
      expect(find.text("Couldn't load your agenda"), findsOneWidget);
      expect(find.text('Google Calendar: HTTP 401'), findsOneWidget);
      expect(find.byKey(const ValueKey('empty-noEventsToday')), findsNothing);
    });
  });

  group('source status', () {
    testWidgets('shows an error banner naming the source and reason while '
        'keeping other sources\' events visible', (tester) async {
      final now = DateTime.utc(2026, 9, 18, 8);
      final event = occ(
        id: 'sync',
        title: 'Design sync',
        source: work,
        startUtc: DateTime.utc(2026, 9, 18, 9),
        endUtc: DateTime.utc(2026, 9, 18, 10),
      );
      await pumpAgenda(
        tester,
        occurrences: [event],
        statuses: const {
          'google:acct': SourceStatus.error('HTTP 401'),
        },
        sourceDisplayNames: const {'google:acct': 'Google Calendar'},
        clock: () => now,
      );

      expect(
        find.byKey(const ValueKey('source-error-banner')),
        findsOneWidget,
      );
      expect(find.text('Google Calendar: HTTP 401'), findsOneWidget);
      // The healthy source's event is still visible.
      expect(find.text('Design sync'), findsWidgets);
    });

    testWidgets('also names permission-denied sources', (tester) async {
      final now = DateTime.utc(2026, 9, 18, 8);
      final event = occ(
        id: 'sync',
        title: 'Design sync',
        source: work,
        startUtc: DateTime.utc(2026, 9, 18, 9),
        endUtc: DateTime.utc(2026, 9, 18, 10),
      );
      await pumpAgenda(
        tester,
        occurrences: [event],
        statuses: const {
          'google:acct':
              SourceStatus.permissionDenied('user denied access'),
        },
        sourceDisplayNames: const {'google:acct': 'Google Calendar'},
        clock: () => now,
      );

      expect(find.text('Google Calendar: user denied access'), findsOneWidget);
    });

    testWidgets('shows the last-refreshed time', (tester) async {
      final now = DateTime.utc(2026, 9, 18, 8);
      final event = occ(
        id: 'sync',
        title: 'Design sync',
        source: work,
        startUtc: DateTime.utc(2026, 9, 18, 9),
        endUtc: DateTime.utc(2026, 9, 18, 10),
      );
      await pumpAgenda(
        tester,
        occurrences: [event],
        lastRefreshedAt: now.subtract(const Duration(minutes: 5)),
        clock: () => now,
      );
      expect(find.text('Updated 5m ago'), findsOneWidget);

      await pumpAgenda(
        tester,
        occurrences: const [],
        anySourcesEnabled: false,
        lastRefreshedAt: null,
        clock: () => now,
      );
      expect(find.text('Not refreshed yet'), findsOneWidget);
    });

    testWidgets('supports manual refresh and pull-to-refresh',
        (tester) async {
      final now = DateTime.utc(2026, 9, 18, 8);
      var refreshCalls = 0;
      await pumpAgenda(
        tester,
        occurrences: const [],
        anySourcesEnabled: true,
        onRefresh: () async {
          refreshCalls++;
        },
        clock: () => now,
      );

      await tester.tap(find.byTooltip('Refresh'));
      await tester.pumpAndSettle();
      expect(refreshCalls, 1);

      await tester.fling(
        find.byType(ListView),
        const Offset(0, 300),
        1000,
      );
      await tester.pumpAndSettle();
      expect(refreshCalls, 2);
    });
  });

  group('goldens', () {
    Future<void> golden(
      WidgetTester tester,
      String name, {
      required Widget widget,
    }) async {
      await tester.binding.setSurfaceSize(const Size(420, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
            fontFamily: 'Roboto',
            useMaterial3: true,
          ),
          home: widget,
        ),
      );
      await tester.pump();
      await expectLater(
        find.byType(AgendaScreen),
        matchesGoldenFile('goldens/$name.png'),
      );
    }

    testWidgets('next meeting card', (tester) async {
      final now = DateTime.utc(2026, 9, 18, 8);
      final next = occ(
        id: 'sync',
        title: 'Design sync',
        source: work,
        startUtc: DateTime.utc(2026, 9, 18, 9),
        endUtc: DateTime.utc(2026, 9, 18, 9, 45),
        location: 'Room B',
        joinInfo: const MeetingJoinInfo(
          url: 'https://meet.example.com/abc',
        ),
      );
      final later = occ(
        id: 'client',
        title: 'Client call',
        source: personal,
        startUtc: DateTime.utc(2026, 9, 18, 11, 30),
        endUtc: DateTime.utc(2026, 9, 18, 12, 30),
      );
      final past = occ(
        id: 'standup',
        title: 'Standup',
        source: work,
        startUtc: DateTime.utc(2026, 9, 18, 6, 30),
        endUtc: DateTime.utc(2026, 9, 18, 7, 15),
      );
      final allDay = occ(
        id: 'offsite',
        title: 'Team offsite',
        source: work,
        startUtc: berlinDayStartUtc,
        endUtc: berlinDayEndUtc,
        isAllDay: true,
      );
      await golden(
        tester,
        'next_meeting_card',
        widget: AgendaScreen(
          occurrences: [past, next, later, allDay],
          statuses: const {},
          sourceDisplayNames: const {},
          anySourcesEnabled: true,
          lastRefreshedAt: now.subtract(const Duration(minutes: 5)),
          onRefresh: () async {},
          clock: () => now,
          timezone: berlin,
          onJoinMeeting: (_) {},
        ),
      );
    });

    testWidgets('empty: no sources enabled', (tester) async {
      final now = DateTime.utc(2026, 9, 18, 8);
      await golden(
        tester,
        'empty_no_sources',
        widget: AgendaScreen(
          occurrences: const [],
          statuses: const {},
          sourceDisplayNames: const {},
          anySourcesEnabled: false,
          lastRefreshedAt: null,
          onRefresh: () async {},
          clock: () => now,
          timezone: berlin,
          onJoinMeeting: (_) {},
        ),
      );
    });

    testWidgets('empty: no events today', (tester) async {
      final now = DateTime.utc(2026, 9, 18, 8);
      await golden(
        tester,
        'empty_no_events',
        widget: AgendaScreen(
          occurrences: const [],
          statuses: const {},
          sourceDisplayNames: const {},
          anySourcesEnabled: true,
          lastRefreshedAt: now.subtract(const Duration(minutes: 2)),
          onRefresh: () async {},
          clock: () => now,
          timezone: berlin,
          onJoinMeeting: (_) {},
        ),
      );
    });

    testWidgets('empty: source error', (tester) async {
      final now = DateTime.utc(2026, 9, 18, 8);
      await golden(
        tester,
        'empty_source_error',
        widget: AgendaScreen(
          occurrences: const [],
          statuses: const {
            'google:acct': SourceStatus.error('HTTP 401'),
            'ics:team': SourceStatus.error('timeout'),
          },
          sourceDisplayNames: const {
            'google:acct': 'Google Calendar',
            'ics:team': 'Team ICS feed',
          },
          anySourcesEnabled: true,
          lastRefreshedAt: now.subtract(const Duration(minutes: 2)),
          onRefresh: () async {},
          clock: () => now,
          timezone: berlin,
          onJoinMeeting: (_) {},
        ),
      );
    });
  });
}

/// Loads the bundled Roboto and MaterialIcons fonts so text and icons render
/// identically on every host (flutter_test otherwise falls back to the block
/// "Ahem" font, which would still be deterministic but unreadable).
Future<void> _loadTestFonts() async {
  await _loadFont('Roboto', const [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
  ]);
  await _loadFont('MaterialIcons', const ['MaterialIcons-Regular.otf']);
}

Future<void> _loadFont(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final file in files) {
    final bytes = File('test/fonts/$file').readAsBytesSync();
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
  }
  await loader.load();
}
