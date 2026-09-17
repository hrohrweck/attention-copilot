/// Widget tests for [RingingAlertView]: the full-screen Android ringing
/// surface rendered inside `AlertActivity`.
///
/// Locks the acknowledgement gate:
///   * acknowledgement (dismiss | join) is the only way a ringing alert ends;
///   * the system back action is consumed and re-raised instead of dismissing;
///   * the Join button renders only when a conference URL exists;
///   * the "still ringing" escalation indicator visibly advances.
library;

import 'package:attention_copilot/domain/alert_policy.dart';
import 'package:attention_copilot/domain/models/meeting_join_info.dart';
import 'package:attention_copilot/ui/ringing_alert_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final startUtc = DateTime.utc(2026, 9, 17, 14, 30);

  /// Hosts the view the way `AlertActivity` will: a full-screen route inside
  /// a Material app (required for [PopScope] and theme access).
  Widget host(RingingAlertView view) => MaterialApp(
        home: Scaffold(body: view),
      );

  /// The exact start-time string the view renders for [startUtc], computed
  /// the same way (local HH:mm) so the assertion is timezone-independent.
  String startsAt(DateTime utc) {
    final local = utc.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return 'Starts at $hour:$minute';
  }

  testWidgets('renders meeting title, start time and countdown state',
      (tester) async {
    await tester.pumpWidget(host(RingingAlertView(
      title: 'Standup',
      startUtc: startUtc,
      nowUtc: startUtc.subtract(const Duration(minutes: 5)),
      onAcknowledgement: (_) {},
    )));

    expect(find.text('Standup'), findsOneWidget);
    expect(find.text(startsAt(startUtc)), findsOneWidget);
    expect(find.text('starting in 5 minutes'), findsOneWidget);
    expect(find.text('in progress'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('shows "in progress" once the meeting has started',
      (tester) async {
    await tester.pumpWidget(host(RingingAlertView(
      title: 'Standup',
      startUtc: startUtc,
      nowUtc: startUtc.add(const Duration(minutes: 3)),
      onAcknowledgement: (_) {},
    )));

    expect(find.text('in progress'), findsOneWidget);
    expect(find.textContaining('starting in'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('countdown ticks coarsely, minute by minute', (tester) async {
    await tester.pumpWidget(host(RingingAlertView(
      title: 'Standup',
      startUtc: startUtc,
      nowUtc: startUtc.subtract(const Duration(minutes: 10)),
      onAcknowledgement: (_) {},
    )));

    expect(find.text('starting in 10 minutes'), findsOneWidget);

    await tester.pump(const Duration(minutes: 1));
    expect(find.text('starting in 9 minutes'), findsOneWidget);

    await tester.pump(const Duration(minutes: 9));
    expect(find.text('in progress'), findsOneWidget);
    expect(find.textContaining('starting in'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Dismiss calls acknowledge exactly once with the dismiss action',
      (tester) async {
    final calls = <AcknowledgementAction>[];
    await tester.pumpWidget(host(RingingAlertView(
      title: 'Standup',
      startUtc: startUtc,
      nowUtc: startUtc.subtract(const Duration(minutes: 5)),
      onAcknowledgement: calls.add,
    )));

    await tester.tap(find.byKey(RingingAlertView.dismissKey));
    await tester.pump();

    expect(calls, hasLength(1));
    expect(calls.single, AcknowledgementAction.dismiss);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Join is absent without a conference URL', (tester) async {
    await tester.pumpWidget(host(RingingAlertView(
      title: 'Standup',
      startUtc: startUtc,
      nowUtc: startUtc.subtract(const Duration(minutes: 5)),
      onAcknowledgement: (_) {},
    )));

    expect(find.byKey(RingingAlertView.joinKey), findsNothing);
    expect(find.text('Join'), findsNothing);
    // Dismiss remains the only offered action.
    expect(find.byKey(RingingAlertView.dismissKey), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Join is present with a conference URL and maps to the join '
      'action', (tester) async {
    final calls = <AcknowledgementAction>[];
    await tester.pumpWidget(host(RingingAlertView(
      title: 'Standup',
      startUtc: startUtc,
      nowUtc: startUtc.subtract(const Duration(minutes: 5)),
      onAcknowledgement: calls.add,
      joinInfo: const MeetingJoinInfo(url: 'https://meet.example.com/standup'),
    )));

    expect(find.byKey(RingingAlertView.joinKey), findsOneWidget);

    await tester.tap(find.byKey(RingingAlertView.joinKey));
    await tester.pump();

    expect(calls, hasLength(1));
    expect(calls.single, AcknowledgementAction.join);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('back action is consumed: no dismissal, re-raise instead',
      (tester) async {
    final calls = <AcknowledgementAction>[];
    var dismissAttempts = 0;
    await tester.pumpWidget(host(RingingAlertView(
      title: 'Standup',
      startUtc: startUtc,
      nowUtc: startUtc.subtract(const Duration(minutes: 5)),
      onAcknowledgement: calls.add,
      onDismissAttempted: () => dismissAttempts++,
    )));

    // Simulate the Android system back button.
    await tester.binding.handlePopRoute();
    await tester.pump();

    // Still ringing: the view is not dismissed and nothing acknowledged.
    expect(find.byType(RingingAlertView), findsOneWidget);
    expect(calls, isEmpty);
    // The blocked back attempt is reported so the host can re-raise.
    expect(dismissAttempts, 1);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('escalation indicator is visible and advances as steps apply',
      (tester) async {
    Widget build(List<EscalationAction> actions) => host(RingingAlertView(
          title: 'Standup',
          startUtc: startUtc,
          nowUtc: startUtc.subtract(const Duration(minutes: 5)),
          onAcknowledgement: (_) {},
          escalationActions: actions,
        ));

    await tester.pumpWidget(build(const []));
    expect(find.text('Still ringing'), findsOneWidget);

    await tester.pumpWidget(build(const [EscalationAction.repeatAudioCycle]));
    expect(find.textContaining('repeating alarm'), findsOneWidget);

    await tester.pumpWidget(build(const [
      EscalationAction.repeatAudioCycle,
      EscalationAction.raiseVolume,
      EscalationAction.reRaiseWindow,
      EscalationAction.changeAccent,
    ]));
    expect(find.textContaining('accent intensified'), findsOneWidget);

    await tester.pumpWidget(build(const [
      EscalationAction.repeatAudioCycle,
      EscalationAction.raiseVolume,
      EscalationAction.reRaiseWindow,
      EscalationAction.changeAccent,
      EscalationAction.holdWindowAndRemind,
    ]));
    expect(find.textContaining('holding with periodic reminder'),
        findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('both actions have touch targets of at least 48dp',
      (tester) async {
    await tester.pumpWidget(host(RingingAlertView(
      title: 'Standup',
      startUtc: startUtc,
      nowUtc: startUtc.subtract(const Duration(minutes: 5)),
      onAcknowledgement: (_) {},
      joinInfo: const MeetingJoinInfo(url: 'https://meet.example.com/standup'),
    )));

    final join = tester.getSize(find.byKey(RingingAlertView.joinKey));
    final dismiss = tester.getSize(find.byKey(RingingAlertView.dismissKey));
    expect(join.width, greaterThanOrEqualTo(48));
    expect(join.height, greaterThanOrEqualTo(48));
    expect(dismiss.width, greaterThanOrEqualTo(48));
    expect(dismiss.height, greaterThanOrEqualTo(48));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('exposes semantics labels and a coarse live region',
      (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(host(RingingAlertView(
      title: 'Standup',
      startUtc: startUtc,
      nowUtc: startUtc.subtract(const Duration(minutes: 5)),
      onAcknowledgement: (_) {},
      joinInfo: const MeetingJoinInfo(url: 'https://meet.example.com/standup'),
    )));

    expect(find.bySemanticsLabel(RingingAlertView.dismissSemanticsLabel),
        findsOneWidget);
    expect(find.bySemanticsLabel(RingingAlertView.joinSemanticsLabel),
        findsOneWidget);

    final live =
        tester.getSemantics(find.bySemanticsLabel('starting in 5 minutes'));
    expect(live.flagsCollection.isLiveRegion, isTrue);

    // Coarse: the live label changes at minute boundaries, not per second.
    await tester.pump(const Duration(seconds: 30));
    expect(find.bySemanticsLabel('starting in 5 minutes'), findsOneWidget);
    await tester.pump(const Duration(seconds: 30));
    expect(find.bySemanticsLabel('starting in 4 minutes'), findsOneWidget);

    handle.dispose();
    await tester.pumpWidget(const SizedBox());
  });
}
