/// The diagnostics screen: a presentation-only view over injected state,
/// plus the pure [buildDiagnosticsReport] function both the view and the
/// copy button feed from.
///
/// No I/O and no state live here. Everything to render — the engine's
/// departure records, per-source statuses, [PresenceState], capability
/// statuses and the next trigger instant — is injected, so the widget is a
/// pure function of its inputs.
library;

import 'package:flutter/material.dart';

import '../domain/alert_engine.dart';
import '../presence/presence_state.dart';
import 'log_sink.dart';

/// How healthy one data source (calendar connector) is.
enum SourceStatus { ok, degraded, unavailable }

/// Per-source diagnostics: a status plus, for non-ok sources, the error.
class SourceDiagnostics {
  const SourceDiagnostics(this.status, [this.error]);

  final SourceStatus status;
  final String? error;
}

/// How healthy one capability is.
enum CapabilityStatus { ok, degraded, unavailable }

/// A capability's status and, when it is not ok, the human-readable reason.
class Capability {
  const Capability(this.status, [this.reason]);

  final CapabilityStatus status;
  final String? reason;
}

/// The user-facing label for an [AlertRecordReason].
String reasonLabel(AlertRecordReason reason) => switch (reason) {
      AlertRecordReason.fired => 'fired',
      AlertRecordReason.deferredLocked => 'deferred-locked',
      AlertRecordReason.deferredAway => 'deferred-away',
      AlertRecordReason.meetingEnded => 'meeting-ended',
      AlertRecordReason.acknowledged => 'acknowledged',
      AlertRecordReason.occurrenceRemoved => 'occurrence-removed',
    };

/// Builds the full diagnostics report as a redacted plain-text string.
///
/// Renders presence (lock/idle/active state), per-source statuses and
/// errors, capability statuses (a degraded capability is reported as
/// `degraded`, never `ok`), the next trigger instant, and the last 24h of
/// departure records labelled with [reasonLabel]. The finished report is
/// passed through [redactSecrets], so anything it embeds (e.g. a source
/// error containing a bearer URL) cannot leak.
String buildDiagnosticsReport({
  required List<AlertEngineRecord> records,
  required Map<String, SourceDiagnostics> sources,
  required PresenceState presence,
  required Map<String, Capability> capabilities,
  required DateTime? nextTrigger,
  required DateTime now,
}) {
  final buffer = StringBuffer()
    ..writeln('Attention Copilot diagnostics')
    ..writeln('generated: ${now.toUtc().toIso8601String()}')
    ..writeln()
    ..writeln('Presence')
    ..writeln('  locked: ${presence.locked}')
    ..writeln('  idleFor: ${presence.idleFor.inSeconds}s')
    ..writeln('  active: ${presence.active}')
    ..writeln('  supported: ${presence.supported}');
  if (!presence.supported && presence.unsupportedReason != null) {
    buffer.writeln('  unsupported: ${presence.unsupportedReason}');
  }
  if (presence.degraded && presence.degradedReason != null) {
    buffer.writeln('  degraded: ${presence.degradedReason}');
  }
  if (presence.mechanism != null) {
    buffer.writeln('  mechanism: ${presence.mechanism}');
  }

  buffer.writeln();
  buffer.writeln('Sources');
  if (sources.isEmpty) {
    buffer.writeln('  (none)');
  } else {
    final names = sources.keys.toList()..sort();
    for (final name in names) {
      final diagnostics = sources[name]!;
      final error = diagnostics.error;
      buffer.writeln(
        '  $name: ${diagnostics.status.name}'
        '${error == null ? '' : ' ($error)'}',
      );
    }
  }

  buffer.writeln();
  buffer.writeln('Capabilities');
  if (capabilities.isEmpty) {
    buffer.writeln('  (none)');
  } else {
    final names = capabilities.keys.toList()..sort();
    for (final name in names) {
      final capability = capabilities[name]!;
      final reason = capability.reason;
      buffer.writeln(
        '  $name: ${capability.status.name}'
        '${reason == null ? '' : ' ($reason)'}',
      );
    }
  }

  buffer.writeln();
  buffer.writeln(
    'Next trigger: ${nextTrigger?.toUtc().toIso8601String() ?? 'none'}',
  );
  buffer.writeln();

  final cutoff = now.toUtc().subtract(const Duration(hours: 24));
  final recent = records
      .where((record) => !record.atUtc.toUtc().isBefore(cutoff))
      .toList()
    ..sort((a, b) => a.atUtc.compareTo(b.atUtc));
  buffer.writeln('Last 24h (${recent.length})');
  for (final record in recent) {
    buffer.writeln(
      '  ${record.atUtc.toUtc().toIso8601String()} '
      '${record.alarmId} ${record.occurrenceId} ${reasonLabel(record.reason)}',
    );
  }

  return redactSecrets(buffer.toString());
}

/// Presentation-only diagnostics view. Renders [buildDiagnosticsReport] for
/// the injected inputs and offers a "copy diagnostics" button that hands the
/// already-redacted report to the injected [onCopyReport] callback.
class DiagnosticsView extends StatelessWidget {
  const DiagnosticsView({
    super.key,
    required this.records,
    required this.sources,
    required this.presence,
    required this.capabilities,
    required this.nextTrigger,
    required this.onCopyReport,
    required this.now,
  });

  /// The engine's departure records (fires, defers, retirements,
  /// acknowledgements).
  final List<AlertEngineRecord> records;

  /// Per-source statuses and errors, keyed by source name.
  final Map<String, SourceDiagnostics> sources;

  /// Current lock/idle/active state.
  final PresenceState presence;

  /// Capability statuses keyed by capability name.
  final Map<String, Capability> capabilities;

  /// The next planned trigger instant, or `null` when nothing is pending.
  final DateTime? nextTrigger;

  /// Called with the redacted report when the user taps the copy button.
  final void Function(String redactedReport) onCopyReport;

  /// The reference instant for the 24h window.
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final report = buildDiagnosticsReport(
      records: records,
      sources: sources,
      presence: presence,
      capabilities: capabilities,
      nextTrigger: nextTrigger,
      now: now,
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(report, style: const TextStyle(fontFamily: 'monospace')),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: () => onCopyReport(report),
            child: const Text('Copy diagnostics'),
          ),
        ],
      ),
    );
  }
}
