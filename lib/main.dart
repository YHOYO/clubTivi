import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'app/app.dart';
import 'app/secrets_bootstrap.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  // La migración de credenciales corre en segundo plano: el primer frame no la
  // espera. Los lectores de secretos esperan la misma puerta
  // (`secretsReadyProvider`), así que ninguno lee el formato legado a medias.
  final container = createAppContainer();

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const ClubTiviApp(),
    ),
  );
}
