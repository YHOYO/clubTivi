/// Ajustes del motor P2P: carpeta de descargas, puerto y límites de velocidad.
///
/// Es lógica pura + persistencia: el motor no lee de aquí, recibe los valores
/// ya resueltos desde el provider. Los valores inválidos se descartan en
/// lectura (puerto fuera de rango, límites negativos) para que un JSON corrupto
/// no deje el motor sin arrancar.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Clave persistida de los ajustes del motor P2P.
const String p2pSettingsKey = 'p2p_engine_settings';

/// Rango de puertos que se acepta configurar (por debajo, puertos de sistema).
const int kMinP2pPort = 1024;
const int kMaxP2pPort = 65535;

/// Valor centinela para `copyWith` con campos que se pueden volver a null.
const Object _unset = Object();

@immutable
class P2pSettings {
  /// Carpeta de descargas. `null` = la predeterminada (Descargas/clubTivi).
  final String? downloadDirectory;

  /// Puerto HTTP del motor. `null` = puerto libre automático.
  final int? port;

  /// Límite de bajada en KB/s. 0 = sin límite.
  final int downloadLimitKbps;

  /// Límite de subida en KB/s. 0 = sin límite.
  final int uploadLimitKbps;

  const P2pSettings({
    this.downloadDirectory,
    this.port,
    this.downloadLimitKbps = 0,
    this.uploadLimitKbps = 0,
  });

  static const P2pSettings defaults = P2pSettings();

  bool get hasCustomDownloadDirectory =>
      downloadDirectory != null && downloadDirectory!.isNotEmpty;

  bool get hasLimits => downloadLimitKbps > 0 || uploadLimitKbps > 0;

  /// Límite en bytes por segundo, que es lo que espera rqbit.
  int? get downloadLimitBytesPerSecond =>
      downloadLimitKbps > 0 ? downloadLimitKbps * 1024 : null;

  int? get uploadLimitBytesPerSecond =>
      uploadLimitKbps > 0 ? uploadLimitKbps * 1024 : null;

  P2pSettings copyWith({
    Object? downloadDirectory = _unset,
    Object? port = _unset,
    int? downloadLimitKbps,
    int? uploadLimitKbps,
  }) {
    return P2pSettings(
      downloadDirectory: identical(downloadDirectory, _unset)
          ? this.downloadDirectory
          : downloadDirectory as String?,
      port: identical(port, _unset) ? this.port : port as int?,
      downloadLimitKbps: downloadLimitKbps ?? this.downloadLimitKbps,
      uploadLimitKbps: uploadLimitKbps ?? this.uploadLimitKbps,
    );
  }

  Map<String, Object?> toJson() => {
        'version': 1,
        'download_directory': downloadDirectory,
        'port': port,
        'download_limit_kbps': downloadLimitKbps,
        'upload_limit_kbps': uploadLimitKbps,
      };

  /// Entrada inválida o corrupta se degrada al valor por defecto del campo.
  factory P2pSettings.fromJson(Object? json) {
    if (json is! Map) return defaults;
    final directory = json['download_directory'];
    final port = _int(json['port']);
    return P2pSettings(
      downloadDirectory: directory is String && directory.trim().isNotEmpty
          ? directory.trim()
          : null,
      port: port != null && port >= kMinP2pPort && port <= kMaxP2pPort
          ? port
          : null,
      downloadLimitKbps: _nonNegative(json['download_limit_kbps']),
      uploadLimitKbps: _nonNegative(json['upload_limit_kbps']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is P2pSettings &&
      other.downloadDirectory == downloadDirectory &&
      other.port == port &&
      other.downloadLimitKbps == downloadLimitKbps &&
      other.uploadLimitKbps == uploadLimitKbps;

  @override
  int get hashCode => Object.hash(
        downloadDirectory,
        port,
        downloadLimitKbps,
        uploadLimitKbps,
      );

  @override
  String toString() => 'P2pSettings(directory: $downloadDirectory, port: $port, '
      'down: $downloadLimitKbps KB/s, up: $uploadLimitKbps KB/s)';

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static int _nonNegative(Object? value) {
    final number = _int(value);
    if (number == null || number < 0) return 0;
    return number;
  }
}

/// Estado persistido del motor, al estilo del resto de ajustes de la app.
class P2pSettingsNotifier extends StateNotifier<P2pSettings> {
  P2pSettingsNotifier({
    P2pSettings initial = P2pSettings.defaults,
    SharedPreferences? preferences,
  })  : _prefs = preferences,
        super(initial);

  SharedPreferences? _prefs;
  Future<void>? _loading;
  bool _loaded = false;

  bool get isLoaded => _loaded;

  Future<SharedPreferences> _preferences() async =>
      _prefs ??= await SharedPreferences.getInstance();

  /// Lectura compartida: las mutaciones esperan a que termine para no escribir
  /// encima de una lectura a medio hacer.
  Future<void> load() {
    if (_loaded) return Future<void>.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    final prefs = await _preferences();
    final raw = prefs.getString(p2pSettingsKey);
    var value = P2pSettings.defaults;
    if (raw != null && raw.isNotEmpty) {
      try {
        value = P2pSettings.fromJson(jsonDecode(raw));
      } catch (_) {
        value = P2pSettings.defaults;
      }
    }
    _loaded = true;
    if (!mounted) return;
    state = value;
  }

  Future<void> save(P2pSettings settings) async {
    await load();
    final prefs = await _preferences();
    await prefs.setString(p2pSettingsKey, jsonEncode(settings.toJson()));
    if (!mounted) return;
    state = settings;
  }

  /// Carpeta personalizada; `null` vuelve a la predeterminada.
  Future<void> setDownloadDirectory(String? directory) async {
    await load();
    final trimmed = directory?.trim();
    final value = trimmed == null || trimmed.isEmpty ? null : trimmed;
    await save(state.copyWith(downloadDirectory: value));
  }

  /// Puerto fijo; `null` vuelve a elegir un puerto libre al arrancar.
  Future<void> setPort(int? port) async {
    await load();
    final valid =
        port != null && port >= kMinP2pPort && port <= kMaxP2pPort ? port : null;
    await save(state.copyWith(port: valid));
  }

  /// Límites en KB/s; 0 (o negativo) significa sin límite y omitir un valor lo
  /// deja como estaba.
  Future<void> setLimits({int? downloadKbps, int? uploadKbps}) async {
    await load();
    int resolve(int? value, int current) {
      if (value == null) return current;
      return value < 0 ? 0 : value;
    }

    await save(state.copyWith(
      downloadLimitKbps: resolve(downloadKbps, state.downloadLimitKbps),
      uploadLimitKbps: resolve(uploadKbps, state.uploadLimitKbps),
    ));
  }

  Future<void> reset() => save(P2pSettings.defaults);
}

final p2pSettingsProvider =
    StateNotifierProvider<P2pSettingsNotifier, P2pSettings>((ref) {
  final notifier = P2pSettingsNotifier();
  notifier.load();
  return notifier;
});
