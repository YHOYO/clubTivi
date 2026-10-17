// El historial de canales visitados: lo que se guarda entre sesiones para
// volver al último canal al abrir la app y para poder ver lo que se ha ido
// viendo.
import 'dart:convert';

import 'package:clubtivi/data/services/channel_history_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('el último visitado es la primera entrada y no se repite', () async {
    final history = ChannelHistory();
    addTearDown(history.dispose);

    await history.record('a');
    await history.record('b');
    await history.record('a');

    expect(history.lastChannelId, 'a');
    expect(
        history.idsByRecency,
        [
          'a',
          'b',
        ],
        reason: 'volver a un canal lo sube al frente en vez de duplicarlo');
  });

  test('el historial se relee tal cual se dejó', () async {
    final first = ChannelHistory();
    await first.record('a');
    await first.record('b');
    first.dispose();

    final reopened = ChannelHistory();
    addTearDown(reopened.dispose);
    await reopened.load();

    expect(reopened.idsByRecency, ['b', 'a']);
    expect(reopened.lastChannelId, 'b');
  });

  test('el historial tiene tope: lo más viejo se cae', () async {
    final history = ChannelHistory();
    addTearDown(history.dispose);

    for (var i = 0; i < ChannelHistory.maxEntries + 5; i++) {
      await history.record('canal-$i');
    }

    expect(history.visits, hasLength(ChannelHistory.maxEntries));
    expect(history.lastChannelId, 'canal-${ChannelHistory.maxEntries + 4}');
    expect(
      history.idsByRecency,
      isNot(contains('canal-0')),
      reason: 'lo más viejo sale de la lista',
    );
  });

  test('quitar un canal y vaciar el historial se guardan', () async {
    final history = ChannelHistory();
    await history.record('a');
    await history.record('b');
    await history.remove('b');
    expect(history.idsByRecency, ['a']);

    await history.clear();
    expect(history.visits, isEmpty);
    expect(history.lastChannelId, isNull);
    history.dispose();

    final reopened = ChannelHistory();
    addTearDown(reopened.dispose);
    await reopened.load();
    expect(reopened.visits, isEmpty, reason: 'el borrado también se guarda');
  });

  test('lo guardado por una versión anterior se lee sin romper nada', () async {
    SharedPreferences.setMockInitialValues({
      ChannelHistory.prefKey: jsonEncode([
        {'id': 'bueno', 'at': 1000},
        {'id': '', 'at': 1000},
        {'sin': 'id'},
        'texto suelto',
        {'id': 'bueno', 'at': 2000},
      ]),
    });

    final history = ChannelHistory();
    addTearDown(history.dispose);
    await history.load();

    expect(
        history.idsByRecency,
        [
          'bueno',
        ],
        reason: 'se queda lo que se entiende, sin repetir canales');
  });

  test('un historial corrupto no impide arrancar', () async {
    SharedPreferences.setMockInitialValues({
      ChannelHistory.prefKey: 'esto no es json',
    });

    final history = ChannelHistory();
    addTearDown(history.dispose);
    await history.load();

    expect(history.visits, isEmpty);
    expect(history.lastChannelId, isNull);
  });
}
