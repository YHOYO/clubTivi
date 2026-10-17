import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../datasources/local/database.dart' as db;
import 'channel_probe_service.dart';

/// Resumen de salud de los canales de un proveedor.
///
/// Un proveedor con 12.000 canales de los que sirven 300 no se arregla canal a
/// canal: lo que hay que ver es de quién es la culpa del resto, porque una
/// ráfaga de 502 dice «este servidor no aguanta» y una de 404 dice «esta lista
/// está vieja».
class ProviderHealthSummary {
  final String providerId;
  final String providerName;
  final int total;

  /// Canales que sirven (rápidos o sólo con una petición en vuelo).
  final int working;

  /// Cuántos de los que sirven son lentos: contestan sólo cuando se les pide solos.
  final int slow;

  /// 5xx y 401/403: fallo que apunta al servidor, no a la entrada de la lista.
  final int serverSide;

  /// Sin respuesta: no se puede atribuir con esta medición.
  final int noAnswer;

  /// 404, páginas web en vez de lista: la entrada ya no lleva a nada.
  final int dead;

  /// La red impide llegar: certificado sin verificar o página de bloqueo. Ni el
  /// servidor ni el canal tienen la culpa, así que no se mezcla con los demás.
  final int blocked;

  final DateTime? checkedAt;

  const ProviderHealthSummary({
    required this.providerId,
    required this.providerName,
    required this.total,
    required this.working,
    required this.slow,
    required this.serverSide,
    required this.noAnswer,
    required this.dead,
    this.blocked = 0,
    this.checkedAt,
  });

  bool get hasData => total > 0;

  /// 0..1 de canales que sirven.
  double get workingRatio => total == 0 ? 0 : working / total;

  /// ¿Los fallos apuntan al servidor? Entonces bajar el ritmo (o refrescar el
  /// proveedor) tiene sentido; si dominan los 404, lo que falla es la lista.
  bool get blamesTheServer =>
      blocked == 0 && serverSide > 0 && serverSide + noAnswer >= dead;

  /// ¿Es la propia red la que no deja llegar? Se antepone a todo lo demás: si
  /// el filtro bloquea el dominio, ningún canal de esa lista se va a ver.
  bool get blamesTheNetwork => blocked > 0 && blocked + working >= total / 2;

  String get label {
    if (!hasData) return 'Not checked yet';
    final parts = <String>[
      '$working/${total} work',
      if (slow > 0) '$slow slow',
      if (blocked > 0) '$blocked blocked by the network',
      if (serverSide > 0) '$serverSide the server refused',
      if (noAnswer > 0) '$noAnswer no answer',
      if (dead > 0) '$dead gone',
    ];
    return parts.join(' · ');
  }

  /// Frase corta para la tarjeta del proveedor.
  String get diagnosis {
    if (!hasData) return 'Run a check to see how many channels play.';
    if (blamesTheNetwork) {
      return 'Your network is filtering these domains: the certificate cannot '
          'be verified and, ignoring it, the answer is a blocking page. The '
          'provider and the channels are fine — check the antivirus, the DNS '
          'filter or the internet provider before blaming the list.';
    }
    if (working == 0 && dead > 0 && dead >= serverSide + noAnswer) {
      return 'Almost nothing works and what fails is gone: this list looks old.';
    }
    if (blamesTheServer) {
      return 'Most failures point at the server (5xx or refusals), not at the '
          'channels: it is choking. Checks now run with fewer requests in '
          'flight and slower channels are retried one at a time.';
    }
    if (workingRatio < 0.2) {
      return 'Only a few channels answer. Scanning the channels you actually '
          'watch is quicker than scanning the whole list.';
    }
    return '${(workingRatio * 100).round()}% of the checked channels answer.';
  }

  Map<String, dynamic> toJson() => {
        'id': providerId,
        'name': providerName,
        'total': total,
        'working': working,
        'slow': slow,
        'server': serverSide,
        'noAnswer': noAnswer,
        'dead': dead,
        'blocked': blocked,
        if (checkedAt != null) 'at': checkedAt!.millisecondsSinceEpoch,
      };

