import 'package:shared_preferences/shared_preferences.dart';

import 'secret_store.dart';

/// Las claves de metadatos que la app necesita.
typedef ApiKeys = ({String traktClientId, String tmdbApiKey});

/// Dueño único de las claves de Trakt y TMDB.
///
/// La primera lectura reconoce el formato legado (`shows_trakt_client_id`,
/// `shows_tmdb_api_key`), lo escribe en el almacén seguro y borra la
/// preferencia sólo cuando la escritura ha ido bien. Si el almacén no está
/// disponible, el valor se conserva donde estaba y se avisa: nunca se pierde
/// una clave por no poder cifrarla.
class ApiKeyStore {
  ApiKeyStore({SecretStore? secrets, SharedPreferences? preferences})
      : _secrets = secrets ?? SecureSecretStore(),
        _prefs = preferences;

  final SecretStore _secrets;
  SharedPreferences? _prefs;

  /// Falso cuando el almacén seguro falló: la UI lo usa para avisar.
  bool storageAvailable = true;

  Future<SharedPreferences> _preferences() async =>
      _prefs ??= await SharedPreferences.getInstance();

  Future<ApiKeys> load() async {
    final prefs = await _preferences();
    final trakt = await migratePrefSecret(
      prefs: prefs,
      store: _secrets,
      prefKey: LegacySecretPrefs.traktClientId,
      secretKey: SecretKeys.traktClientId,
    );
    final tmdb = await migratePrefSecret(
      prefs: prefs,
      store: _secrets,
      prefKey: LegacySecretPrefs.tmdbApiKey,
      secretKey: SecretKeys.tmdbApiKey,
    );
    storageAvailable = !(trakt.usedLegacy || tmdb.usedLegacy);
    return (traktClientId: trakt.value, tmdbApiKey: tmdb.value);
  }

  /// Guarda ambas claves. Vaciar una la borra del almacén.
  Future<void> save({
    required String traktClientId,
    required String tmdbApiKey,
  }) async {
    final prefs = await _preferences();
    var available = true;
    available &= await _put(
      prefs,
      LegacySecretPrefs.traktClientId,
      SecretKeys.traktClientId,
      traktClientId.trim(),
    );
    available &= await _put(
      prefs,
      LegacySecretPrefs.tmdbApiKey,
      SecretKeys.tmdbApiKey,
      tmdbApiKey.trim(),
    );
    storageAvailable = available;
  }

  Future<bool> _put(
    SharedPreferences prefs,
    String prefKey,
    String secretKey,
    String value,
  ) {
    return putSecret(
      prefs: prefs,
      store: _secrets,
      prefKey: prefKey,
      secretKey: secretKey,
      value: value,
    );
  }
}
