import 'package:flutter/material.dart';

/// Setup stage of one calendar source during onboarding.
///
/// Distinct from the runtime [SourceStatusKind] in
/// `lib/data/sources/source.dart`: this is the wizard's own view of whether
/// a source is usable, carrying the extra `not-configured` and
/// `needs-permission` stages that only exist before first sync.
enum WizardSourceStage {
  /// The source exists but nothing has been set up yet.
  notConfigured,

  /// The source needs a platform permission grant before it can connect.
  needsPermission,

  /// Permission was requested and denied; the user must open system
  /// settings. Never treated as configured.
  permissionDenied,

  /// The source is fully set up and can deliver events.
  connected,

  /// Setup failed; [WizardSourceStatus.reason] carries the cause.
  error,
}

/// Immutable setup state of one wizard source.
class WizardSourceStatus {
  const WizardSourceStatus._(this.stage, this.reason);

  const WizardSourceStatus.notConfigured()
      : this._(WizardSourceStage.notConfigured, null);

  const WizardSourceStatus.needsPermission()
      : this._(WizardSourceStage.needsPermission, null);

  const WizardSourceStatus.permissionDenied([String? reason])
      : this._(WizardSourceStage.permissionDenied, reason);

  const WizardSourceStatus.connected()
      : this._(WizardSourceStage.connected, null);

  const WizardSourceStatus.error(String reason)
      : this._(WizardSourceStage.error, reason);

  final WizardSourceStage stage;

  /// Failure cause when [stage] is [WizardSourceStage.error]; also carried
  /// optionally by [WizardSourceStage.permissionDenied].
  final String? reason;

  bool get isConnected => stage == WizardSourceStage.connected;

  bool get isPermissionDenied => stage == WizardSourceStage.permissionDenied;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WizardSourceStatus &&
          other.stage == stage &&
          other.reason == reason;

  @override
  int get hashCode => Object.hash(stage, reason);

  @override
  String toString() => 'WizardSourceStatus($stage, $reason)';
}

/// A single calendar source presented in the wizard's source-selection step.
class WizardCalendarSource {
  const WizardCalendarSource({
    required this.id,
    required this.displayName,
    required this.status,
  });

  /// Stable identity, also used for action keys like
  /// `open-settings-<id>`.
  final String id;

  final String displayName;

  final WizardSourceStatus status;

  /// Whether this source counts towards enabling finish.
  bool get isConfigured => status.isConnected;
}

/// Presentation-only onboarding wizard.
///
/// Steps:
///   1. choose calendar sources - per-source toggles with distinct states,
///      a Google "paste client ID" section and an ICS URL entry;
///   2. choose default lead times;
///   3. verify with a test alert ([OnboardingWizard.onTestAlert]);
///   4. finish onto the agenda ([OnboardingWizard.onFinish]), enabled only
///      once at least one source is configured.
///
/// All side effects are injected callbacks; the wizard never mutates source
/// state itself, so a `permission-denied` source can never silently become
/// connected.
class OnboardingWizard extends StatefulWidget {
  const OnboardingWizard({
    super.key,
    required this.sources,
    required this.onTestAlert,
    required this.onFinish,
    this.onConnectGoogle,
    this.onAddIcsUrl,
    this.onRequestPermission,
    this.onOpenSettings,
    this.leadTimePresets = const [
      Duration.zero,
      Duration(minutes: 5),
      Duration(minutes: 10),
      Duration(minutes: 15),
    ],
  });

  /// Sources with their current setup states. The wizard re-renders when a
  /// parent updates this list (e.g. after a connect completes).
  final List<WizardCalendarSource> sources;

  /// Fired when the user asks for a test alert on the verify step.
  final Future<void> Function() onTestAlert;

  /// Fired when the user finishes the wizard. Only reachable when at least
  /// one source is configured.
  final VoidCallback onFinish;

  /// Fired with the pasted client ID after it passes validation.
  final ValueChanged<String>? onConnectGoogle;

  /// Fired with the entered ICS URL.
  final ValueChanged<String>? onAddIcsUrl;

  /// Fired with a source id whose permission grant should be requested.
  final ValueChanged<String>? onRequestPermission;

  /// Fired with a source id whose permission was denied; the parent should
  /// direct the user to system settings.
  final ValueChanged<String>? onOpenSettings;

  /// Default lead-time choices offered on step 2. `Duration.zero` renders as
  /// "At meeting time".
  final List<Duration> leadTimePresets;

  @override
  State<OnboardingWizard> createState() => _OnboardingWizardState();
}

class _OnboardingWizardState extends State<OnboardingWizard> {
  static const _steps = 4;

  final _googleClientIdFormKey = GlobalKey<FormState>();
  final _googleClientIdController = TextEditingController();
  final _icsUrlController = TextEditingController();
  final _toggleState = <String, bool>{};

  int _step = 0;
  late Duration _leadTime;
  bool _testAlertSent = false;

  bool get _hasConfiguredSource => widget.sources.any((s) => s.isConfigured);

  @override
  void initState() {
    super.initState();
    _leadTime = widget.leadTimePresets.isEmpty
        ? const Duration(minutes: 10)
        : widget.leadTimePresets.first;
  }

  @override
  void dispose() {
    _googleClientIdController.dispose();
    _icsUrlController.dispose();
    super.dispose();
  }

  void _connectGoogle() {
    if (!_googleClientIdFormKey.currentState!.validate()) {
      return;
    }
    widget.onConnectGoogle?.call(_googleClientIdController.text.trim());
  }

