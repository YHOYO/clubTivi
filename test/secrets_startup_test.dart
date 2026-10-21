// El arranque ya no espera a la migración de credenciales. Estos tests
// demuestran las dos mitades del contrato: el primer frame se pinta con la
// migración a medias y, en ese mismo instante, una lectura de secretos espera
// a la puerta y sale con el valor ya migrado (y las preferencias limpias).
import 'dart:async';
import 'dart:convert';

import 'package:clubtivi/app/app.dart';
import 'package:clubtivi/app/secrets_bootstrap.dart';
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/debrid_settings.dart';
import 'package:clubtivi/data/services/secret_store.dart';
import 'package:clubtivi/data/services/secret_store_provider.dart';
import 'package:clubtivi/data/services/secrets_ready.dart';
import 'package:clubtivi/features/providers/provider_manager.dart';
import 'package:clubtivi/features/shows/shows_providers.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Un almacén que no responde hasta que el test lo abre: así la migración se
/// queda exactamente donde interesa observarla.
class _GatedStore implements SecretStore {
  final _gate = Completer<void>();
  final _inner = MemorySecretStore();

  Map<String, String> get values => _inner.values;
  bool get isBlocked => !_gate.isCompleted;

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<String?> read(String key) async {
    await _gate.future;
    return _inner.read(key);
  }

  @override
  Future<void> write(String key, String value) async {
    await _gate.future;
    await _inner.write(key, value);
  }

  @override
  Future<void> delete(String key) async {
    await _gate.future;
    await _inner.delete(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<db.AppDatabase> databaseWithXtream() async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    await database.upsertProvider(db.ProvidersCompanion.insert(
      id: 'xtream-1',
      name: 'Xtream',
      type: 'xtream',
      url: const Value('http://example.com'),
      username: const Value('user'),
      password: const Value('xtream-pass'),
    ));
    return database;
  }

  Map<String, Object> legacyPrefs() => {
        'shows_trakt_client_id': 'trakt-legacy',
        'shows_tmdb_api_key': 'tmdb-legacy',
        'shows_debrid_configs': jsonEncode({
          'version': 2,
          'services': [
            {'type': 'allDebrid', 'token': 'ad-token', 'enabled': true},
          ],
        }),
        'lg_webos_key_10.0.0.2': 'tv-key',
      };

  testWidgets('el primer frame se pinta antes de terminar la migración',
      (tester) async {
    SharedPreferences.setMockInitialValues(legacyPrefs());
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final store = _GatedStore();
    final container = createAppContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        secretStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ClubTiviApp(),
      ),
    );
    await tester.pump();

    // Hay frame con la migración todavía parada en el almacén.
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(
      store.isBlocked,
      isTrue,
      reason: 'la migración no puede haber terminado: el almacén no respondió',
    );
    expect(
      (await SharedPreferences.getInstance())
          .getString('shows_trakt_client_id'),
      'trakt-legacy',
      reason: 'mientras tanto el legado sigue intacto',
    );

    store.release();
    await tester.runAsync(() => container.read(secretsReadyProvider));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('shows_trakt_client_id'), isNull);
    expect(store.values[SecretKeys.traktClientId], 'trakt-legacy');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  test('un lector espera la puerta y ve el valor migrado', () async {
    SharedPreferences.setMockInitialValues(legacyPrefs());
    final database = await databaseWithXtream();
    addTearDown(database.close);
    final store = _GatedStore();
    final container = createAppContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        secretStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(container.dispose);

    // Las dos lecturas se piden con la migración todavía bloqueada.
    container.listen(showsRepositoryProvider, (_, _) {});
    final repoFuture = container.read(showsRepositoryProvider.future);
    final passwordFuture =
        container.read(providerManagerProvider).passwordFor('xtream-1');

    var repoDone = false;
    var passwordDone = false;
    unawaited(repoFuture.then((_) => repoDone = true));
    unawaited(passwordFuture.then((_) => passwordDone = true));
    await pumpEventQueue();

    expect(repoDone, isFalse, reason: 'el repositorio espera a la migración');
    expect(
      passwordDone,
      isFalse,
      reason: 'la contraseña Xtream espera a la migración',
    );

    store.release();
    final repo = await repoFuture;
    final password = await passwordFuture;

    expect(repo.hasTrakt, isTrue);
    expect(repo.hasTmdb, isTrue);
    expect(repo.hasDebrid, isTrue);
    expect(password, 'xtream-pass');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), isNot(contains('shows_trakt_client_id')));
    expect(prefs.getKeys(), isNot(contains('shows_tmdb_api_key')));
    expect(prefs.getKeys(), isNot(contains('lg_webos_key_10.0.0.2')));
    expect(prefs.getString(debridConfigsKey), isNot(contains('token')));

    expect(store.values[SecretKeys.traktClientId], 'trakt-legacy');
    expect(store.values[SecretKeys.tmdbApiKey], 'tmdb-legacy');
    expect(store.values[SecretKeys.debridToken('allDebrid')], 'ad-token');
    expect(store.values[SecretKeys.webosClientKey('10.0.0.2')], 'tv-key');
    expect(store.values[SecretKeys.providerPassword('xtream-1')], 'xtream-pass');
    expect(
      (await database.getAllProviders()).single.password,
      isNull,
      reason: 'la base no conserva la contraseña en claro',
    );
  });

  test('la puerta no escribe nada en una instalación vacía', () async {
    SharedPreferences.setMockInitialValues({});
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final store = MemorySecretStore();
    final container = createAppContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        secretStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(container.dispose);

    await container.read(secretsReadyProvider);

    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    expect(store.values, isEmpty);
  });

  test('sin almacén la puerta se abre y el lector ve el legado', () async {
    SharedPreferences.setMockInitialValues(legacyPrefs());
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final container = createAppContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        secretStoreProvider.overrideWithValue(const UnavailableSecretStore()),
      ],
    );
    addTearDown(container.dispose);

    container.listen(showsRepositoryProvider, (_, _) {});
    final repo = await container.read(showsRepositoryProvider.future);

    expect(repo.hasTrakt, isTrue, reason: 'el legado se sigue usando');
    expect(repo.hasTmdb, isTrue);
    expect(repo.hasDebrid, isTrue);
    expect(
      container.read(showsApiKeysProvider.notifier).storageAvailable,
      isFalse,
    );

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('shows_trakt_client_id'), 'trakt-legacy');
    expect(prefs.getString('shows_tmdb_api_key'), 'tmdb-legacy');
    final debrid = jsonDecode(prefs.getString(debridConfigsKey)!) as Map;
    expect(
      (debrid['services'] as List).single['token'],
      'ad-token',
      reason: 'sin almacén no se escribe un documento sin el token',
    );
  });
}
