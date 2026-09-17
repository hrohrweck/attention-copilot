import 'package:attention_copilot/diagnostics/diagnostics_view.dart';
import 'package:attention_copilot/domain/alert_engine.dart';
import 'package:attention_copilot/presence/presence_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  final now = DateTime.utc(2026, 9, 17, 10);

  const lockedPresence = PresenceState(
    locked: true,
    idleFor: Duration.zero,
    active: false,
    mechanism: 'fake',
  );
  const activePresence = PresenceState(
    locked: false,
    idleFor: Duration(seconds: 30),
    active: true,
    mechanism: 'fake',
  );

  testWidgets(
    'renders locked -> deferred -> unlocked -> fired for a scripted scenario',
    (tester) async {
      final deferred = AlertEngineRecord(
        alarmId: 'a1',
        occurrenceId: 'o1',
        reason: AlertRecordReason.deferredLocked,
        atUtc: now.subtract(const Duration(minutes: 30)),
      );
      final fired = AlertEngineRecord(
        alarmId: 'a1',
        occurrenceId: 'o1',
        reason: AlertRecordReason.fired,
        atUtc: now.subtract(const Duration(minutes: 25)),
      );

      // While locked: the trigger was deferred.
      await tester.pumpWidget(_wrap(DiagnosticsView(
        records: [deferred],
        sources: const {},
        presence: lockedPresence,
        capabilities: const {},
        nextTrigger: null,
        now: now,
        onCopyReport: (_) {},
      )));
      expect(find.textContaining('locked: true'), findsOneWidget);
      expect(find.textContaining('active: false'), findsOneWidget);
      expect(find.textContaining('deferred-locked'), findsOneWidget);
      expect(find.textContaining('fired'), findsNothing);

      // After unlock: the same trigger fired.
      await tester.pumpWidget(_wrap(DiagnosticsView(
        records: [deferred, fired],
        sources: const {},
        presence: activePresence,
        capabilities: const {},
        nextTrigger: null,
        now: now,
        onCopyReport: (_) {},
      )));
      expect(find.textContaining('locked: false'), findsOneWidget);
      expect(find.textContaining('active: true'), findsOneWidget);
      expect(find.textContaining('deferred-locked'), findsOneWidget);
      expect(find.textContaining('fired'), findsOneWidget);
    },
  );

  testWidgets('a degraded capability shows its reason and never claims ok',
      (tester) async {
    const capabilities = {
      'macos-screen-lock': Capability(
        CapabilityStatus.degraded,
        'screen-lock key absent',
      ),
    };

    await tester.pumpWidget(_wrap(DiagnosticsView(
      records: const [],
      sources: const {},
      presence: activePresence,
      capabilities: capabilities,
      nextTrigger: null,
      now: now,
      onCopyReport: (_) {},
    )));

    expect(find.textContaining('screen-lock key absent'), findsOneWidget);

    final report = buildDiagnosticsReport(
      records: const [],
      sources: const {},
      presence: activePresence,
      capabilities: capabilities,
      nextTrigger: null,
      now: now,
    );
    final capLine =
        report.split('\n').firstWhere((l) => l.contains('macos-screen-lock'));
    expect(capLine, contains('degraded'));
    expect(capLine, isNot(contains('ok')));
  });

  testWidgets('copy diagnostics calls onCopyReport with a redacted report',
      (tester) async {
    String? copied;
    const sources = {
      'ics': SourceDiagnostics(
        SourceStatus.unavailable,
        'https://cal.example.com/feed.ics?token=sekret-ics',
      ),
    };

    await tester.pumpWidget(_wrap(DiagnosticsView(
      records: const [],
      sources: sources,
      presence: activePresence,
      capabilities: const {},
      nextTrigger: now.add(const Duration(minutes: 5)),
      now: now,
      onCopyReport: (report) => copied = report,
    )));

    // The secret never renders, either.
    expect(find.textContaining('sekret-ics'), findsNothing);
    expect(find.textContaining('Next trigger:'), findsOneWidget);

    await tester.tap(find.text('Copy diagnostics'));
    expect(copied, isNotNull);
    expect(copied, contains('[REDACTED]'));
    expect(copied, isNot(contains('sekret-ics')));
  });
}
