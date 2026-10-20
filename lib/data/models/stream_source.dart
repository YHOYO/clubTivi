/// Fuente de reproducción unificada.
///
/// Todo lo que puede acabar en el reproductor (debrid, addon, scraper o
/// torrent) se representa con este tipo. Es lógica pura: sin Flutter, sin red
/// y sin conocimiento de la UI.
library;

/// De dónde sale la fuente.
enum SourceKind {
  /// Enlace servido por un servicio debrid (cacheado o resuelto).
  debrid,

  /// Enlace directo devuelto por un addon.
  addon,

  /// Enlace extraído de una página por un pack de scraping.
  scraper,

  /// Torrent P2P crudo (infoHash/magnet).
  torrent,
}

/// Cómo se localiza el contenido.
enum StreamLocator {
  /// URL HTTP/HLS reproducible tal cual.
  url,

  /// Magnet completo, con trackers incluidos.
  magnet,

  /// Solo el hash; el motor P2P tendrá que resolver metadata y trackers.
  infoHash,
}

/// Referencia a un subtítulo asociado a la fuente.
class SubtitleReference {
  final String id;
  final String url;
  final String language;
  final String? label;

  const SubtitleReference({
    required this.id,
    required this.url,
    required this.language,
    this.label,
  });

  @override
  String toString() => 'SubtitleReference($id, $language)';
}

/// Candidato de reproducción con todo lo necesario para rankearlo y abrirlo.
class StreamSource {
  /// Identidad estable dentro de la lista (para desempates deterministas).
  final String id;

  /// Proveedor que lo encontró (`torrentio`, `real-debrid`, …).
  final String providerId;

  /// Addon o proveedor de origen (`Torrentio`, `Comet`, `torrent`, …).
  /// No se sustituye por el servicio debrid: la fila debe seguir diciendo de
  /// qué addon viene aunque la fuente esté cacheada.
  final String providerName;

  final SourceKind kind;

  /// Nombre del release o del archivo.
  final String title;

  /// URL directa, si la hay.
  final String? url;

  final String? infoHash;

  /// Índice del archivo dentro del torrent, cuando el addon lo conoce.
  final int? fileIdx;

  final String? magnetUrl;

  final String? quality;

  final int? sizeBytes;

  final int? seeds;

  /// Disponibilidad instantánea en el servicio debrid.
  final bool isCached;

  /// Servicio debrid que tiene la fuente cacheada, si aplica.
  final String? cachedBy;

  /// Idiomas de audio normalizados (`es-419`, `es`, `en`, …).
  final Set<String> audioLanguages;

  /// `MULTI` o `DUAL` cuando el release declara varias pistas sin decir cuáles.
  final String? audioMode;

  /// Idiomas de subtítulos disponibles en la propia fuente.
  final Set<String> subtitleLanguages;

  /// True cuando el addon anuncia subtítulos pero no su idioma.
  final bool hasSubtitles;

  /// Detalle técnico que no cabe en el badge: codec, HDR y fuente.
  final String? qualityDetail;

  /// Subtítulos externos ya referenciados por el proveedor.
  final List<SubtitleReference> subtitles;

  /// Cabeceras HTTP necesarias (Referer, User-Agent…).
  final Map<String, String> headers;

  final String? referer;

  /// True cuando la URL debe pasar por el proxy local.
  final bool needsProxy;

  /// Motivo por el que no se puede reproducir con la configuración actual.
  final String? unavailableReason;

  const StreamSource({
    required this.id,
    required this.providerId,
    required this.providerName,
    required this.kind,
    required this.title,
    this.url,
    this.infoHash,
    this.fileIdx,
    this.magnetUrl,
    this.quality,
    this.sizeBytes,
    this.seeds,
    this.isCached = false,
    this.cachedBy,
    this.audioLanguages = const {},
    this.audioMode,
    this.subtitleLanguages = const {},
    this.hasSubtitles = false,
    this.qualityDetail,
    this.subtitles = const [],
    this.headers = const {},
    this.referer,
    this.needsProxy = false,
    this.unavailableReason,
  });

  /// Forma de localizarlo, o `null` si el candidato no trae enlace.
  StreamLocator? get locator {
    if (url != null && url!.isNotEmpty) return StreamLocator.url;
    if (magnetUrl != null && magnetUrl!.isNotEmpty) return StreamLocator.magnet;
    if (infoHash != null && infoHash!.isNotEmpty) {
      return StreamLocator.infoHash;
    }
    return null;
  }

  bool get isDirect => locator == StreamLocator.url;

  /// Una URL directa siempre se puede abrir; un magnet solo si hay un
  /// resolvedor (debrid hoy, P2P más adelante) y no está marcado como no
  /// disponible.
  bool get isAvailable {
    if (isDirect) return true;
    if (locator == null) return false;
    return unavailableReason == null;
  }

  String get filesizeDisplay {
    final bytes = sizeBytes;
    if (bytes == null || bytes <= 0) return '';
    final gb = bytes / (1024 * 1024 * 1024);
    if (gb >= 1) return '${gb.toStringAsFixed(1)} GB';
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(0)} MB';
  }

  /// Primera línea del release, sin la lista de `👤/💾/⚙️` que algunos addons
  /// pegan en `title`. La fila del selector usa esto en vez del blob completo.
  String get displayName {
    for (final line in title.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return title.trim();
  }

  StreamSource copyWith({
    String? id,
    String? providerId,
    String? providerName,
    SourceKind? kind,
    String? title,
    String? url,
    String? infoHash,
    int? fileIdx,
    String? magnetUrl,
    String? quality,
    int? sizeBytes,
    int? seeds,
    bool? isCached,
    String? cachedBy,
    Set<String>? audioLanguages,
    String? audioMode,
    Set<String>? subtitleLanguages,
    bool? hasSubtitles,
    String? qualityDetail,
    List<SubtitleReference>? subtitles,
    Map<String, String>? headers,
    String? referer,
    bool? needsProxy,
    String? unavailableReason,
  }) {
    return StreamSource(
      id: id ?? this.id,
      providerId: providerId ?? this.providerId,
      providerName: providerName ?? this.providerName,
      kind: kind ?? this.kind,
      title: title ?? this.title,
      url: url ?? this.url,
      infoHash: infoHash ?? this.infoHash,
      fileIdx: fileIdx ?? this.fileIdx,
      magnetUrl: magnetUrl ?? this.magnetUrl,
      quality: quality ?? this.quality,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      seeds: seeds ?? this.seeds,
      isCached: isCached ?? this.isCached,
      cachedBy: cachedBy ?? this.cachedBy,
      audioLanguages: audioLanguages ?? this.audioLanguages,
      audioMode: audioMode ?? this.audioMode,
      subtitleLanguages: subtitleLanguages ?? this.subtitleLanguages,
      hasSubtitles: hasSubtitles ?? this.hasSubtitles,
      qualityDetail: qualityDetail ?? this.qualityDetail,
      subtitles: subtitles ?? this.subtitles,
      headers: headers ?? this.headers,
      referer: referer ?? this.referer,
      needsProxy: needsProxy ?? this.needsProxy,
      unavailableReason: unavailableReason ?? this.unavailableReason,
    );
  }

  @override
  String toString() =>
      'StreamSource($id, ${kind.name}, ${locator?.name ?? 'none'}, '
      'audio: $audioLanguages)';
}