  factory ProviderHealthSummary.fromJson(Map<String, dynamic> json) =>
      ProviderHealthSummary(
        providerId: json['id'] as String? ?? '',
        providerName: json['name'] as String? ?? '',
        total: json['total'] as int? ?? 0,
        working: json['working'] as int? ?? 0,
        slow: json['slow'] as int? ?? 0,
        serverSide: json['server'] as int? ?? 0,
        noAnswer: json['noAnswer'] as int? ?? 0,
        dead: json['dead'] as int? ?? 0,
        blocked: json['blocked'] as int? ?? 0,
        checkedAt: json['at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(json['at'] as int),
      );

  /// Agrupa los resultados de un escaneo por proveedor.
  static Map<String, ProviderHealthSummary> fromResults(
    Iterable<MapEntry<db.Channel, ProbeResult>> results, {
    Map<String, String> providerNames = const {},
  }) {
    final totals = <String, int>{};
    final working = <String, int>{};
    final slow = <String, int>{};
    final server = <String, int>{};
    final noAnswer = <String, int>{};
    final dead = <String, int>{};
    final blocked = <String, int>{};

    for (final entry in results) {
      final id = entry.key.providerId;
      totals.update(id, (v) => v + 1, ifAbsent: () => 1);
      switch (entry.value.verdict) {
        case ProbeVerdict.works:
          working.update(id, (v) => v + 1, ifAbsent: () => 1);
          if (entry.value.status == ProbeStatus.slow) {
            slow.update(id, (v) => v + 1, ifAbsent: () => 1);
          }
        case ProbeVerdict.serverSide:
          server.update(id, (v) => v + 1, ifAbsent: () => 1);
        case ProbeVerdict.noAnswer:
          noAnswer.update(id, (v) => v + 1, ifAbsent: () => 1);
        case ProbeVerdict.dead:
          dead.update(id, (v) => v + 1, ifAbsent: () => 1);
        case ProbeVerdict.blocked:
          blocked.update(id, (v) => v + 1, ifAbsent: () => 1);
      }
    }

    final now = DateTime.now();
    return {
      for (final id in totals.keys)
        id: ProviderHealthSummary(
          providerId: id,
          providerName: providerNames[id] ?? id,
          total: totals[id] ?? 0,
          working: working[id] ?? 0,
          slow: slow[id] ?? 0,
          serverSide: server[id] ?? 0,
          noAnswer: noAnswer[id] ?? 0,
          dead: dead[id] ?? 0,
          blocked: blocked[id] ?? 0,
          checkedAt: now,
        ),
    };
  }
}

/// Guarda el último resumen por proveedor para que la pantalla de proveedores
/// lo muestre sin tener que volver a medir nada.
class ProviderHealthStore {
  static const _prefsKey = 'provider_health_v1';

  final Map<String, ProviderHealthSummary> _byProvider = {};
  bool _loaded = false;
  bool _saveScheduled = false;

  bool get isLoaded => _loaded;

  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null) {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        for (final entry in map.entries) {
          final value = entry.value;
          if (value is Map<String, dynamic>) {
            _byProvider[entry.key] = ProviderHealthSummary.fromJson(value);
          }
        }
      }
    } catch (e) {
      debugPrint('[Health] Could not read provider summaries: $e');
    }
    _loaded = true;
  }

  ProviderHealthSummary? summaryFor(String providerId) => _byProvider[providerId];

  Map<String, ProviderHealthSummary> get all =>
      Map.unmodifiable(_byProvider);

  void record(ProviderHealthSummary summary) {
    _byProvider[summary.providerId] = summary;
    _scheduleSave();
  }

  void recordAll(Iterable<ProviderHealthSummary> summaries) {
    for (final summary in summaries) {
      _byProvider[summary.providerId] = summary;
    }
    _scheduleSave();
  }

  /// Olvida los resúmenes de proveedores que ya no existen.
  void pruneTo(Set<String> providerIds) {
    _byProvider.removeWhere((id, _) => !providerIds.contains(id));
    _scheduleSave();
  }

  void clear() {
    _byProvider.clear();
    _scheduleSave();
  }

  void _scheduleSave() {
    if (_saveScheduled) return;
    _saveScheduled = true;
    Future.delayed(const Duration(seconds: 3), () {
      _saveScheduled = false;
      unawaited(save());
    });
  }

  Future<void> save() async {
    try {
      final payload = _byProvider.map((k, v) => MapEntry(k, v.toJson()));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(payload));
    } catch (e) {
      debugPrint('[Health] Could not save provider summaries: $e');
    }
  }
}

final providerHealthStoreProvider = Provider<ProviderHealthStore>((ref) {
  final store = ProviderHealthStore();
  unawaited(store.load());
  return store;
});
