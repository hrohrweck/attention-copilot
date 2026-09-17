import 'package:attention_copilot/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app shell builds and renders', (tester) async {
    await tester.pumpWidget(const AttentionCopilotApp());

    expect(find.text('Attention Copilot'), findsOneWidget);
  });
}
