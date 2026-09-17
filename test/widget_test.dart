import 'package:attention_copilot/main.dart';
import 'package:attention_copilot/ui/onboarding_wizard.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app/test_fakes.dart';

void main() {
  testWidgets('the composed app builds and renders the onboarding wizard',
      (tester) async {
    final harness = SmokeHarness(anySourceConfigured: false);
    await tester.pumpWidget(
      ProviderScope(
        overrides: harness.overrides,
        child: const AttentionCopilotApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(OnboardingWizard), findsOneWidget);
  });
}
