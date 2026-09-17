import 'package:attention_copilot/app/composition_root.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Application entry point: initialises the binding and the bundled tzdata
/// database, resolves the device's IANA timezone, then boots the composed
/// app inside a [ProviderScope] whose timezone provider is pinned to the
/// resolved zone.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final timezone = await resolveLocalTimezone();
  runApp(
    ProviderScope(
      overrides: [
        localTimezoneProvider.overrideWith((ref) => timezone),
      ],
      child: const AttentionCopilotApp(),
    ),
  );
}

/// The composed application root: starts the one-shot bootstrapper and the
/// engine heartbeat, then renders the route table (home = onboarding wizard
/// or agenda, plus Settings and Diagnostics).
class AttentionCopilotApp extends ConsumerWidget {
  const AttentionCopilotApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watched once: these providers run the app-start side effects.
    ref.watch(bootstrapperProvider);
    ref.watch(heartbeatProvider);

    return MaterialApp(
      navigatorKey: ref.watch(navigatorKeyProvider),
      title: 'Attention Copilot',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: const HomeRouter(),
      routes: {
        SettingsRoute.path: (_) => const SettingsRoute(),
        DiagnosticsRoute.path: (_) => const DiagnosticsRoute(),
      },
    );
  }
}
