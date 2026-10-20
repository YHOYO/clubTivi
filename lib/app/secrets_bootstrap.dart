import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/services/debrid_settings.dart';
import '../data/services/secret_store.dart';
import '../data/services/secret_store_provider.dart';
import '../features/providers/provider_manager.dart';
import '../features/shows/shows_providers.dart';

/// Mueve al almacén seguro todas las credenciales del formato legado.
///
/// `main` la espera antes de `runApp`, así que ningún provider puede leer
/// preferencias antes de que la migración termine: no hay carrera entre las
/// pantallas que arrancan y la primera lectura de cada secreto. Es
/// idempotente: con todo ya migrado no escribe nada, y si el almacén no está
/// disponible conserva el legado tal cual (cada lector lo seguirá usando y la
/// UI avisa), en vez de borrar una credencial que no ha podido cifrar.
Future<void> bootstrapSecrets(ProviderContainer container) async {
  final prefs = await SharedPreferences.getInstance();
  final store = container.read(secretStoreProvider);

  // Trakt y TMDB.
  await container.read(showsApiKeysProvider.notifier).load();

  // Debrid: documento v2 con tokens, mapa tipo→token y token único.
  await container.read(debridSettingsProvider.notifier).load();

  // Claves de emparejamiento de TV LG, host a host.
  await migrateWebOsKeys(prefs: prefs, store: store);

  // Contraseñas Xtream que quedaron en la base.
  try {
    await container.read(providerManagerProvider).migrateProviderPasswords();
  } catch (e) {
    // Un fallo aquí (base bloqueada, disco lleno) no puede impedir abrir la
    // app: el refresco de cada proveedor reintenta su propia migración.
    debugPrint('[Secrets] No se pudieron migrar las contraseñas Xtream: $e');
  }
}
