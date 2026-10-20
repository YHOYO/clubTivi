// El estado de debrid es el único dueño de "qué servicio resuelve": habilitar,
// deshabilitar sin perder el token, orden de prioridad y migración de las
// claves antiguas. Los tokens viven en el almacén seguro, nunca en
// preferencias; estos tests fijan ese contrato.
import 'dart:convert';

import 'package:clubtivi/data/datasources/remote/debrid_service.dart';
import 'package:clubtivi/data/services/debrid_settings.dart';
import 'package:clubtivi/data/services/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<DebridSettingsNotifier> loadedNotifier({
    SecretStore? secrets,
  }) async {
    final notifier = DebridSettingsNotifier(
      secrets: secrets ?? MemorySecretStore(),
    );
    await notifier.load();
    return notifier;
  }

  /// Documento v3 con servicios pero sin tokens (lo que se escribe hoy).
  String v3(List<Map<String, Object?>> services) =>
      jsonEncode({'version': 3, 'services': services});

  test('migra el mapa tipo→token al almacén y no deja el token en prefs',
      () async {
    SharedPreferences.setMockInitialValues({
      'shows_debrid_tokens': jsonEncode({
        'allDebrid': 'ad-token',
        'realDebrid': 'rd-token',
      }),
    });
    final store = MemorySecretStore();

    final notifier = await loadedNotifier(secrets: store);

    expect(
      notifier.state.services.map((s) => s.type),
      [DebridType.realDebrid, DebridType.allDebrid],
      reason: 'el orden migrado es determinista (orden del enum)',
    );
    expect(notifier.state.configFor(DebridType.realDebrid)!.token, 'rd-token');
    expect(notifier.state.configFor(DebridType.allDebrid)!.enabled, isTrue);
    expect(notifier.storageAvailable, isTrue);
    expect(store.values[SecretKeys.debridToken('realDebrid')], 'rd-token');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('shows_debrid_tokens'), isNull);
    final stored = prefs.getString(debridConfigsKey)!;
    expect(stored, isNot(contains('rd-token')));
    expect(stored, contains('"version":3'));
  });

  test('migra el token único de la versión más antigua', () async {
    SharedPreferences.setMockInitialValues({
      'shows_debrid_api_token': 'legacy-token',
      'shows_debrid_type': 'allDebrid',
    });
    final store = MemorySecretStore();

    final notifier = await loadedNotifier(secrets: store);

    expect(notifier.state.services.single.type, DebridType.allDebrid);
    expect(notifier.state.services.single.token, 'legacy-token');
    expect(store.values[SecretKeys.debridToken('allDebrid')], 'legacy-token');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('shows_debrid_api_token'), isNull);
    expect(prefs.getString('shows_debrid_type'), isNull);
  });

  test('un documento v2 se migra una sola vez y es idempotente', () async {
    SharedPreferences.setMockInitialValues({
      debridConfigsKey: jsonEncode({
        'version': 2,
        'services': [
          {'type': 'realDebrid', 'token': 'rd-token', 'enabled': true},
        ],
      }),
    });
    final store = MemorySecretStore();

    await loadedNotifier(secrets: store);
    final prefs = await SharedPreferences.getInstance();
    final migrated = prefs.getString(debridConfigsKey)!;
    expect(migrated, contains('"version":3'));
    expect(migrated, isNot(contains('rd-token')));

    final second = await loadedNotifier(secrets: store);
    expect(second.state.configFor(DebridType.realDebrid)!.token, 'rd-token');
    expect(
      prefs.getString(debridConfigsKey),
      migrated,
      reason: 'una segunda lectura no reescribe el documento',
    );
  });

  test('restaurar un backup sin tokens conserva orden y habilitado', () async {
    SharedPreferences.setMockInitialValues({
      debridConfigsKey: v3([
        {'type': 'allDebrid', 'enabled': true},
        {'type': 'realDebrid', 'enabled': false},
      ]),
    });
    final store = MemorySecretStore()
      ..values[SecretKeys.debridToken('allDebrid')] = 'ad-token';

    final notifier = await loadedNotifier(secrets: store);

    expect(
      notifier.state.services.map((s) => s.type),
      [DebridType.allDebrid, DebridType.realDebrid],
      reason: 'la estructura fue restaurada; sólo falta la credencial',
    );
    expect(notifier.state.enabledTypes, [DebridType.allDebrid]);
    expect(notifier.state.configFor(DebridType.realDebrid)!.token, isEmpty);
  });

  test('sin almacén seguro conserva los tokens y avisa', () async {
    SharedPreferences.setMockInitialValues({
      debridConfigsKey: jsonEncode({
        'version': 2,
        'services': [
          {'type': 'realDebrid', 'token': 'rd-token', 'enabled': true},
        ],
      }),
    });
    final notifier = await loadedNotifier(secrets: const UnavailableSecretStore());

    expect(notifier.state.configFor(DebridType.realDebrid)!.token, 'rd-token');
    expect(notifier.storageAvailable, isFalse);

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(debridConfigsKey),
      contains('rd-token'),
      reason: 'no se borra lo que aún no se ha podido guardar de forma segura',
    );
  });

  test('deshabilitar conserva el token y no deja servicios resolviendo',
      () async {
    SharedPreferences.setMockInitialValues({
      debridConfigsKey: v3([
        {'type': 'realDebrid', 'enabled': true},
      ]),
    });
    final store = MemorySecretStore()
      ..values[SecretKeys.debridToken('realDebrid')] = 'rd-token';
    final notifier = await loadedNotifier(secrets: store);

    await notifier.setEnabled(DebridType.realDebrid, false);

    expect(notifier.state.hasEnabledService, isFalse);
    expect(notifier.state.configuredCount, 1);
    expect(notifier.state.configFor(DebridType.realDebrid)!.token, 'rd-token');
    expect(store.values[SecretKeys.debridToken('realDebrid')], 'rd-token');

    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(debridConfigsKey)!;
    expect(stored, contains('"enabled":false'));
    expect(stored, isNot(contains('rd-token')));
  });

  test('el orden de la lista decide quién resuelve', () async {
    SharedPreferences.setMockInitialValues({
      debridConfigsKey: v3([
        {'type': 'realDebrid', 'enabled': true},
        {'type': 'allDebrid', 'enabled': true},
      ]),
    });
    final store = MemorySecretStore()
      ..values[SecretKeys.debridToken('realDebrid')] = 'rd-token'
      ..values[SecretKeys.debridToken('allDebrid')] = 'ad-token';
    final notifier = await loadedNotifier(secrets: store);

    expect(notifier.state.enabledTypes,
        [DebridType.realDebrid, DebridType.allDebrid]);

    await notifier.move(1, 0);

    expect(
      notifier.state.enabledTypes,
      [DebridType.allDebrid, DebridType.realDebrid],
      reason: 'AllDebrid pasa a ser el primero',
    );
  });

  test('un servicio nuevo entra al final y su token va al almacén', () async {
    SharedPreferences.setMockInitialValues({
      debridConfigsKey: v3([
        {'type': 'realDebrid', 'enabled': true},
      ]),
    });
    final store = MemorySecretStore()
      ..values[SecretKeys.debridToken('realDebrid')] = 'rd-token';
    final notifier = await loadedNotifier(secrets: store);

    await notifier.saveToken(DebridType.allDebrid, 'ad-token');

    expect(
      notifier.state.services.map((s) => s.type),
      [DebridType.realDebrid, DebridType.allDebrid],
    );
    expect(store.values[SecretKeys.debridToken('allDebrid')], 'ad-token');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(debridConfigsKey), isNot(contains('ad-token')));
  });

  test('guardar un token nuevo mantiene el estado deshabilitado', () async {
    SharedPreferences.setMockInitialValues({
      debridConfigsKey: v3([
        {'type': 'realDebrid', 'enabled': false},
      ]),
    });
    final store = MemorySecretStore()
      ..values[SecretKeys.debridToken('realDebrid')] = 'rd-token';
    final notifier = await loadedNotifier(secrets: store);

    await notifier.saveToken(DebridType.realDebrid, 'rd-token-2');

    expect(notifier.state.configFor(DebridType.realDebrid)!.token,
        'rd-token-2');
    expect(notifier.state.configFor(DebridType.realDebrid)!.enabled, isFalse);
    expect(store.values[SecretKeys.debridToken('realDebrid')], 'rd-token-2');
  });

  test('quitar un servicio borra su token del almacén', () async {
    SharedPreferences.setMockInitialValues({
      debridConfigsKey: v3([
        {'type': 'realDebrid', 'enabled': true},
        {'type': 'allDebrid', 'enabled': true},
      ]),
    });
    final store = MemorySecretStore()
      ..values[SecretKeys.debridToken('realDebrid')] = 'rd-token'
      ..values[SecretKeys.debridToken('allDebrid')] = 'ad-token';
    final notifier = await loadedNotifier(secrets: store);

    await notifier.remove(DebridType.realDebrid);

    expect(notifier.state.configuredCount, 1);
    expect(notifier.state.configFor(DebridType.realDebrid), isNull);
    expect(store.values.containsKey(SecretKeys.debridToken('realDebrid')),
        isFalse);
    expect(store.values[SecretKeys.debridToken('allDebrid')], 'ad-token');
  });

  test('releer persiste habilitado y orden en un proceso nuevo', () async {
    SharedPreferences.setMockInitialValues({
      debridConfigsKey: v3([
        {'type': 'realDebrid', 'enabled': true},
        {'type': 'allDebrid', 'enabled': true},
      ]),
    });
    final store = MemorySecretStore()
      ..values[SecretKeys.debridToken('realDebrid')] = 'rd-token'
      ..values[SecretKeys.debridToken('allDebrid')] = 'ad-token';

    final first = await loadedNotifier(secrets: store);
    await first.move(1, 0);
    await first.setEnabled(DebridType.allDebrid, false);

    final second = await loadedNotifier(secrets: store);

    expect(second.state.services.map((s) => s.type),
        [DebridType.allDebrid, DebridType.realDebrid]);
    expect(second.state.configFor(DebridType.allDebrid)!.enabled, isFalse);
    expect(second.state.enabledTypes, [DebridType.realDebrid]);
  });

  test('JSON corrupto cae a la migración en vez de dejar la app vacía',
      () async {
    SharedPreferences.setMockInitialValues({
      debridConfigsKey: '{not json',
      'shows_debrid_tokens': jsonEncode({'realDebrid': 'rd-token'}),
    });
    final store = MemorySecretStore();

    final notifier = await loadedNotifier(secrets: store);

    expect(notifier.state.services.single.type, DebridType.realDebrid);
    expect(notifier.state.services.single.token, 'rd-token');
    expect(store.values[SecretKeys.debridToken('realDebrid')], 'rd-token');
  });

  test('sin configuración arranca en modo sin debrid', () async {
    final notifier = await loadedNotifier();

    expect(notifier.state.services, isEmpty);
    expect(notifier.state.hasEnabledService, isFalse);
  });
}
