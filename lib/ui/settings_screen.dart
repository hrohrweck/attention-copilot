import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/storage/settings_store.dart';

/// Presentation-layer settings that are not (yet) part of the persisted
/// [AppSettings] document. The screen renders these and reports changes
/// through [SettingsScreen.onExtrasChanged]; wiring them to a store is the
/// caller's job.
@immutable
class SettingsExtras {
  const SettingsExtras({
    this.repeatIntervalSeconds = 30,
    this.volumeRampEnabled = true,
    this.maxAlertDurationMinutes = 5,
    this.quietWhenAwayMinutes = 5,
    this.alertWhileLockedOrAway = false,
    this.audioSourceId = 'system',
    this.icsUrl,
    this.macCalendarsEnabled = false,
    this.trayEnabled = true,
    this.residentEnabled = false,
    this.autostartEnabled = false,
  });

  static const SettingsExtras defaults = SettingsExtras();

  /// Audio source ids offered in the selection control.
  static const List<String> audioSourceIds = ['system', 'chime', 'alarm'];

  /// Human-readable label for an [audioSourceIds] entry.
  static String audioSourceLabel(String id) {
    switch (id) {
      case 'system':
        return 'System default';
      case 'chime':
        return 'Chime';
      case 'alarm':
        return 'Alarm';
      default:
        return id;
    }
  }

  /// How often the audio cycle repeats while unacknowledged, in seconds.
  final int repeatIntervalSeconds;

  /// Whether the alert volume is raised over time (volume ramp).
  final bool volumeRampEnabled;

  /// Upper bound for how long an alert may ring, in minutes.
  final int maxAlertDurationMinutes;

  /// Away duration after which alerts are deferred while absent, in minutes.
  final int quietWhenAwayMinutes;

  /// When true the alert fires even while the machine is locked or the user
  /// is away.
  final bool alertWhileLockedOrAway;

  /// Selected audio source id (one of [audioSourceIds]).
  final String audioSourceId;

  /// Configured ICS feed URL, or null when not configured.
  final String? icsUrl;

  /// Whether the macOS native calendar source is switched on.
  final bool macCalendarsEnabled;

  /// Whether the system tray icon is shown.
  final bool trayEnabled;

  /// Whether the app stays resident in the background.
  final bool residentEnabled;

  /// Whether the app starts at login.
  final bool autostartEnabled;

  static const Object _unset = Object();

  /// Returns a copy with the given fields replaced. Pass `icsUrl: null` to
  /// clear the configured ICS feed.
  SettingsExtras copyWith({
    int? repeatIntervalSeconds,
    bool? volumeRampEnabled,
    int? maxAlertDurationMinutes,
    int? quietWhenAwayMinutes,
    bool? alertWhileLockedOrAway,
    String? audioSourceId,
    Object? icsUrl = _unset,
    bool? macCalendarsEnabled,
    bool? trayEnabled,
    bool? residentEnabled,
    bool? autostartEnabled,
  }) {
    return SettingsExtras(
      repeatIntervalSeconds: repeatIntervalSeconds ?? this.repeatIntervalSeconds,
      volumeRampEnabled: volumeRampEnabled ?? this.volumeRampEnabled,
      maxAlertDurationMinutes:
          maxAlertDurationMinutes ?? this.maxAlertDurationMinutes,
      quietWhenAwayMinutes: quietWhenAwayMinutes ?? this.quietWhenAwayMinutes,
      alertWhileLockedOrAway:
          alertWhileLockedOrAway ?? this.alertWhileLockedOrAway,
      audioSourceId: audioSourceId ?? this.audioSourceId,
      icsUrl: identical(icsUrl, _unset) ? this.icsUrl : icsUrl as String?,
      macCalendarsEnabled: macCalendarsEnabled ?? this.macCalendarsEnabled,
      trayEnabled: trayEnabled ?? this.trayEnabled,
      residentEnabled: residentEnabled ?? this.residentEnabled,
      autostartEnabled: autostartEnabled ?? this.autostartEnabled,
    );
  }
}

