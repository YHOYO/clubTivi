// El arranque es el único punto donde la migración puede correr antes de que
// ningún provider lea preferencias. Estos tests siembran el formato legado,
// arrancan con la misma función que usa `main` y miran el disco: preferencias
// limpias, valores intactos y nada perdido si el almacén seguro no está.
import 'dart:convert';

import 'package:clubtivi/app/secrets_bootstrap.dart';
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/datasources/remote/debrid_service.dart';
import 'package:clubtivi/data/services/debrid_settings.dart';
import 'package:clubtivi/data/services/secret_store.dart';
import 'package:clubtivi/data/services/secret_store_provider.dart';
import 'package:clubtivi/features/providers/provider_manager.dart';
import 'package:clubtivi/features/shows/shows_providers.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Arranca como `main`: contenedor propio, base en memoria y almacén dado.
  Future<ProviderContainer> boot({
    required SecretStore store,
    required db.AppDatabase database,
  }) async {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        secretStoreProvider.overrideWithValue(store),
      ],
    );
    await bootstrapSecrets(container);
    return container;
  }

  Future<db.AppDatabase> memoryDatabase() async =>
      db.AppDatabase.forTesting(NativeDatabase.memory());

  Future<db.AppDatabase> databaseWithXtream() async {
    final database = await memoryDatabase();
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

  /// Preferencias tal cual están en disco, para comparar antes y después.
  Future<Map<String, Object?>> prefSnapshot() async {
    final prefs = await SharedPreferences.getInstance();
    return {for (final key in prefs.getKeys()) key: prefs.get(key)};
  }

  test('las cuatro familias quedan en el almacén y fuera de preferencias',
      () async {
    SharedPreferences.setMockInitialValues({
      'shows_trakt_client_id': 'trakt-legacy',
      'shows_tmdb_api_key': 'tmdb-legacy',
      'shows_debrid_configs': jsonEncode({
        'version': 2,
        'services': [
          {'type': 'allDebrid', 'token': 'ad-token', 'enabled': true},
          {'type': 'realDebrid', 'token': 'rd-token', 'enabled': true},
        ],
      }),
      'lg_webos_key_192.168.1.20': 'tv-key',
      'shows_favorites': '["tt1"]',
    });
    final store = MemorySecretStore();
    final database = await databaseWithXtream();
    addTearDown(database.close);

    final container = await boot(store: store, database: database);
    addTearDown(container.dispose);

    final prefs = await prefSnapshot();
    expect(prefs.keys, isNot(contains('shows_trakt_client_id')));
    expect(prefs.keys, isNot(contains('shows_tmdb_api_key')));
    expect(
      prefs.keys.where((key) => key.startsWith('lg_webos_key_')),
      isEmpty,
      reason: 'la clave de la TV también se mueve',
    );
    final dump = jsonEncode(prefs);
    for (final secret in [
      'trakt-legacy',
      'tmdb-legacy',
      'ad-token',
      'rd-token',
      'tv-key',
      'xtream-pass',
    ]) {
      expect(dump, isNot(contains(secret)));
    }
    expect(prefs['shows_favorites'], '["tt1"]',
        reason: 'lo que no es secreto no se toca');
    expect(
      jsonDecode(prefs[debridConfigsKey] as String),
      {
        'version': 3,
        'services': [
          {'type': 'allDebrid', 'enabled': true},
          {'type': 'realDebrid', 'enabled': true},
        ],
      },
      reason: 'la estructura viaja sin tokens',
    );

    expect(store.values[SecretKeys.traktClientId], 'trakt-legacy');
    expect(store.values[SecretKeys.tmdbApiKey], 'tmdb-legacy');
    expect(store.values[SecretKeys.debridToken('allDebrid')], 'ad-token');
    expect(store.values[SecretKeys.debridToken('realDebrid')], 'rd-token');
    expect(store.values[SecretKeys.webosClientKey('192.168.1.20')], 'tv-key');
    expect(store.values[SecretKeys.providerPassword('xtream-1')],
        'xtream-pass');

    // Y los providers que usa la UI siguen viendo los mismos valores.
    expect(container.read(showsApiKeysProvider).traktClientId, 'trakt-legacy');
    expect(container.read(showsApiKeysProvider).tmdbApiKey, 'tmdb-legacy');
    final debrid = container.read(debridSettingsProvider);
    expect(debrid.enabledTypes, [DebridType.allDebrid, DebridType.realDebrid]);
    expect(debrid.configFor(DebridType.realDebrid)!.token, 'rd-token');

    final provider = (await database.getAllProviders()).single;
    expect(provider.password, isNull,
        reason: 'la base no conserva la contraseña en claro');
  });

  test('sin almacén seguro no se pierde ni se toca nada', () async {
    SharedPreferences.setMockInitialValues({
      'shows_trakt_client_id': 'trakt-legacy',
      'shows_debrid_configs': jsonEncode({
        'version': 2,
        'services': [
          {'type': 'allDebrid', 'token': 'ad-token', 'enabled': true},
        ],
      }),
      'lg_webos_key_10.0.0.2': 'tv-key',
    });
    final database = await databaseWithXtream();
    addTearDown(database.close);
    final before = await prefSnapshot();

    final container = await boot(
      store: const UnavailableSecretStore(),
      database: database,
    );
    addTearDown(container.dispose);

    expect(
      await prefSnapshot(),
      before,
      reason: 'mejor el formato viejo conocido que una credencial perdida',
    );

    expect(container.read(showsApiKeysProvider).traktClientId, 'trakt-legacy');
    expect(
      container
          .read(debridSettingsProvider)
          .configFor(DebridType.allDebrid)!
          .token,
      'ad-token',
    );
    expect(
      container.read(showsApiKeysProvider.notifier).storageAvailable,
      isFalse,
    );
    expect(
      container.read(debridSettingsProvider.notifier).storageAvailable,
      isFalse,
    );
    final provider = (await database.getAllProviders()).single;
    expect(provider.password, 'xtream-pass',
        reason: 'sin almacén, la contraseña se queda donde estaba');
  });

  test('arrancar dos veces no cambia nada', () async {
    SharedPreferences.setMockInitialValues({
      'shows_trakt_client_id': 'trakt-legacy',
      'shows_debrid_configs': jsonEncode({
        'version': 2,
        'services': [
          {'type': 'realDebrid', 'token': 'rd-token', 'enabled': true},
        ],
      }),
      'lg_webos_key_10.0.0.2': 'tv-key',
    });
    final store = MemorySecretStore();
    final database = await databaseWithXtream();
    addTearDown(database.close);

    final first = await boot(store: store, database: database);
    addTearDown(first.dispose);
    final afterFirstRun = await prefSnapshot();
    final storeAfterFirstRun = Map<String, String>.from(store.values);

    final second = await boot(store: store, database: database);
    addTearDown(second.dispose);

    expect(await prefSnapshot(), afterFirstRun);
    expect(store.values, storeAfterFirstRun);
    expect(second.read(debridSettingsProvider).enabledTypes,
        [DebridType.realDebrid]);
    expect(second.read(showsApiKeysProvider).traktClientId, 'trakt-legacy');
  });

  test('una instalación nueva no escribe ni una preferencia', () async {
    SharedPreferences.setMockInitialValues({});
    final store = MemorySecretStore();
    final database = await memoryDatabase();
    addTearDown(database.close);

    final container = await boot(store: store, database: database);
    addTearDown(container.dispose);

    expect(await prefSnapshot(), isEmpty);
    expect(store.values, isEmpty);
  });

  for (final (name, seed, type, token) in [
    (
      'documento v2',
      {
        'shows_debrid_configs': jsonEncode({
          'version': 2,
          'services': [
            {'type': 'allDebrid', 'token': 'ad-token', 'enabled': true},
          ],
        }),
      },
      DebridType.allDebrid,
      'ad-token',
    ),
    (
      'mapa tipo→token',
      {
        'shows_debrid_tokens':
            jsonEncode({'allDebrid': 'ad-token', 'realDebrid': 'rd-token'}),
      },
      DebridType.realDebrid,
      'rd-token',
    ),
    (
      'token único',
      {
        'shows_debrid_api_token': 'single-token',
        'shows_debrid_type': 'realDebrid',
      },
      DebridType.realDebrid,
      'single-token',
    ),
  ]) {
    test('debrid migra también el formato $name', () async {
      SharedPreferences.setMockInitialValues(seed);
      final store = MemorySecretStore();
      final database = await memoryDatabase();
      addTearDown(database.close);

      final container = await boot(store: store, database: database);
      addTearDown(container.dispose);

      expect(
        container.read(debridSettingsProvider).configFor(type)!.token,
        token,
      );
      expect(store.values[SecretKeys.debridToken(type.name)], token);
      final prefs = await prefSnapshot();
      expect(prefs.keys, isNot(contains('shows_debrid_tokens')));
      expect(prefs.keys, isNot(contains('shows_debrid_api_token')));
      expect(prefs.keys, isNot(contains('shows_debrid_type')));
      expect(prefs[debridConfigsKey], isNot(contains('token')));
    });
  }

  test('un mapa viejo que quedó tras migrar no sobrevive con tokens', () async {
    SharedPreferences.setMockInitialValues({
      debridConfigsKey: jsonEncode({
        'version': 3,
        'services': [
          {'type': 'realDebrid', 'enabled': true},
        ],
      }),
      'shows_debrid_tokens': jsonEncode({'realDebrid': 'rd-token'}),
    });
    final store = MemorySecretStore()
      ..values[SecretKeys.debridToken('realDebrid')] = 'rd-token';
    final database = await memoryDatabase();
    addTearDown(database.close);

    final container = await boot(store: store, database: database);
    addTearDown(container.dispose);

    final prefs = await prefSnapshot();
    expect(prefs.keys, isNot(contains('shows_debrid_tokens')));
    expect(
      container.read(debridSettingsProvider).configFor(DebridType.realDebrid)!
          .token,
      'rd-token',
    );
  });

  test('un token del mapa que no está configurado no se borra', () async {
    SharedPreferences.setMockInitialValues({
      debridConfigsKey: jsonEncode({
        'version': 3,
        'services': [
          {'type': 'realDebrid', 'enabled': true},
        ],
      }),
      'shows_debrid_tokens': jsonEncode({
        'realDebrid': 'rd-token',
        'allDebrid': 'unused-token',
      }),
    });
    final store = MemorySecretStore()
      ..values[SecretKeys.debridToken('realDebrid')] = 'rd-token';
    final database = await memoryDatabase();
    addTearDown(database.close);

    final container = await boot(store: store, database: database);
    addTearDown(container.dispose);

    expect(
      (await prefSnapshot()).keys,
      contains('shows_debrid_tokens'),
      reason: 'puede ser la única copia de esa credencial',
    );
  });

  test('todas las TV emparejadas se migran y el resto no se toca', () async {
    SharedPreferences.setMockInitialValues({
      'lg_webos_key_10.0.0.2': 'tv-a',
      'lg_webos_key_10.0.0.3': 'tv-b',
      'last_group': 'News',
    });
    final store = MemorySecretStore();
    final database = await memoryDatabase();
    addTearDown(database.close);

    final container = await boot(store: store, database: database);
    addTearDown(container.dispose);

    expect(store.values[SecretKeys.webosClientKey('10.0.0.2')], 'tv-a');
    expect(store.values[SecretKeys.webosClientKey('10.0.0.3')], 'tv-b');
    expect((await prefSnapshot()).keys.toList(), ['last_group']);
  });

  test('una clave legada vacía no se queda como rastro', () async {
    SharedPreferences.setMockInitialValues({'shows_tmdb_api_key': ''});
    final store = MemorySecretStore();
    final database = await memoryDatabase();
    addTearDown(database.close);

    final container = await boot(store: store, database: database);
    addTearDown(container.dispose);

    expect(await prefSnapshot(), isEmpty);
    expect(store.values, isEmpty);
  });
}
