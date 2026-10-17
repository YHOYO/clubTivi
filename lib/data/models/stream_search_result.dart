/// Resultado de una búsqueda de fuentes: lo que se pudo leer y qué proveedor
/// quedó fuera, con el motivo para poder enseñarlo.
///
/// Lógica pura: sin Flutter, sin red y sin almacenamiento.
library;

import 'stream_source.dart';

/// Un proveedor (addon, scraper…) que no pudo aportar fuentes en esta
/// búsqueda. No es un fallo de la app: es información para el usuario.
class StreamProviderFailure {
  final String providerId;
  final String providerName;
  final String reason;

  const StreamProviderFailure({
    required this.providerId,
    required this.providerName,
    required this.reason,
  });

  @override
  bool operator ==(Object other) =>
      other is StreamProviderFailure &&
      other.providerId == providerId &&
      other.providerName == providerName &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(providerId, providerName, reason);

  @override
  String toString() => 'StreamProviderFailure($providerName: $reason)';
}

/// Fuentes encontradas (ya sin ordenar o ya rankeadas, según quién la use) y
/// los proveedores que quedaron fuera.
class StreamSearchResult {
  final List<StreamSource> sources;
  final List<StreamProviderFailure> failures;

  const StreamSearchResult({
    this.sources = const [],
    this.failures = const [],
  });

  bool get isEmpty => sources.isEmpty;
  bool get hasFailures => failures.isNotEmpty;

  StreamSearchResult copyWith({
    List<StreamSource>? sources,
    List<StreamProviderFailure>? failures,
  }) {
    return StreamSearchResult(
      sources: sources ?? this.sources,
      failures: failures ?? this.failures,
    );
  }

  @override
  String toString() =>
      'StreamSearchResult(${sources.length} fuentes, ${failures.length} fallos)';
}