  String _leadTimeLabel(Duration d) {
    if (d == Duration.zero) {
      return 'At meeting time';
    }
    return '${d.inMinutes} min before';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Step ${_step + 1} of $_steps',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 8),
              Expanded(child: switch (_step) {
                0 => _buildSourcesStep(),
                1 => _buildLeadTimesStep(),
                2 => _buildTestAlertStep(),
                _ => _buildFinishStep(),
              }),
              _buildNavigation(),
            ],
          ),
        ),
      ),
    );
  }

  // Step 1: choose calendar sources.
  Widget _buildSourcesStep() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Choose your calendar sources',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          for (final source in widget.sources) _buildSourceTile(source),
          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 8),
          Text(
            'Google Calendar',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Form(
            key: _googleClientIdFormKey,
            child: TextFormField(
              key: const Key('google-client-id-field'),
              controller: _googleClientIdController,
              decoration: const InputDecoration(
                labelText: 'OAuth client ID',
                hintText: 'Paste your Google OAuth client ID',
                border: OutlineInputBorder(),
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'Enter a Google client ID';
                }
                return null;
              },
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton(
              key: const Key('google-connect-button'),
              onPressed: _connectGoogle,
              child: const Text('Connect'),
            ),
          ),
          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 8),
          Text(
            'ICS feed',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('ics-url-field'),
            controller: _icsUrlController,
            decoration: const InputDecoration(
              labelText: 'Feed URL',
              hintText: 'https://example.com/calendar.ics',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton(
              key: const Key('ics-add-button'),
              onPressed: _icsUrlController.text.trim().isEmpty
                  ? null
                  : () =>
                      widget.onAddIcsUrl?.call(_icsUrlController.text.trim()),
              child: const Text('Add feed'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSourceTile(WizardCalendarSource source) {
    final isToggled =
        _toggleState[source.id] ?? source.status.isConnected;
    final status = source.status;

    final Widget statusLabel;
    final Widget? statusAction;
    switch (status.stage) {
      case WizardSourceStage.notConfigured:
        statusLabel = Text(
          'Not configured',
          key: Key('wizard-source-status-${source.id}'),
        );
        statusAction = null;
      case WizardSourceStage.needsPermission:
        statusLabel = Text(
          'Needs permission',
          key: Key('wizard-source-status-${source.id}'),
        );
        statusAction = TextButton(
          key: Key('grant-permission-${source.id}'),
          onPressed: () => widget.onRequestPermission?.call(source.id),
          child: const Text('Grant'),
        );
      case WizardSourceStage.permissionDenied:
        statusLabel = Text(
          'Permission denied',
          key: Key('wizard-source-status-${source.id}'),
        );
        statusAction = TextButton(
          key: Key('open-settings-${source.id}'),
          onPressed: () => widget.onOpenSettings?.call(source.id),
          child: const Text('Open Settings'),
        );
      case WizardSourceStage.connected:
        statusLabel = Text(
          'Connected',
          key: Key('wizard-source-status-${source.id}'),
        );
        statusAction = const Icon(Icons.check_circle, color: Colors.green);
      case WizardSourceStage.error:
        statusLabel = Text(
          'Error: ${status.reason}',
          key: Key('wizard-source-status-${source.id}'),
        );
        statusAction = null;
    }

    return ListTile(
      title: Text(source.displayName),
      subtitle: statusLabel,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ?statusAction,
          Switch(
            value: isToggled,
            onChanged: (value) => setState(
              () => _toggleState[source.id] = value,
            ),
          ),
        ],
      ),
    );
  }

  // Step 2: default lead times.
  Widget _buildLeadTimesStep() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Default lead time',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text('How long before a meeting should alerts start?'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              for (final preset in widget.leadTimePresets)
                ChoiceChip(
                  label: Text(_leadTimeLabel(preset)),
                  selected: _leadTime == preset,
                  onSelected: (_) => setState(() => _leadTime = preset),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // Step 3: verify with a test alert.
  Widget _buildTestAlertStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Send a test alert',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        const Text(
          'Make sure alerts reach you before you rely on them.',
        ),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          key: const Key('send-test-alert'),
          onPressed: () async {
            await widget.onTestAlert();
            if (mounted) {
              setState(() => _testAlertSent = true);
            }
          },
          icon: const Icon(Icons.notifications_active),
          label: const Text('Send test alert'),
        ),
        if (_testAlertSent) ...[
          const SizedBox(height: 12),
          const Text(
            'Test alert sent',
            style: TextStyle(color: Colors.green),
          ),
        ],
      ],
    );
  }

  // Step 4: finish onto the agenda.
  Widget _buildFinishStep() {
    final configuredCount =
        widget.sources.where((s) => s.isConfigured).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'You are ready',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(
          _hasConfiguredSource
              ? '$configuredCount calendar '
                  '${configuredCount == 1 ? 'source is' : 'sources are'} '
                  'ready to go.'
              : 'Connect at least one calendar source to continue.',
        ),
        const SizedBox(height: 16),
        ElevatedButton(
          key: const Key('wizard-finish'),
          onPressed: _hasConfiguredSource ? widget.onFinish : null,
          child: const Text('Open agenda'),
        ),
      ],
    );
  }

  Widget _buildNavigation() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        if (_step > 0)
          TextButton(
            key: const Key('wizard-back'),
            onPressed: () => setState(() => _step--),
            child: const Text('Back'),
          )
        else
          const SizedBox(width: 48),
        if (_step < _steps - 1)
          ElevatedButton(
            key: const Key('wizard-next'),
            onPressed: () => setState(() => _step++),
            child: const Text('Next'),
          ),
      ],
    );
  }
}
