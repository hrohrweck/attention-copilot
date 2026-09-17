import 'package:flutter/material.dart';

void main() {
  runApp(const AttentionCopilotApp());
}

/// Minimal application shell.
///
/// The real composition root (providers, timezone bootstrap, scheduler
/// wiring) lands in the later todos. This shell exists so the scaffold
/// builds, analyzes and tests cleanly from day one.
class AttentionCopilotApp extends StatelessWidget {
  const AttentionCopilotApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Attention Copilot',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: const Scaffold(
        body: Center(child: Text('Attention Copilot')),
      ),
    );
  }
}
