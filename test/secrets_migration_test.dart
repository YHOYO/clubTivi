// Contrato de secretos: lo que hoy vive en SharedPreferences o en una columna
// de la base se mueve al almacén seguro en la primera lectura, sin perder
// nada si el almacén falla, y el backup exporta la configuración sin
// credenciales.
import 'dart:convert';

import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/api_key_store.dart';
import 'package:clubtivi/data/services/backup_service.dart';
import 'package:clubtivi/data/services/secret_store.dart';
import 'package:clubtivi/features/providers/provider_manager.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('claves de Trakt y TMDB', () {
    test('se migran al almacén y desaparecen de preferencias', () async {
      SharedPreferences.setMockInitialValues({
        LegacySecretPrefs.traktClientId: 'trakt-id',
        LegacySecretPrefs.tmdbApiKey: 'tmdb-key',
      });
      final store = MemorySecretStore();

      final keys = await ApiKeyStore(secrets: store).load();

      expect(keys.traktClientId, 'trakt-id');
      expect(keys.tmdbApiKey, 'tmdb-key');
      expect(store.values[SecretKeys.traktClientId], 'trakt-id');
      expect(store.values[SecretKeys.tmdbApiKey], 'tmdb-key');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(LegacySecretPrefs.traktClientId), isNull);
      expect(prefs.getString(LegacySecretPrefs.tmdbApiKey), isNull);
    });

    test('guardar escribe en el almacén y vaciar borra', () async {
      final store = MemorySecretStore();
      final prefs = await SharedPreferences.getInstance();
      final keys = ApiKeyStore(secrets: store, preferences: prefs);

      await keys.save(traktClientId: 'trakt-id', tmdbApiKey: 'tmdb-key');
      expect(store.values[SecretKeys.traktClientId], 'trakt-id');
      expect(prefs.getString(LegacySecretPrefs.traktClientId), isNull);

      // Una segunda lectura no duplica ni pierde nada.
      expect((await keys.load()).tmdbApiKey, 'tmdb-key');

      await keys.save(traktClientId: '', tmdbApiKey: 'tmdb-key');
      expect(store.values.containsKey(SecretKeys.traktClientId), isFalse);
      expect(store.values[SecretKeys.tmdbApiKey], 'tmdb-key');
    });

    test('sin almacén seguro conserva las claves y avisa', () async {
      SharedPreferences.setMockInitialValues({
        LegacySecretPrefs.traktClientId: 'trakt-id',
      });
      final store = UnavailableSecretStore();
      final keys = ApiKeyStore(secrets: store);

      final loaded = await keys.load();

      expect(loaded.traktClientId, 'trakt-id');
      expect(keys.storageAvailable, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(LegacySecretPrefs.traktClientId),
        'trakt-id',
        reason: 'no se borra lo que no se ha podido cifrar',
      );
    });
  });

  test('la clave de emparejamiento de la TV se migra al almacén', () async {
    SharedPreferences.setMockInitialValues({
      'lg_webos_key_192.168.1.20': 'tv-key',
    });
    final store = MemorySecretStore();
    final prefs = await SharedPreferences.getInstance();

    final result = await migratePrefSecret(
      prefs: prefs,
      store: store,
      prefKey: 'lg_webos_key_192.168.1.20',
      secretKey: SecretKeys.webosClientKey('192.168.1.20'),
    );

    expect(result.value, 'tv-key');
    expect(result.migrated, isTrue);
    expect(store.values[SecretKeys.webosClientKey('192.168.1.20')], 'tv-key');
    expect(prefs.getString('lg_webos_key_192.168.1.20'), isNull);
  });

  test('migrar de nuevo no duplica ni cambia el valor guardado', () async {
    SharedPreferences.setMockInitialValues({
      LegacySecretPrefs.tmdbApiKey: 'legacy',
    });
    final store = MemorySecretStore()
      ..values[SecretKeys.tmdbApiKey] = 'current';
    final prefs = await SharedPreferences.getInstance();

    final result = await migratePrefSecret(
      prefs: prefs,
      store: store,
      prefKey: LegacySecretPrefs.tmdbApiKey,
      secretKey: SecretKeys.tmdbApiKey,
    );

    expect(result.value, 'current', reason: 'el almacén manda');
    expect(prefs.getString(LegacySecretPrefs.tmdbApiKey), isNull);
  });

  test('la contraseña Xtream sale de la base y entra en el almacén', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await database.upsertProvider(db.ProvidersCompanion.insert(
      id: 'xtream-1',
      name: 'Xtream',
      type: 'xtream',
      url: const Value('http://example.com'),
      username: const Value('user'),
      password: const Value('secret-pass'),
    ));
    final store = MemorySecretStore();
    final manager = ProviderManager(database, secrets: store);

    expect(await manager.migrateProviderPasswords(), 1);

    expect(
      await store.read(SecretKeys.providerPassword('xtream-1')),
      'secret-pass',
    );
    final provider = (await database.getAllProviders()).single;
    expect(
      provider.password,
      isNull,
      reason: 'la base no puede seguir guardando la contraseña en claro',
    );

    // Idempotente: ya no queda nada que mover.
    expect(await manager.migrateProviderPasswords(), 0);
  });

  test('el backup sale sin credenciales pero con la configuración', () async {
    SharedPreferences.setMockInitialValues({
      LegacySecretPrefs.traktClientId: 'trakt-id',
      LegacySecretPrefs.tmdbApiKey: 'tmdb-key',
      'shows_debrid_configs': jsonEncode({
        'version': 2,
        'services': [
          {'type': 'allDebrid', 'token': 'ad-token', 'enabled': true},
        ],
      }),
      'lg_webos_key_192.168.1.20': 'tv-key',
      'shows_favorites': jsonEncode(['tt1']),
      'show_last_season_tt1': 3,
    });
    final prefs = await SharedPreferences.getInstance();

    final data = collectBackupPreferences(prefs);
    final dump = jsonEncode(data);

    for (final secret in [
      'trakt-id',
      'tmdb-key',
      'ad-token',
      'tv-key',
    ]) {
      expect(dump, isNot(contains(secret)));
    }
    expect(data['shows_favorites'], jsonEncode(['tt1']));
    expect(data['show_last_season_tt1'], 3);

    final debrid = jsonDecode(data['shows_debrid_configs'] as String) as Map;
    expect(
      debrid['services'],
      [
        {'type': 'allDebrid', 'enabled': true},
      ],
      reason: 'la estructura viaja para que restaurar conserve prioridad',
    );
  });
}
