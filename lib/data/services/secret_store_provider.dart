import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'secret_store.dart';

/// El almacén que usa toda la app.
///
/// Existe para que producción use el nativo y los tests inyecten un doble sin
/// tocar cada notifier, y para que el arranque y la UI compartan instancia.
final secretStoreProvider = Provider<SecretStore>(
  (ref) => SecureSecretStore(),
);
