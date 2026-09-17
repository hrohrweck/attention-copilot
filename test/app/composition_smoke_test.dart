/// Composition-root smoke test: boots the fully composed app with every
/// plugin/IO seam overridden by fakes and asserts the routing contract —
/// onboarding when no source is configured, the agenda when one is — and
/// that Settings and Diagnostics are reachable.
library;

import 'package:attention_copilot/app/composition_root.dart';
import 'package:attention_copilot/diagnostics/diagnostics_view.dart';
import 'package:attention_copilot/main.dart';
import 'package:attention_copilot/ui/agenda_screen.dart';
import 'package:attention_copilot/ui/onboarding_wizard.dart';
import 'package:attention_copilot/ui/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'test_fakes.dart';

Future<void> pumpComposedApp(
  WidgetTester tester,
  SmokeHarness harness,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: harness.overrides,
      child: const AttentionCopilotApp(),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() {
    tzdata.initializeTimeZones();
  });

  testWidgets(
    'boots to the agenda when a source is configured, plans the engine and '
    'navigates Settings -> Diagnostics',
    (tester) async {
      final harness = SmokeHarness(anySourceConfigured: true);
      await pumpComposedApp(tester, harness);

      // The home route is the agenda, rendering the fake source's meeting.
      expect(find.byType(AgendaScreen), findsOneWidget);
      expect(find.text('Smoke test meeting'), findsOneWidget);

      // The engine was restored and re-planned with the meeting's trigger.
      expect(harness.scheduler.scheduled, isNotEmpty);

      // Settings is reachable from the home route.
      await tester.tap(find.byKey(HomeHost.settingsButtonKey));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);

      // Diagnostics is reachable from Settings (the settings list builds
      // lazily, so scroll the tile into view first).
      final diagnosticsTile = find.byKey(const Key('settings.diagnostics'));
      await tester.scrollUntilVisible(
        diagnosticsTile,
        400,
        scrollable: find
            .descendant(
              of: find.byType(SettingsScreen),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(diagnosticsTile);
      await tester.pumpAndSettle();
      expect(find.byType(DiagnosticsView), findsOneWidget);
      expect(
        find.textContaining('Attention Copilot diagnostics'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'boots to the onboarding wizard when no source is configured and '
    'Settings is still reachable',
    (tester) async {
      final harness = SmokeHarness(anySourceConfigured: false);
      await pumpComposedApp(tester, harness);

      // The home route is the onboarding wizard.
      expect(find.byType(OnboardingWizard), findsOneWidget);
      expect(find.text('Choose your calendar sources'), findsOneWidget);

      // Nothing was scheduled for the engine (no occurrences, no triggers).
      expect(harness.scheduler.scheduled, isEmpty);

      // Settings is reachable from the wizard home too.
      await tester.tap(find.byKey(HomeHost.settingsButtonKey));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
    },
  );
}
