import 'source.dart';

/// Holds all known [CalendarSource]s and which of them are enabled.
///
/// Registration order is preserved so iterations (and therefore merge
/// tie-breaks) never depend on map hashing. The orchestrator only fetches
/// [enabledSources].
class CalendarSourceRegistry {
  final Map<String, CalendarSource> _sources = {};
  final Set<String> _enabled = {};

  /// Registers [source] and optionally enables it (default: enabled).
  ///
  /// Throws [StateError] when a source with the same [CalendarSource.id] is
  /// already registered; ids are the stable map key everywhere.
  void register(CalendarSource source, {bool enabled = true}) {
    final id = source.id;
    if (_sources.containsKey(id)) {
      throw StateError(
        'A calendar source with id "$id" is already registered.',
      );
    }
    _sources[id] = source;
    if (enabled) {
      _enabled.add(id);
    }
  }

  /// Removes a source and its enabled flag.
  void unregister(String sourceId) {
    _sources.remove(sourceId);
    _enabled.remove(sourceId);
  }

  /// The registered source with [sourceId], or `null` when unknown.
  CalendarSource? lookup(String sourceId) => _sources[sourceId];

  /// Whether the source with [sourceId] is registered and enabled.
  bool isEnabled(String sourceId) => _enabled.contains(sourceId);

  /// Enables or disables the source with [sourceId].
  ///
  /// Throws [ArgumentError] when no source with that id is registered.
  void setEnabled(String sourceId, bool enabled) {
    if (!_sources.containsKey(sourceId)) {
      throw ArgumentError.value(
        sourceId,
        'sourceId',
        'No calendar source registered with this id.',
      );
    }
    if (enabled) {
      _enabled.add(sourceId);
    } else {
      _enabled.remove(sourceId);
    }
  }

  /// All registered sources in registration order.
  List<CalendarSource> get all => List.unmodifiable(_sources.values);

  /// The enabled sources in registration order.
  List<CalendarSource> get enabledSources => List.unmodifiable(
        _sources.values.where((source) => _enabled.contains(source.id)),
      );

  /// Ids of the enabled sources.
  Set<String> get enabledIds => Set.unmodifiable(_enabled);
}
