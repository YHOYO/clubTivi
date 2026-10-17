import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Un canal visitado y cuándo se vio por última vez.
@immutable
class ChannelVisit {
  const ChannelVisit({required this.channelId, required this.at});

  final String channelId;
  final DateTime at;

  Map<String, Object> toJson() => {
        'id': channelId,
        'at': at.millisecondsSinceEpoch,
      };

  static ChannelVisit? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    if (id is! String || id.isEmpty) return null;
    final at = value['at'];
    return ChannelVisit(
      channelId: id,
      at: DateTime.fromMillisecondsSinceEpoch(at is int ? at : 0),
    );
  }
}

/// Historial de los canales que se están visitando.
///
/// Se guarda en las preferencias, igual que el último canal y los nombres
/// personalizados: son pocos datos, se leen una vez al arrancar y no necesitan
/// una tabla. Cada visita sube al frente, así que «el último visitado» es la
/// primera entrada y la lista no repite canales.
///
/// Vive por encima de la pantalla: el reproductor apunta aquí cualquier canal
/// que el usuario abra, venga de la lista, de la guía o del mando.
class ChannelHistory extends ChangeNotifier {
  static const prefKey = 'channel_history';

  /// Tope de visitas guardadas: más que suficiente para «seguir viendo» y
  /// barato de leer en cada arranque.
  static const maxEntries = 100;

  List<ChannelVisit> _visits = const [];
  bool _loaded = false;
  Future<void>? _loading;

  /// De la más reciente a la más antigua.
  List<ChannelVisit> get visits => List.unmodifiable(_visits);

  bool get isLoaded => _loaded;

  /// El último canal visitado, que es el que la app vuelve a poner al abrirse.
  String? get lastChannelId => _visits.isEmpty ? null : _visits.first.channelId;

  /// Los canales del historial, del más reciente al más antiguo.
  List<String> get idsByRecency => [
        for (final visit in _visits) visit.channelId,
      ];

  Future<void> load() => _loading ??= _restore();

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _visits = _decode(prefs.getString(prefKey));
    } catch (_) {
      // Preferencias corruptas: se empieza de cero en vez de romper el arranque.
      _visits = const [];
    }
    _loaded = true;
    notifyListeners();
  }

  /// Apunta una visita. Si el canal ya estaba, sube al frente con la hora nueva
  /// en lugar de repetirse.
  Future<void> record(String channelId) async {
    if (channelId.isEmpty) return;
    if (!_loaded) await load();
    final next = <ChannelVisit>[
      ChannelVisit(channelId: channelId, at: DateTime.now()),
      ..._visits.where((visit) => visit.channelId != channelId),
    ];
    _visits = next.length > maxEntries ? next.sublist(0, maxEntries) : next;
    notifyListeners();
    await _save();
  }

  Future<void> remove(String channelId) async {
    if (!_loaded) await load();
    final next =
        _visits.where((visit) => visit.channelId != channelId).toList();
    if (next.length == _visits.length) return;
    _visits = next;
    notifyListeners();
    await _save();
  }

  Future<void> clear() async {
    if (!_loaded) await load();
    if (_visits.isEmpty) return;
    _visits = const [];
    notifyListeners();
    await _save();
  }

  List<ChannelVisit> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final visits = <ChannelVisit>[];
      final seen = <String>{};
      for (final entry in decoded) {
        final visit = ChannelVisit.fromJson(entry);
        // Tolerante con lo guardado por versiones anteriores: se queda lo que
        // se entiende, sin repetir canales.
        if (visit == null || !seen.add(visit.channelId)) continue;
        visits.add(visit);
      }
      return visits.length > maxEntries
          ? visits.sublist(0, maxEntries)
          : visits;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        prefKey,
        jsonEncode([for (final visit in _visits) visit.toJson()]),
      );
    } catch (_) {
      // Sin disco no hay historial, pero la app sigue funcionando.
    }
  }
}

final channelHistoryProvider = Provider<ChannelHistory>((ref) {
  final history = ChannelHistory();
  unawaited(history.load());
  ref.onDispose(history.dispose);
  return history;
});
