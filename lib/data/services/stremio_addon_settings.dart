import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/stremio_addon.dart';

/// Clave donde vive la lista de addons instalados.
const String stremioAddonsKey = 'shows_stremio_addons';

/// Lista de addons instalados. El orden es la prioridad de consulta y
/// [enabledAddons] es lo único que el resto de la app debe mirar: aquí se
/// decide qué addon se consulta.
@immutable
class StremioAddonSettings {
  final List<InstalledAddon> addons;

  const StremioAddonSettings({this.addons = const []});

  List<InstalledAddon> get enabledAddons =>
      addons.where((a) => a.enabled).toList(growable: false);

  bool get hasAddons => addons.isNotEmpty;
  bool get hasEnabledAddons => enabledAddons.isNotEmpty;
  int get count => addons.length;
  int get enabledCount => enabledAddons.length;

  InstalledAddon? byUrl(String url) {
    for (final addon in addons) {
      if (addon.url == url) return addon;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is StremioAddonSettings && listEquals(other.addons, addons);

  @override
  int get hashCode => Object.hashAll(addons);

  @override
  String toString() => 'StremioAddonSettings(${addons.length} addons)';
}

/// Lee y persiste la lista de addons instalados.
class StremioAddonSettingsNotifier extends StateNotifier<StremioAddonSettings> {
  StremioAddonSettingsNotifier({
    StremioAddonSettings initial = const StremioAddonSettings(),
    SharedPreferences? preferences,
  })  : _prefs = preferences,
        super(initial);

  SharedPreferences? _prefs;
  Future<void>? _loading;
  bool _loaded = false;

  bool get isLoaded => _loaded;

  Future<SharedPreferences> _preferences() async =>
      _prefs ??= await SharedPreferences.getInstance();

  /// Lectura perezosa y compartida: las mutaciones esperan a que termine para
  /// no escribir encima de una lectura a medio hacer.
  Future<void> load() {
    if (_loaded) return Future<void>.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    final prefs = await _preferences();
    final raw = prefs.getString(stremioAddonsKey);
    final List<InstalledAddon> addons =
        raw == null || raw.isEmpty ? const [] : _decode(raw);
    _loaded = true;
    if (!mounted) return;
    state = StremioAddonSettings(addons: addons);
  }

  /// Guarda un addon ya validado. Si la URL ya estaba, actualiza nombre y
  /// versión conservando su posición y su estado; si es nueva, entra al final
  /// (menor prioridad) y habilitada.
  Future<void> save(StremioManifest manifest, String url) async {
    await load();
    if (!mounted) return;

    final normalized = tryNormalizeAddonUrl(url);
    if (normalized == null) return;

    final addons = List<InstalledAddon>.from(state.addons);
    final index = addons.indexWhere((a) => a.url == normalized);
    final entry = InstalledAddon(
      url: normalized,
      name: manifest.name,
      manifestId: manifest.id,
      version: manifest.version,
      enabled: index >= 0 ? addons[index].enabled : true,
    );
    if (index >= 0) {
      addons[index] = entry;
    } else {
      addons.add(entry);
    }
    await _update(addons);
  }

  Future<void> setEnabled(String url, bool enabled) async {
    await load();
    if (!mounted) return;
    final addons = [
      for (final addon in state.addons)
        addon.url == url ? addon.copyWith(enabled: enabled) : addon,
    ];
    await _update(addons);
  }

  Future<void> remove(String url) async {
    await load();
    if (!mounted) return;
    await _update(state.addons.where((a) => a.url != url).toList());
  }

  /// Mueve un addon dentro del orden de prioridad.
  Future<void> move(int from, int to) async {
    await load();
    if (!mounted) return;
    final addons = List<InstalledAddon>.from(state.addons);
    if (from < 0 ||
        from >= addons.length ||
        to < 0 ||
        to >= addons.length ||
        from == to) {
      return;
    }
    final moved = addons.removeAt(from);
    addons.insert(to, moved);
    await _update(addons);
  }

  Future<void> _update(List<InstalledAddon> addons) async {
    final prefs = await _preferences();
    await _write(prefs, addons);
    if (!mounted) return;
    state = StremioAddonSettings(
      addons: List<InstalledAddon>.unmodifiable(addons),
    );
  }

  /// Entradas ilegibles se descartan y URLs duplicadas se colapsan: un JSON
  /// corrupto no puede dejar la app consultando el mismo addon dos veces.
  static List<InstalledAddon> _decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      final list = decoded is Map ? decoded['addons'] : decoded;
      if (list is! List) return const [];

      final seen = <String>{};
      final addons = <InstalledAddon>[];
      for (final entry in list) {
        final addon = InstalledAddon.fromJson(entry);
        if (addon == null || !seen.add(addon.url)) continue;
        addons.add(addon);
      }
      return addons;
    } catch (_) {
      return const [];
    }
  }

  static Future<void> _write(
    SharedPreferences prefs,
    List<InstalledAddon> addons,
  ) {
    return prefs.setString(
      stremioAddonsKey,
      jsonEncode({
        'version': 1,
        'addons': [for (final addon in addons) addon.toJson()],
      }),
    );
  }
}

final stremioAddonSettingsProvider =
    StateNotifierProvider<StremioAddonSettingsNotifier, StremioAddonSettings>(
        (ref) {
  final notifier = StremioAddonSettingsNotifier();
  notifier.load();
  return notifier;
});
