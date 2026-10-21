import 'package:flutter_riverpod/flutter_riverpod.dart';

/// La puerta que espera todo lector de credenciales antes de leer.
///
/// `main` la sustituye por el future de la migración de arranque (ver
/// `createAppContainer`), de modo que el primer frame se pinta sin esperarla
/// pero ninguna lectura de secretos se adelanta a la migración.
///
/// Por defecto está cumplida: un contenedor de test, o cualquier entrada que
/// no arranque la app entera, no se queda esperando una migración que nadie
/// lanzó.
final secretsReadyProvider = Provider<Future<void>>(
  (ref) => Future<void>.value(),
);
