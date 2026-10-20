import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Espera el valor de un [FutureProvider] dejando una suscripción abierta
/// mientras se resuelve.
///
/// Leer sólo `provider.future` no basta en la app real: sin ningún oyente el
/// elemento del provider se descarta antes de completar y el future se queda
/// pendiente para siempre. Con eso, pulsar Play resolvía las fuentes (los
/// addons sí respondían) pero el selector no llegaba a abrirse nunca; el
/// usuario sólo veía «Finding stream...». Suscribirse y cerrar al terminar
/// mantiene el provider vivo justo lo que dura la espera.
Future<T> awaitProviderFuture<T>(
  WidgetRef ref,
  FutureProvider<T> provider,
) async {
  final subscription = ref.listenManual(provider, (_, _) {});
  try {
    return await ref.read(provider.future);
  } finally {
    subscription.close();
  }
}
