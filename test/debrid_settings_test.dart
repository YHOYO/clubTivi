// El estado de debrid es el único dueño de "qué servicio resuelve": habilitar,
// deshabilitar sin perder el token, orden de prioridad y migración de las
// claves antiguas. Estos tests fijan ese contrato.
import 'dart:convert';

import 'package:clubtivi/data/datasources/remote/debrid_service.dart';
import 'package:clubtivi/data/services/debrid_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<DebridSettingsNotifier> loadedNotifier() async {
    final notifier = DebridSettingsNotifier();
    await notifier.load();
    return notifier;
  }

  test('migra el mapa tipo→token y borra la clave heredada', () async {
    SharedPreferences.setMockInitialValues({
      'shows_debrid_tokens': jsonEncode({
        'allDebrid': 'ad-token',
        'realDebrid': 'rd-token',
      }),
    });

    final notifier = await loadedNotifier();

    expect(
      notifier.state.services.map((s) => s.type),
      [DebridType.realDebrid, DebridType.allDebrid],
      reason: 'el orden migrado es determinista (orden del enum)',
    );
    expect(notifier.state.configFor(DebridType.realDebrid)!.token, 'rd-token');
    expect(notifier.state.configFor(DebridType.allDebrid)!.enabled, isTrue);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('shows_debrid_tokens'), isNull);
    expect(prefs.getString(debridConfigsKey), isNotNull);
  });

  test('migra el token único de la versión más antigua', () async {
    SharedPreferences.setMockInitialValues({
      'shows_debrid_api_token': 'legacy-token',
      'shows_debrid_type': 'allDebrid',
    });

    final notifier = await loadedNotifier();

    expect(notifier.state.services, hasLength(1));
    expect(notifier.state.services.single.type, DebridType.allDebrid);
    expect(notifier.state.services.single.token, 'legacy-token');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('shows_debrid_api_token'), isNull);
    expect(prefs.getString('shows_debrid_type'), isNull);
  });

  test('deshabilitar conserva el token y no deja servicios resolviendo',
      () async {
    SharedPreferences.setMockInitialValues({
      debridConfigsKey: jsonEncode({
        'version': 2,
        'services': [
          {'type': 'realDebrid', 'token': 'rd-token', 'enabled': true},
        ],
      }),
    });
    final notifier = await loadedNotifier();

    await notifier.setEnabled(DebridType.realDebrid, false);

    expect(notifier.state.hasEnabledService, isFalse);
    expect(notifier.state.configuredCount, 1);
    expect(notifier.state.enabledCount, 0);
    expect(
      notifier.state.configFor(DebridType.realDebrid)!.token,
      'rd-token',
      reason: 'apagar no borra la API',
    );

    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(debridConfigsKey)!;
    expect(stored, contains('rd-token'));
    expect(stored, contains('"enabled":false'));
  });

  test('el orden de la lista decide quién resuelve', () async {
    SharedPreferences.setMockInitialValues({
      debridConfigsKey: jsonEncode({
        'version': 2,
        'services': [
          {'type': 'realDebrid', 'token': 'rd-token', 'enabled': true},
          {'type': 'allDebrid', 'token': 'ad-token', 'enabled': true},
        ],
      }),
    });
    final notifier = await loadedNotifier();

    expect(notifier.state.enabledTypes,
        [DebridType.realDebrid, DebridType.allDebrid]);

    await notifier.move(1, 0);

    expect(
      notifier.state.enabledTypes,
      [DebridType.allDebrid, DebridType.realDebrid],
      reason: 'AllDebrid pasa a ser el primero',
    );
    expect(notifier.state.services.first.type, DebridType.allDebrid);
  });

  test('un servicio nuevo entra al final y conserva la prioridad existente',
      () async {
    SharedPreferences.setMockInitialValues({
      debridConfigsKey: jsonEncode({
        'version': 2,
        'services': [
          {'type': 'realDebrid', 'token': 'rd-token', 'enabled': true},
        ],
      }),
    });
    final notifier = await loadedNotifier();

    await notifier.saveToken(DebridType.allDebrid, 'ad-token');

    expect(
      notifier.state.services.map((s) => s.type),
      [DebridType.realDebrid, DebridType.allDebrid],
    );
    expect(notifier.state.services.last.enabled, isTrue);
  });

  test('guardar un token nuevo mantiene el estado deshabilitado', () async {
    SharedPreferences.setMockInitialValues({
      debridConfigsKey: jsonEncode({
        'version': 2,
        'services': [
          {'type': 'realDebrid', 'token': 'rd-token', 'enabled': false},
        ],
      }),
    });
    final notifier = await loadedNotifier();

    await notifier.saveToken(DebridType.realDebrid, 'rd-token-2');

    expect(notifier.state.configFor(DebridType.realDebrid)!.token,
        'rd-token-2');
    expect(notifier.state.configFor(DebridType.realDebrid)!.enabled, isFalse);
  });

  test('quitar un servicio elimina el token persistido', () async {
    SharedPreferences.setMockInitialValues({
      debridConfigsKey: jsonEncode({
        'version': 2,
        'services': [
          {'type': 'realDebrid', 'token': 'rd-token', 'enabled': true},
          {'type': 'allDebrid', 'token': 'ad-token', 'enabled': true},
        ],
      }),
    });
    final notifier = await loadedNotifier();

    await notifier.remove(DebridType.realDebrid);

    expect(notifier.state.configuredCount, 1);
    expect(notifier.state.configFor(DebridType.realDebrid), isNull);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(debridConfigsKey), isNot(contains('rd-token')));
    expect(prefs.getString(debridConfigsKey), contains('ad-token'));
  });

  test('releer persiste habilitado y orden en un proceso nuevo', () async {
    SharedPreferences.setMockInitialValues({
      debridConfigsKey: jsonEncode({
        'version': 2,
        'services': [
          {'type': 'realDebrid', 'token': 'rd-token', 'enabled': true},
          {'type': 'allDebrid', 'token': 'ad-token', 'enabled': true},
        ],
      }),
    });
    final first = await loadedNotifier();
    await first.move(1, 0);
    await first.setEnabled(DebridType.allDebrid, false);

    final second = await loadedNotifier();

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

    final notifier = await loadedNotifier();

    expect(notifier.state.services.single.type, DebridType.realDebrid);
    expect(notifier.state.services.single.token, 'rd-token');
  });

  test('sin configuración arranca en modo sin debrid', () async {
    final notifier = await loadedNotifier();

    expect(notifier.state.services, isEmpty);
    expect(notifier.state.hasEnabledService, isFalse);
    expect(notifier.state.enabledCount, 0);
  });
}