/// Presentation-only settings screen.
///
/// Renders the current [settings] and [extras] and reports every change
/// through [onSettingsChanged] / [onExtrasChanged]. Side effects (OAuth,
/// firing a real alert, opening the diagnostics page, previewing audio) are
/// delegated to the injected callbacks — the real wiring lives elsewhere.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    required this.onSettingsChanged,
    required this.extras,
    required this.onExtrasChanged,
    this.onTestAlert,
    this.onPreviewAudio,
    this.onGoogleConnect,
    this.onGoogleDisconnect,
    this.onIcsConnect,
    this.onIcsDisconnect,
    this.onOpenDiagnostics,
  });

  /// The persisted settings to render.
  final AppSettings settings;

  /// Invoked with the new [AppSettings] whenever a persisted field changes.
  final ValueChanged<AppSettings> onSettingsChanged;

  /// The presentation-layer extras to render.
  final SettingsExtras extras;

  /// Invoked with the new [SettingsExtras] whenever an extras field changes.
  final ValueChanged<SettingsExtras> onExtrasChanged;

  /// Invoked when the user taps "Test Alert". The real firing path is wired
  /// elsewhere; this screen only triggers it.
  final VoidCallback? onTestAlert;

  /// Invoked with the selected audio source id when the user taps "Preview".
  final ValueChanged<String>? onPreviewAudio;

  /// Invoked with the validated client id when the user taps "Connect" for
  /// Google Calendar.
  final ValueChanged<String>? onGoogleConnect;

  /// Invoked when the user taps "Disconnect" for Google Calendar.
  final VoidCallback? onGoogleDisconnect;

  /// Invoked with the validated ICS URL when the user connects an ICS feed.
  final ValueChanged<String>? onIcsConnect;

  /// Invoked when the user disconnects the ICS feed.
  final VoidCallback? onIcsDisconnect;

  /// Invoked when the user opens the diagnostics section.
  final VoidCallback? onOpenDiagnostics;

  /// Validates a complete lead-time list. Canonical order is longest lead
  /// time first, earliest alert last (the persisted default is `[10, 1]`):
  /// strictly descending minutes, positive and duplicate-free. Returns an
  /// error message, or null when valid.
  static String? validateAlertLeadMinutes(List<int> minutes) {
    if (minutes.isEmpty) {
      return 'Add at least one lead time';
    }
    final seen = <int>{};
    for (var i = 0; i < minutes.length; i++) {
      final minute = minutes[i];
      if (minute <= 0) {
        return 'Lead times must be positive minutes';
      }
      if (!seen.add(minute)) {
        return 'Duplicate lead time: $minute minutes';
      }
      if (i > 0 && minutes[i] >= minutes[i - 1]) {
        return 'Lead times must be ordered longest first (earliest alert last)';
      }
    }
    return null;
  }

  /// Validates adding [candidate] to [existing]. Returns an error message,
  /// or null when the addition is allowed.
  static String? validateLeadTimeAddition(List<int> existing, int candidate) {
    if (candidate <= 0) {
      return 'Lead times must be positive minutes';
    }
    if (existing.contains(candidate)) {
      return 'A $candidate-minute lead time already exists';
    }
    return null;
  }

  /// Validates a Google OAuth client id shape: a non-empty
  /// `*.apps.googleusercontent.com` identifier. Returns an error message, or
  /// null when valid.
  static String? validateGoogleClientId(String value) {
    const suffix = '.apps.googleusercontent.com';
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return 'Enter a client ID';
    }
    if (!trimmed.endsWith(suffix) || trimmed.length == suffix.length) {
      return 'Client ID must end with $suffix';
    }
    final prefix = trimmed.substring(0, trimmed.length - suffix.length);
    if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(prefix)) {
      return 'Client ID contains invalid characters';
    }
    return null;
  }

  /// Validates an ICS feed URL. Returns an error message, or null when valid.
  static String? validateIcsUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return 'Enter an ICS URL';
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme) {
      return 'Enter a full URL (https://…)';
    }
    const allowed = {'http', 'https', 'webcal', 'file'};
    if (!allowed.contains(uri.scheme.toLowerCase())) {
      return 'URL must start with http, https or webcal';
    }
    return null;
  }

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const List<int> _repeatIntervalOptions = [15, 30, 60, 120];
  static const List<int> _maxDurationOptions = [1, 3, 5, 10, 15];
  static const List<int> _quietAwayOptions = [1, 2, 5, 10];

  late AppSettings _settings;
  late SettingsExtras _extras;
  late final TextEditingController _clientIdController;
  late final TextEditingController _icsUrlController;
  String? _clientIdError;
  String? _icsUrlError;

  static String _repeatLabel(int seconds) =>
      seconds >= 120 ? 'Repeat: ${seconds ~/ 60} min' : 'Repeat: $seconds s';

  static String _durationLabel(int minutes) => 'Stop after $minutes min';

  static String _awayLabel(int minutes) => 'After $minutes min away';

  @override
  void initState() {
    super.initState();
    _settings = widget.settings;
    _extras = widget.extras;
    _clientIdController =
        TextEditingController(text: _settings.googleClientId ?? '');
    _icsUrlController = TextEditingController(text: _extras.icsUrl ?? '');
  }

  @override
  void didUpdateWidget(SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.settings != _settings) {
      _settings = widget.settings;
      final nextClientId = _settings.googleClientId ?? '';
      if (_clientIdController.text != nextClientId) {
        _clientIdController.text = nextClientId;
      }
    }
    if (widget.extras != _extras) {
      _extras = widget.extras;
      final nextIcsUrl = _extras.icsUrl ?? '';
      if (_icsUrlController.text != nextIcsUrl) {
        _icsUrlController.text = nextIcsUrl;
      }
    }
  }

  @override
  void dispose() {
    _clientIdController.dispose();
    _icsUrlController.dispose();
    super.dispose();
  }

  void _emitSettings(AppSettings next) {
    setState(() => _settings = next);
    widget.onSettingsChanged(next);
  }

  void _emitExtras(SettingsExtras next) {
    setState(() => _extras = next);
    widget.onExtrasChanged(next);
  }

  // ---------------------------------------------------------------------
  // Lead times
  // ---------------------------------------------------------------------

  void _addLeadTime(int minutes) {
    final next = [..._settings.alertLeadMinutes, minutes]
      ..sort((a, b) => b.compareTo(a));
    _emitSettings(
        _settings.copyWith(alertLeadMinutes: List<int>.unmodifiable(next)));
  }

  void _removeLeadTime(int minutes) {
    _emitSettings(_settings.copyWith(
      alertLeadMinutes: List<int>.unmodifiable(
          _settings.alertLeadMinutes.where((m) => m != minutes)),
    ));
  }

  void _restoreDefaultLeadTimes() {
    _emitSettings(_settings.copyWith(
        alertLeadMinutes: AppSettings.defaultAlertLeadMinutes));
  }

  Future<void> _showAddLeadTimeDialog() async {
    final controller = TextEditingController();
    final int? added = await showDialog<int>(
      context: context,
      builder: (dialogContext) {
        String? error;
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            void submit() {
              final value = int.tryParse(controller.text.trim());
              if (value == null) {
                setDialogState(() => error = 'Enter a number of minutes');
                return;
              }
              final problem = SettingsScreen.validateLeadTimeAddition(
                  _settings.alertLeadMinutes, value);
              if (problem != null) {
                setDialogState(() => error = problem);
                return;
              }
              Navigator.of(dialogContext).pop(value);
            }

            return AlertDialog(
              title: const Text('Add alert lead time'),
              content: TextField(
                key: const Key('settings.addLeadDialogField'),
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: 'Minutes before start',
                  errorText: error,
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  key: const Key('settings.addLeadDialogAdd'),
                  onPressed: submit,
                  child: const Text('Add'),
                ),
              ],
            );
          },
        );
      },
    );
    if (added != null) {
      _addLeadTime(added);
    }
  }

  // ---------------------------------------------------------------------
  // Calendar sources
  // ---------------------------------------------------------------------

  void _connectGoogle() {
    final value = _clientIdController.text.trim();
    final problem = SettingsScreen.validateGoogleClientId(value);
    setState(() => _clientIdError = problem);
    if (problem != null) {
      return;
    }
    _emitSettings(_settings.copyWith(googleClientId: value));
    widget.onGoogleConnect?.call(value);
  }

  void _disconnectGoogle() {
    _emitSettings(AppSettings(
      schemaVersion: _settings.schemaVersion,
      alertLeadMinutes: _settings.alertLeadMinutes,
      snoozeEnabled: _settings.snoozeEnabled,
      googleClientId: null,
      deviceCalendarsEnabled: _settings.deviceCalendarsEnabled,
      enabledDeviceCalendarIds: _settings.enabledDeviceCalendarIds,
      unknown: _settings.unknown,
    ));
    setState(() => _clientIdController.clear());
    widget.onGoogleDisconnect?.call();
  }

  void _connectIcs() {
    final value = _icsUrlController.text.trim();
    final problem = SettingsScreen.validateIcsUrl(value);
    setState(() => _icsUrlError = problem);
    if (problem != null) {
      return;
    }
    _emitExtras(_extras.copyWith(icsUrl: value));
    widget.onIcsConnect?.call(value);
  }

  void _disconnectIcs() {
    _emitExtras(_extras.copyWith(icsUrl: null));
    setState(() => _icsUrlController.clear());
    widget.onIcsDisconnect?.call();
  }

  // ---------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Alert lead times', style: theme.textTheme.titleMedium),
        ..._buildLeadTimeRows(),
        _buildLeadTimeActions(),
        const Divider(),
        Text('Escalation', style: theme.textTheme.titleMedium),
        _buildDropdown<int>(
          key: const Key('settings.repeatInterval'),
          label: 'Repeat interval',
          value: _extras.repeatIntervalSeconds,
          items: [
            for (final seconds in _repeatIntervalOptions)
              DropdownMenuItem(
                value: seconds,
                child: Text(_repeatLabel(seconds)),
              ),
          ],
          onChanged: (v) =>
              _emitExtras(_extras.copyWith(repeatIntervalSeconds: v)),
        ),
        SwitchListTile(
          key: const Key('settings.volumeRamp'),
          title: const Text('Raise volume over time'),
          subtitle: const Text('Escalate the alert volume until acknowledged'),
          value: _extras.volumeRampEnabled,
          onChanged: (v) =>
              _emitExtras(_extras.copyWith(volumeRampEnabled: v)),
        ),
        _buildDropdown<int>(
          key: const Key('settings.maxDuration'),
          label: 'Maximum alert duration',
          value: _extras.maxAlertDurationMinutes,
          items: [
            for (final minutes in _maxDurationOptions)
              DropdownMenuItem(
                value: minutes,
                child: Text(_durationLabel(minutes)),
              ),
          ],
          onChanged: (v) =>
              _emitExtras(_extras.copyWith(maxAlertDurationMinutes: v)),
        ),
        const Divider(),
        Text('Quiet when away', style: theme.textTheme.titleMedium),
        _buildDropdown<int>(
          key: const Key('settings.quietAway'),
          label: 'Quiet threshold',
          value: _extras.quietWhenAwayMinutes,
          items: [
            for (final minutes in _quietAwayOptions)
              DropdownMenuItem(
                value: minutes,
                child: Text(_awayLabel(minutes)),
              ),
          ],
          onChanged: (v) =>
              _emitExtras(_extras.copyWith(quietWhenAwayMinutes: v)),
        ),
        SwitchListTile(
          key: const Key('settings.alertWhileLocked'),
          title: const Text('Alert even while locked or away'),
          subtitle: const Text('Override the quiet-when-away deferral'),
          value: _extras.alertWhileLockedOrAway,
          onChanged: (v) =>
              _emitExtras(_extras.copyWith(alertWhileLockedOrAway: v)),
        ),
        const Divider(),
        SwitchListTile(
          key: const Key('settings.snoozeSwitch'),
          title: const Text('Offer snooze'),
          subtitle: const Text('Show a snooze button on the alert surface'),
          value: _settings.snoozeEnabled,
          onChanged: (v) =>
              _emitSettings(_settings.copyWith(snoozeEnabled: v)),
        ),
        const Divider(),
        Text('Audio', style: theme.textTheme.titleMedium),
        _buildDropdown<String>(
          key: const Key('settings.audioSource'),
          label: 'Audio source',
          value: _extras.audioSourceId,
          items: [
            for (final id in SettingsExtras.audioSourceIds)
              DropdownMenuItem(
                value: id,
                child: Text(SettingsExtras.audioSourceLabel(id)),
              ),
          ],
          onChanged: (v) => _emitExtras(_extras.copyWith(audioSourceId: v)),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: OutlinedButton.icon(
            key: const Key('settings.audioPreview'),
            onPressed: widget.onPreviewAudio == null
                ? null
                : () => widget.onPreviewAudio!(_extras.audioSourceId),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Preview'),
          ),
        ),
        const Divider(),
        Text('Calendar sources', style: theme.textTheme.titleMedium),
        _buildGoogleSection(),
        _buildIcsSection(),
        SwitchListTile(
          key: const Key('settings.macCalendars'),
          title: const Text('Use macOS calendar integration'),
          value: _extras.macCalendarsEnabled,
          onChanged: (v) =>
              _emitExtras(_extras.copyWith(macCalendarsEnabled: v)),
        ),
        SwitchListTile(
          key: const Key('settings.deviceCalendars'),
          title: const Text("Use this device's calendars (Android)"),
          value: _settings.deviceCalendarsEnabled,
          onChanged: (v) => _emitSettings(
              _settings.copyWith(deviceCalendarsEnabled: v)),
        ),
        const Divider(),
        Text('System integration', style: theme.textTheme.titleMedium),
        SwitchListTile(
          key: const Key('settings.tray'),
          title: const Text('Show in system tray'),
          value: _extras.trayEnabled,
          onChanged: (v) => _emitExtras(_extras.copyWith(trayEnabled: v)),
        ),
        SwitchListTile(
          key: const Key('settings.resident'),
          title: const Text('Keep resident in background'),
          value: _extras.residentEnabled,
          onChanged: (v) => _emitExtras(_extras.copyWith(residentEnabled: v)),
        ),
        SwitchListTile(
          key: const Key('settings.autostart'),
          title: const Text('Start at login'),
          value: _extras.autostartEnabled,
          onChanged: (v) => _emitExtras(_extras.copyWith(autostartEnabled: v)),
        ),
        const Divider(),
        ListTile(
          key: const Key('settings.diagnostics'),
          leading: const Icon(Icons.monitor_heart_outlined),
          title: const Text('Diagnostics'),
          subtitle: const Text('Export logs and check system health'),
          trailing: const Icon(Icons.chevron_right),
          onTap: widget.onOpenDiagnostics,
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          key: const Key('settings.testAlert'),
          onPressed: widget.onTestAlert,
          icon: const Icon(Icons.notifications_active),
          label: const Text('Test Alert'),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  List<Widget> _buildLeadTimeRows() {
    final minutes = _settings.alertLeadMinutes;
    final validation = SettingsScreen.validateAlertLeadMinutes(minutes);
    return [
      for (final minute in minutes)
        ListTile(
          dense: true,
          leading: const Icon(Icons.notifications_active_outlined),
          title: Text(
              '$minute ${minute == 1 ? 'minute' : 'minutes'} before'),
          trailing: IconButton(
            key: Key('settings.deleteLead-$minute'),
            tooltip: 'Remove $minute-minute lead time',
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: minutes.length > 1
                ? () => _removeLeadTime(minute)
                : null,
          ),
        ),
      if (validation != null)
        Padding(
          padding: const EdgeInsets.only(left: 16, bottom: 8),
          child: Text(
            validation,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
    ];
  }

  Widget _buildLeadTimeActions() {
    return Row(
      children: [
        OutlinedButton.icon(
          key: const Key('settings.addLeadTime'),
          onPressed: _showAddLeadTimeDialog,
          icon: const Icon(Icons.add),
          label: const Text('Add lead time'),
        ),
        const SizedBox(width: 8),
        TextButton(
          key: const Key('settings.restoreDefaults'),
          onPressed: _restoreDefaultLeadTimes,
          child: const Text('Restore defaults'),
        ),
      ],
    );
  }

  Widget _buildDropdown<T>({
    required Key key,
    required String label,
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            key: key,
            value: value,
            isExpanded: true,
            isDense: true,
            items: items,
            onChanged: (v) {
              if (v != null) {
                onChanged(v);
              }
            },
          ),
        ),
      ),
    );
  }

  Widget _buildGoogleSection() {
    final clientId = _settings.googleClientId;
    if (clientId != null) {
      return ListTile(
        leading: const Icon(Icons.check_circle),
        title: const Text('Google Calendar'),
        subtitle: Text('Connected with client $clientId'),
        trailing: TextButton(
          key: const Key('settings.googleDisconnect'),
          onPressed: _disconnectGoogle,
          child: const Text('Disconnect'),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('settings.googleClientIdField'),
            controller: _clientIdController,
            decoration: InputDecoration(
              labelText: 'Google OAuth client ID',
              hintText: '…apps.googleusercontent.com',
              errorText: _clientIdError,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) {
              if (_clientIdError != null) {
                setState(() => _clientIdError = null);
              }
            },
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonal(
              key: const Key('settings.googleConnect'),
              onPressed: _connectGoogle,
              child: const Text('Connect'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIcsSection() {
    final configured = _extras.icsUrl != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('settings.icsUrlField'),
            controller: _icsUrlController,
            decoration: InputDecoration(
              labelText: 'ICS calendar URL',
              hintText: 'https://…/calendar.ics',
              errorText: _icsUrlError,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) {
              if (_icsUrlError != null) {
                setState(() => _icsUrlError = null);
              }
            },
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: configured
                ? OutlinedButton(
                    key: const Key('settings.icsDisconnect'),
                    onPressed: _disconnectIcs,
                    child: const Text('Disconnect'),
                  )
                : FilledButton.tonal(
                    key: const Key('settings.icsConnect'),
                    onPressed: _connectIcs,
                    child: const Text('Connect'),
                  ),
          ),
        ],
      ),
    );
  }
}
