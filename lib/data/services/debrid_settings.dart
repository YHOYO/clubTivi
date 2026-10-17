import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../datasources/remote/debrid_service.dart';

/// Motivo que se muestra en las fuentes que necesitan un servicio debrid.
const String kDebridRequiredReason = 'Requiere un servicio debrid habilitado';

/// Clave donde vive la configuración actual (JSON versionado).
const String debridConfigsKey = 'shows_debrid_configs';

// Claves heredadas: solo se leen para migrarlas una vez.
const String _legacyTokensKey = 'shows_debrid_tokens';
const String _legacyTokenKey = 'shows_debrid_api_token';
const String _legacyTypeKey = 'shows_debrid_type';

DebridType? debridTypeFromName(String name) {
  for (final type in DebridType.values) {
    if (type.name == name) return type;
  }
  return null;
}

/// Configuración persistida de un servicio debrid.
@immutable
class DebridServiceConfig {
  final DebridType type;
  final String token;

  /// Un servicio deshabilitado conserva su token, pero no resuelve nada.
  final bool enabled;

  const DebridServiceConfig({
    required this.type,
    required this.token,
    this.enabled = true,
  });

  DebridServiceConfig copyWith({String? token, bool? enabled}) {
    return DebridServiceConfig(
      type: type,
      token: token ?? this.token,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'token': token,
        'enabled': enabled,
      };

  /// Devuelve null para entradas irrecuperables (tipo desconocido, token
  /// vacío): un JSON corrupto no debe dejar la app sin servicios.
  static DebridServiceConfig? fromJson(Object? value) {
    if (value is! Map) return null;
    final typeName = value['type'];
    final token = value['token'];
    if (typeName is! String || token is! String) return null;
    final type = debridTypeFromName(typeName);
    if (type == null || token.isEmpty) return null;
    final enabled = value['enabled'];
    return DebridServiceConfig(
      type: type,
      token: token,
      enabled: enabled is bool ? enabled : true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DebridServiceConfig &&
      other.type == type &&
      other.token == token &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(type, token, enabled);

  @override
  String toString() =>
      'DebridServiceConfig(${type.name}, enabled: $enabled, token: <redacted>)';
}

/// Estado completo de los servicios debrid.
///
/// El orden de [services] es la prioridad: el primer servicio habilitado es el
/// que resuelve. Es el único sitio que decide qué servicio se usa.
@immutable
class DebridSettings {
  final List<DebridServiceConfig> services;

  const DebridSettings({this.services = const []});

  List<DebridServiceConfig> get enabledServices => services
      .where((s) => s.enabled && s.token.isNotEmpty)
      .toList(growable: false);

  bool get hasEnabledService => enabledServices.isNotEmpty;
  int get configuredCount => services.length;
  int get enabledCount => enabledServices.length;

  DebridServiceConfig? configFor(DebridType type) {
    for (final config in services) {
      if (config.type == type) return config;
    }
    return null;
  }

  bool isConfigured(DebridType type) => configFor(type) != null;

  /// Servicios que resolverán, en orden de prioridad.
  List<DebridType> get enabledTypes =>
      enabledServices.map((s) => s.type).toList(growable: false);

  @override
  bool operator ==(Object other) =>
      other is DebridSettings && listEquals(other.services, services);

  @override
  int get hashCode => Object.hashAll(services);
}

/// Se lanza cuando se intenta resolver un torrent sin ningún servicio debrid
/// habilitado. La UI lo traduce a un aviso, nunca a un fallo sin explicación.
class DebridUnavailableException implements Exception {
  final String message;

  const DebridUnavailableException([
    this.message = 'No hay ningún servicio debrid habilitado. '
        'Habilita uno en Ajustes → Debrid Services.',
  ]);

  @override
  String toString() => message;
}

/// Lee, migra y persiste la configuración de servicios debrid.
class DebridSettingsNotifier extends StateNotifier<DebridSettings> {
  DebridSettingsNotifier({
    DebridSettings initial = const DebridSettings(),
    SharedPreferences? preferences,
  })  : _prefs = preferences,
        super(initial);

  SharedPreferences? _prefs;
  Future<void>? _loading;
  bool _loaded = false;

  /// True cuando [load] ya leyó (y migró) las preferencias.
  bool get isLoaded => _loaded;

  Future<SharedPreferences> _preferences() async =>
      _prefs ??= await SharedPreferences.getInstance();

  /// Lectura perezosa y compartida: las mutaciones esperan a que termine para
  /// no escribir encima de una migración a medio hacer.
  Future<void> load() {
    if (_loaded) return Future<void>.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    final prefs = await _preferences();
    final settings = await _read(prefs);
    _loaded = true;
    if (!mounted) return;
    state = settings;
  }

  Future<void> setEnabled(DebridType type, bool enabled) async {
    await load();
    if (!mounted || state.configFor(type) == null) return;
    final services = [
      for (final config in state.services)
        config.type == type ? config.copyWith(enabled: enabled) : config,
    ];
    await _update(services);
  }

  /// Guarda el token. Un servicio nuevo entra al final (menor prioridad); uno
  /// existente conserva su posición y su estado habilitado.
  Future<void> saveToken(DebridType type, String token) async {
    await load();
    if (!mounted) return;
    final trimmed = token.trim();
    if (trimmed.isEmpty) {
      await remove(type);
      return;
    }

    final existing = state.configFor(type);
    final services = List<DebridServiceConfig>.from(state.services);
    if (existing == null) {
      services.add(DebridServiceConfig(type: type, token: trimmed));
    } else {
      final index = services.indexWhere((c) => c.type == type);
      services[index] = existing.copyWith(token: trimmed);
    }
    await _update(services);
  }

  Future<void> remove(DebridType type) async {
    await load();
    if (!mounted || state.configFor(type) == null) return;
    await _update(state.services.where((c) => c.type != type).toList());
  }

  /// Mueve un servicio dentro del orden de prioridad.
  Future<void> move(int from, int to) async {
    await load();
    if (!mounted) return;
    final services = List<DebridServiceConfig>.from(state.services);
    if (from < 0 ||
        from >= services.length ||
        to < 0 ||
        to >= services.length ||
        from == to) {
      return;
    }
    final moved = services.removeAt(from);
    services.insert(to, moved);
    await _update(services);
  }

  Future<void> _update(List<DebridServiceConfig> services) async {
    final prefs = await _preferences();
    await _write(prefs, services);
    if (!mounted) return;
    state = DebridSettings(services: List<DebridServiceConfig>.unmodifiable(services));
  }

  // --- Lectura, migración y escritura ---

  static Future<DebridSettings> _read(SharedPreferences prefs) async {
    final raw = prefs.getString(debridConfigsKey);
    if (raw != null && raw.isNotEmpty) {
      final decoded = _decode(raw);
      if (decoded != null) return DebridSettings(services: decoded);
    }

    final migrated = _migrateLegacy(prefs);
    if (migrated.isEmpty) return const DebridSettings();

    await _write(prefs, migrated);
    await prefs.remove(_legacyTokensKey);
    await prefs.remove(_legacyTokenKey);
    await prefs.remove(_legacyTypeKey);
    return DebridSettings(services: migrated);
  }

  /// Acepta tanto el objeto versionado como un array suelto. Devuelve null si
  /// el documento no se puede interpretar, para poder caer a la migración.
  static List<DebridServiceConfig>? _decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      final list = decoded is Map ? decoded['services'] : decoded;
      if (list is! List) return null;

      final seen = <DebridType>{};
      final configs = <DebridServiceConfig>[];
      for (final entry in list) {
        final config = DebridServiceConfig.fromJson(entry);
        if (config == null || !seen.add(config.type)) continue;
        configs.add(config);
      }
      return configs;
    } catch (_) {
      return null;
    }
  }

  /// Traduce el mapa tipo→token de versiones anteriores y el token único aún
  /// más antiguo. El orden resultante es el del enum: determinista y sin
  /// depender del orden de inserción del JSON.
  static List<DebridServiceConfig> _migrateLegacy(SharedPreferences prefs) {
    final tokens = <DebridType, String>{};

    final raw = prefs.getString(_legacyTokensKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final map = jsonDecode(raw);
        if (map is Map) {
          for (final entry in map.entries) {
            final type = debridTypeFromName('${entry.key}');
            final token = entry.value;
            if (type != null && token is String && token.isNotEmpty) {
              tokens[type] = token;
            }
          }
        }
      } catch (_) {
        // JSON corrupto: se ignora y se prueba con el formato de token único.
      }
    }

    final legacyToken = prefs.getString(_legacyTokenKey) ?? '';
    if (legacyToken.isNotEmpty) {
      final type = debridTypeFromName(prefs.getString(_legacyTypeKey) ?? '') ??
          DebridType.realDebrid;
      tokens.putIfAbsent(type, () => legacyToken);
    }

    return [
      for (final type in DebridType.values)
        if (tokens[type] != null)
          DebridServiceConfig(type: type, token: tokens[type]!),
    ];
  }

  static Future<void> _write(
    SharedPreferences prefs,
    List<DebridServiceConfig> services,
  ) {
    return prefs.setString(
      debridConfigsKey,
      jsonEncode({
        'version': 2,
        'services': [for (final config in services) config.toJson()],
      }),
    );
  }
}

final debridSettingsProvider =
    StateNotifierProvider<DebridSettingsNotifier, DebridSettings>((ref) {
  final notifier = DebridSettingsNotifier();
  notifier.load();
  return notifier;
});
