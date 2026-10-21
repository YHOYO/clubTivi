import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/services/debrid_settings.dart';
import '../data/services/secret_store.dart';
import '../data/services/secret_store_provider.dart';
import '../data/services/secrets_ready.dart';
import '../features/providers/provider_manager.dart';
import '../features/shows/shows_providers.dart';

/// Mueve al almacén seguro todas las credenciales del formato legado.
///
/// Es el único sitio donde corre la migración completa. Es idempotente: con
/// todo ya migrado no escribe nada, y si el almacén no está disponible
/// conserva el legado tal cual (cada lector lo seguirá usando y la UI avisa),
/// en vez de borrar una credencial que no ha podido cifrar.
///
/// Ya no bloquea el primer frame: [createAppContainer] la lanza en segundo
/// plano y los lectores esperan [secretsReadyProvider].
Future<void> bootstrapSecrets(ProviderContainer container) async {
  final store = container.read(secretStoreProvider);

  // Trakt y TMDB.
  try {
    await container.read(showsApiKeysProvider.notifier).load();
  } catch (e) {
    // Ningún secreto se pierde: la migración sólo borra la preferencia legada
    // después de escribir en el almacén, así que aquí queda el formato viejo.
    debugPrint('[Secrets] No se pudieron migrar Trakt/TMDB: $e');
  }

  // Debrid: documento v2 con tokens, mapa tipo→token y token único.
  try {
    await container.read(debridSettingsProvider.notifier).load();
  } catch (e) {
    debugPrint('[Secrets] No se pudieron migrar los servicios debrid: $e');
  }

  // Claves de emparejamiento de TV LG, host a host.
  try {
    final prefs = await SharedPreferences.getInstance();
    await migrateWebOsKeys(prefs: prefs, store: store);
  } catch (e) {
    debugPrint('[Secrets] No se pudieron migrar las claves de TV: $e');
  }

  // Contraseñas Xtream que quedaron en la base.
  try {
    await ProviderManager(
      container.read(databaseProvider),
      secrets: store,
    ).migrateProviderPasswords();
  } catch (e) {
    // Un fallo aquí (base bloqueada, disco lleno) no puede impedir abrir la
    // app: el refresco de cada proveedor reintenta su propia migración.
    debugPrint('[Secrets] No se pudieron migrar las contraseñas Xtream: $e');
  }
}

/// Crea el contenedor de la app y lanza la migración **sin** bloquear el
/// primer frame.
///
/// [secretsReadyProvider] es la única puerta que esperan los lectores de
/// secretos; se abre cuando la migración termina (o falla), nunca antes.
/// `runApp` sigue su curso mientras tanto.
///
/// [overrides] existe para que los tests inyecten base y almacén sin tocar el
/// cableado real.
ProviderContainer createAppContainer({List<Override> overrides = const []}) {
  final gate = Completer<void>();
  final container = ProviderContainer(
    overrides: [
      secretsReadyProvider.overrideWithValue(gate.future),
      ...overrides,
    ],
  );
  unawaited(
    bootstrapSecrets(container)
        .then<void>(
          (_) {},
          onError: (Object error, StackTrace stack) {
            debugPrint('[Secrets] La migración no terminó: $error');
          },
        )
        .whenComplete(() {
          if (!gate.isCompleted) gate.complete();
        }),
  );
  return container;
}
