import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'app/app.dart';
import 'app/secrets_bootstrap.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  // Las credenciales legadas se migran antes de que la UI lea ninguna: el
  // contenedor es el mismo que usa la app, así que los notifiers comparten
  // estado en vez de volver a leer preferencias.
  final container = ProviderContainer();
  await bootstrapSecrets(container);

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const ClubTiviApp(),
    ),
  );
}
