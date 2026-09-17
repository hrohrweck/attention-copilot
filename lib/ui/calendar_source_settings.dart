import 'package:flutter/material.dart';

import '../data/sources/calendar_contract_source.dart';
import '../data/storage/settings_store.dart';

/// Source-selection surface for the Android CalendarContract source
/// (plan todo 21).
///
/// Permission model: `READ_CALENDAR` is requested only when the user flips
/// the master toggle on (in context), never at app start. When the source
/// was enabled on a previous run, the grant is only *checked* passively at
/// start; a revoked permission lands in the blocking denied state instead of
/// prompting.
///
/// Persistence: the master toggle (`deviceCalendarsEnabled`) and the
/// per-calendar selection (`enabledDeviceCalendarIds`) are stored through
/// [settingsStore]. On the first enable, every visible calendar is selected
/// by default; afterwards the persisted selection is authoritative.
class CalendarSourceSettings extends StatefulWidget {
  const CalendarSourceSettings({
    super.key,
    required this.source,
    required this.settingsStore,
    required this.openAppSettings,
  });

  /// The Android CalendarContract source used to check/request the
  /// `READ_CALENDAR` permission and to enumerate device calendars.
  final CalendarContractSource source;

  /// Seam for persisting the master toggle and the per-calendar selection.
  final SettingsStore settingsStore;

  /// Opens the system app-settings screen so the user can grant
  /// `READ_CALENDAR` after a denial. The widget itself has no platform
  /// channel for this; the caller (composition root) provides the action.
  final Future<void> Function() openAppSettings;

  @override
  State<CalendarSourceSettings> createState() => _CalendarSourceSettingsState();
}

class _CalendarSourceSettingsState extends State<CalendarSourceSettings> {
  AppSettings _settings = AppSettings.defaults();
  bool _enabled = false;
  bool _denied = false;
  bool _busy = false;
  List<ContractCalendar> _calendars = const <ContractCalendar>[];
  Set<int> _enabledIds = <int>{};

  @override
  void initState() {
    super.initState();
    _restore();
  }

  /// Loads the persisted posture. A previously enabled source is checked
  /// passively - the permission dialog is never raised at app start.
  Future<void> _restore() async {
    final result = await widget.settingsStore.load();
    if (!mounted) {
      return;
    }
    _settings = result.settings;
    final enabled = result.settings.deviceCalendarsEnabled;
    setState(() {
      _enabled = enabled;
      _enabledIds =
          Set<int>.of(result.settings.enabledDeviceCalendarIds ?? const <int>[]);
    });
    if (enabled) {
      await _checkPermission();
    }
  }

  /// Queries the grant without prompting; on grant, loads the calendars.
  Future<void> _checkPermission() async {
    setState(() {
      _busy = true;
    });
    final granted = await widget.source.hasPermission();
    if (!mounted) {
      return;
    }
    if (granted) {
      await _loadCalendars();
    } else {
      setState(() {
        _denied = true;
        _busy = false;
      });
    }
  }

  /// Requests `READ_CALENDAR` in context (the user just opted in); on grant,
  /// loads the calendars, on denial falls into the blocking denied state.
  Future<void> _requestPermission() async {
    setState(() {
      _busy = true;
    });
    final granted = await widget.source.requestPermission();
    if (!mounted) {
      return;
    }
    if (granted) {
      await _loadCalendars();
    } else {
      setState(() {
        _denied = true;
        _busy = false;
      });
    }
  }

  Future<void> _loadCalendars() async {
    final calendars = await widget.source.listCalendars();
    if (!mounted) {
      return;
    }
    // First-time enable: default to every visible calendar. Afterwards the
    // persisted selection is authoritative (including "user disabled all").
    var ids = _enabledIds;
    if (_settings.enabledDeviceCalendarIds == null) {
      ids = calendars.where((c) => c.visible).map((c) => c.id).toSet();
    }
    setState(() {
      _denied = false;
      _busy = false;
      _calendars = calendars;
      _enabledIds = Set<int>.of(ids);
    });
    await _persist(enabledDeviceCalendarIds: List<int>.of(ids));
  }

  Future<void> _onMasterToggled(bool value) async {
    if (value) {
      setState(() {
        _enabled = true;
        _denied = false;
      });
      await _persist(deviceCalendarsEnabled: true);
      await _requestPermission();
    } else {
      setState(() {
        _enabled = false;
        _denied = false;
      });
      // Keep the per-calendar selection so re-enabling restores it.
      await _persist(deviceCalendarsEnabled: false);
    }
  }

  Future<void> _onCalendarToggled(ContractCalendar calendar, bool value) async {
    setState(() {
      if (value) {
        _enabledIds.add(calendar.id);
      } else {
        _enabledIds.remove(calendar.id);
      }
    });
    await _persist(enabledDeviceCalendarIds: List<int>.of(_enabledIds));
  }

  Future<void> _persist({
    bool? deviceCalendarsEnabled,
    List<int>? enabledDeviceCalendarIds,
  }) async {
    final updated = _settings.copyWith(
      deviceCalendarsEnabled: deviceCalendarsEnabled,
      enabledDeviceCalendarIds: enabledDeviceCalendarIds,
    );
    _settings = updated;
    await widget.settingsStore.save(updated);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SwitchListTile(
          title: const Text("Use this device's calendars"),
          subtitle: const Text(
            'Show meetings from the calendars synced to this device.',
          ),
          value: _enabled,
          onChanged: _busy ? null : _onMasterToggled,
        ),
        if (_enabled) ..._buildBody(),
      ],
    );
  }

  List<Widget> _buildBody() {
    if (_busy) {
      return const <Widget>[
        Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (_denied) {
      return <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Icon(Icons.calendar_month_outlined, size: 40),
              const SizedBox(height: 12),
              Text(
                'Calendar access is blocked',
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                "Attention Copilot can't read this device's calendars "
                'because the READ_CALENDAR permission was denied. Grant it '
                'in system settings, or try requesting it again.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _requestPermission,
                child: const Text('Try again'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: widget.openAppSettings,
                child: const Text('Open system settings'),
              ),
            ],
          ),
        ),
      ];
    }
    if (_calendars.isEmpty) {
      return const <Widget>[
        Padding(
          padding: EdgeInsets.all(16),
          child: Text('No calendars were found on this device.'),
        ),
      ];
    }
    return <Widget>[
      for (final calendar in _calendars)
        SwitchListTile(
          title: Text(calendar.displayName),
          subtitle: calendar.accountName == null
              ? null
              : Text(calendar.accountName!),
          value: _enabledIds.contains(calendar.id),
          onChanged: (value) => _onCalendarToggled(calendar, value),
        ),
    ];
  }
}
