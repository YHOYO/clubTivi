import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Claves de SharedPreferences donde vivían los secretos antes del almacén.
/// Siguen leyéndose para migrarlas y nunca deben volver a escribirse salvo
/// que el almacén seguro no esté disponible (entonces se conservan, no se
/// pierden).
abstract final class LegacySecretPrefs {
  static const traktClientId = 'shows_trakt_client_id';
  static const tmdbApiKey = 'shows_tmdb_api_key';

  static const debridConfigs = 'shows_debrid_configs';
  static const debridTokens = 'shows_debrid_tokens';
  static const debridToken = 'shows_debrid_api_token';
  static const debridType = 'shows_debrid_type';

  static const webosPrefix = 'lg_webos_key_';
}

/// Claves del almacén seguro. Son estables: si cambian, se pierden secretos.
abstract final class SecretKeys {
  static const traktClientId = 'api.trakt_client_id';
  static const tmdbApiKey = 'api.tmdb_api_key';

  /// La clave de emparejamiento de una TV LG, por host.
  static String webosClientKey(String host) => 'lg.webos.key.$host';

  /// El token de un servicio debrid, por tipo (`DebridType.name`).
  static String debridToken(String typeName) => 'debrid.$typeName';

  /// La contraseña Xtream de un proveedor, por id.
  static String providerPassword(String providerId) =>
      'provider.$providerId.password';
}

/// El almacén seguro no está disponible en esta plataforma o instalación.
///
/// Se lanza en vez de caer a texto plano: quien migra decide conservar el
/// formato legado (sin borrar nada) y avisar.
class SecretStoreUnavailable implements Exception {
  final Object cause;

  const SecretStoreUnavailable(this.cause);

  @override
  String toString() => 'SecretStoreUnavailable($cause)';
}

/// Un almacén de secretos con la misma forma en todas las plataformas.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// `flutter_secure_storage`: Keystore en Android, Credential Manager en
/// Windows. Cualquier fallo del canal nativo se traduce a
/// [SecretStoreUnavailable].
class SecureSecretStore implements SecretStore {
  SecureSecretStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (e) {
      throw SecretStoreUnavailable(e);
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (e) {
      throw SecretStoreUnavailable(e);
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (e) {
      throw SecretStoreUnavailable(e);
    }
  }
}

/// Para tests y para plataformas sin soporte real.
class MemorySecretStore implements SecretStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// Un almacén que no funciona: para probar el camino «no perder nada».
class UnavailableSecretStore implements SecretStore {
  const UnavailableSecretStore();

  @override
  Future<String?> read(String key) async =>
      throw const SecretStoreUnavailable('sin almacén seguro');

  @override
  Future<void> write(String key, String value) async =>
      throw const SecretStoreUnavailable('sin almacén seguro');

  @override
  Future<void> delete(String key) async =>
      throw const SecretStoreUnavailable('sin almacén seguro');
}

/// Lee un secreto que hoy vive en SharedPreferences y lo migra al almacén.
///
/// Reglas, en orden:
/// 1. Si ya está en el almacén, ese valor manda y la preferencia legada se
///    borra.
/// 2. Si sólo está en la preferencia, se escribe en el almacén y, **sólo si
///    se escribió bien**, se borra la preferencia.
/// 3. Si el almacén no está disponible, se devuelve el valor legado y no se
///    toca nada: mejor texto plano conocido que una credencial perdida. Ese
///    caso se avisa por log y por [MigrationResult.usedLegacy].
Future<MigrationResult> migratePrefSecret({
  required SharedPreferences prefs,
  required SecretStore store,
  required String prefKey,
  required String secretKey,
}) async {
  final legacy = prefs.getString(prefKey);
  try {
    final stored = await store.read(secretKey);
    if (stored != null && stored.isNotEmpty) {
      if (legacy != null) await prefs.remove(prefKey);
      return MigrationResult(value: stored, migrated: legacy != null);
    }
    if (legacy == null || legacy.isEmpty) {
      // Una clave vacía no es un secreto: se retira para que las preferencias
      // no conserven rastros del formato viejo.
      if (legacy != null) await prefs.remove(prefKey);
      return const MigrationResult(value: '');
    }
    await store.write(secretKey, legacy);
    await prefs.remove(prefKey);
    return MigrationResult(value: legacy, migrated: true);
  } on SecretStoreUnavailable catch (e) {
    debugPrint(
      '[Secrets] Almacén seguro no disponible para $secretKey: $e. '
      'Se conserva el valor legado en preferencias.',
    );
    return MigrationResult(value: legacy ?? '', usedLegacy: true);
  }
}

/// Mueve al almacén todas las claves de emparejamiento de TV LG.
///
/// Las TV se emparejan una a una, así que el arranque no sabe qué hosts hay:
/// se recorre el prefijo. Idempotente: un host ya migrado no deja preferencia
/// y no se vuelve a tocar.
Future<int> migrateWebOsKeys({
  required SharedPreferences prefs,
  required SecretStore store,
}) async {
  var migrated = 0;
  final keys = prefs
      .getKeys()
      .where((key) => key.startsWith(LegacySecretPrefs.webosPrefix))
      .toList();
  for (final key in keys) {
    final host = key.substring(LegacySecretPrefs.webosPrefix.length);
    if (host.isEmpty) continue;
    final result = await migratePrefSecret(
      prefs: prefs,
      store: store,
      prefKey: key,
      secretKey: SecretKeys.webosClientKey(host),
    );
    if (result.migrated) migrated++;
  }
  return migrated;
}

/// Guarda un secreto (vacío = borrarlo) y retira la copia legada.
///
/// Devuelve false si el almacén no está disponible; en ese caso el valor se
/// conserva en preferencias para no perderlo, que es el único motivo por el
/// que un secreto sigue en texto plano.
Future<bool> putSecret({
  required SharedPreferences prefs,
  required SecretStore store,
  required String prefKey,
  required String secretKey,
  required String value,
}) async {
  try {
    if (value.isEmpty) {
      await store.delete(secretKey);
    } else {
      await store.write(secretKey, value);
    }
    await prefs.remove(prefKey);
    return true;
  } on SecretStoreUnavailable catch (e) {
    debugPrint(
      '[Secrets] No se pudo guardar $secretKey de forma segura ($e); '
      'se conserva en preferencias.',
    );
    if (value.isEmpty) {
      await prefs.remove(prefKey);
    } else {
      await prefs.setString(prefKey, value);
    }
    return false;
  }
}

/// Qué pasó al leer un secreto.
class MigrationResult {
  final String value;

  /// Se movió del formato legado al almacén en esta lectura.
  final bool migrated;

  /// El almacén no estaba disponible y se leyó del formato legado.
  final bool usedLegacy;

  const MigrationResult({
    required this.value,
    this.migrated = false,
    this.usedLegacy = false,
  });
}
