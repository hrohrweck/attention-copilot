import 'package:attention_copilot/ui/onboarding_wizard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(home: child);

/// Taps "Next" three times: sources -> lead times -> test alert -> finish.
Future<void> _goToLastStep(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.tap(find.byKey(const Key('wizard-next')));
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('every source state renders distinctly', (tester) async {
    final wizard = OnboardingWizard(
      sources: const [
        WizardCalendarSource(
          id: 'native',
          displayName: 'Native calendar',
          status: WizardSourceStatus.notConfigured(),
        ),
        WizardCalendarSource(
          id: 'perm',
          displayName: 'Needs permission source',
          status: WizardSourceStatus.needsPermission(),
        ),
        WizardCalendarSource(
          id: 'denied',
          displayName: 'Denied source',
          status: WizardSourceStatus.permissionDenied(),
        ),
        WizardCalendarSource(
          id: 'conn',
          displayName: 'Connected source',
          status: WizardSourceStatus.connected(),
        ),
        WizardCalendarSource(
          id: 'broken',
          displayName: 'Broken source',
          status: WizardSourceStatus.error('boom'),
        ),
      ],
      onTestAlert: () async {},
      onFinish: () {},
    );

    await tester.pumpWidget(_wrap(wizard));

    expect(find.text('Not configured'), findsOneWidget);
    expect(find.text('Needs permission'), findsOneWidget);
    expect(find.text('Permission denied'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Error: boom'), findsOneWidget);
  });

  testWidgets('Google path validates a non-empty client ID before connect',
      (tester) async {
    final connected = <String>[];
    final wizard = OnboardingWizard(
      sources: const [],
      onTestAlert: () async {},
      onFinish: () {},
      onConnectGoogle: connected.add,
    );

    await tester.pumpWidget(_wrap(wizard));

    // Empty client ID: connect is rejected and the callback never fires.
    await tester.tap(find.byKey(const Key('google-connect-button')));
    await tester.pump();
    expect(find.text('Enter a Google client ID'), findsOneWidget);
    expect(connected, isEmpty);

    // Non-empty client ID: connect proceeds with the entered value.
    await tester.enterText(
      find.byKey(const Key('google-client-id-field')),
      'abc123',
    );
    await tester.tap(find.byKey(const Key('google-connect-button')));
    await tester.pump();
    expect(connected, ['abc123']);
  });

  testWidgets(
      'permission-denied source shows the settings action and never '
      'continues as connected', (tester) async {
    final opened = <String>[];
    var finished = false;
    final wizard = OnboardingWizard(
      sources: const [
        WizardCalendarSource(
          id: 'denied',
          displayName: 'Denied source',
          status: WizardSourceStatus.permissionDenied('user denied'),
        ),
      ],
      onTestAlert: () async {},
      onFinish: () => finished = true,
      onOpenSettings: opened.add,
    );

    await tester.pumpWidget(_wrap(wizard));

    // The denied source surfaces the "directing to settings" action.
    final settingsAction = find.byKey(const Key('open-settings-denied'));
    expect(settingsAction, findsOneWidget);
    await tester.tap(settingsAction);
    await tester.pump();
    expect(opened, ['denied']);

    // It is still denied - never silently continued as connected.
    expect(find.text('Permission denied'), findsOneWidget);

    // And the wizard does not allow finishing from a denied source alone.
    await _goToLastStep(tester);
    final finishButton = tester
        .widget<ElevatedButton>(find.byKey(const Key('wizard-finish')));
    expect(finishButton.onPressed, isNull);
    await tester.tap(find.byKey(const Key('wizard-finish')));
    await tester.pump();
    expect(finished, isFalse);
  });

  testWidgets('finish is enabled only once at least one source is configured',
      (tester) async {
    var finished = 0;

    Widget build(List<WizardCalendarSource> sources) => OnboardingWizard(
          key: UniqueKey(),
          sources: sources,
          onTestAlert: () async {},
          onFinish: () => finished++,
        );

    // Nothing configured yet: finish must be disabled.
    await tester.pumpWidget(_wrap(build(const [
      WizardCalendarSource(
        id: 'a',
        displayName: 'Source A',
        status: WizardSourceStatus.notConfigured(),
      ),
    ])));
    await _goToLastStep(tester);
    expect(
      tester
          .widget<ElevatedButton>(find.byKey(const Key('wizard-finish')))
          .onPressed,
      isNull,
    );

    // One connected source: finish is enabled and calls onFinish.
    await tester.pumpWidget(_wrap(build(const [
      WizardCalendarSource(
        id: 'a',
        displayName: 'Source A',
        status: WizardSourceStatus.connected(),
      ),
    ])));
    await _goToLastStep(tester);
    await tester.tap(find.byKey(const Key('wizard-finish')));
    await tester.pump();
    expect(finished, 1);
  });

  testWidgets('test-alert step invokes the injected onTestAlert',
      (tester) async {
    var alerts = 0;
    final wizard = OnboardingWizard(
      sources: const [
        WizardCalendarSource(
          id: 'a',
          displayName: 'Source A',
          status: WizardSourceStatus.connected(),
        ),
      ],
      onTestAlert: () async => alerts++,
      onFinish: () {},
    );

    await tester.pumpWidget(_wrap(wizard));
    await tester.tap(find.byKey(const Key('wizard-next')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wizard-next')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('send-test-alert')));
    await tester.pumpAndSettle();
    expect(alerts, 1);
    expect(find.text('Test alert sent'), findsOneWidget);
  });
}
