import 'package:equatable/equatable.dart';

/// Qué clase de vídeo promocional es, de más a menos relevante.
enum VideoKind { trailer, teaser, clip, featurette, other }

/// Un vídeo promocional de un título (tráiler, teaser, clip o featurette).
///
/// Nace en dos sitios y se comporta igual en los dos: TMDB entrega la lista
/// completa en `videos` y Trakt anota un único tráiler. La app sólo sabe
/// reproducir YouTube dentro de sí misma, así que [isPlayableInApp] decide si
/// el botón abre el reproductor de la app o el navegador.
class MediaVideo extends Equatable {
  /// Sitio de origen tal y como lo publica TMDB (`YouTube`).
  final String site;

  /// Id del vídeo en YouTube. Vacío cuando el vídeo no es de YouTube.
  final String key;

  /// Nombre que da la fuente (`Official Trailer`, `Teaser`…).
  final String name;

  final VideoKind kind;

  /// TMDB marca los tráilers publicados por el estudio.
  final bool official;

  /// Código ISO 639-1 del idioma del vídeo (`es`, `en`…), si la fuente lo dice.
  final String? language;

  final DateTime? publishedAt;

  /// URL completa para los vídeos que no son de YouTube (tráiler de Trakt).
  final String? externalUrl;

  const MediaVideo({
    required this.name,
    this.site = 'YouTube',
    this.key = '',
    this.kind = VideoKind.other,
    this.official = false,
    this.language,
    this.publishedAt,
    this.externalUrl,
  });

  /// `/videos` de TMDB: `{results: [{site, key, name, type, official, ...}]}`.
  ///
  /// Sólo se conservan los vídeos de YouTube: son los únicos que la app puede
  /// abrir en su reproductor, y mezclar otros dejaría botones que no hacen nada.
  static List<MediaVideo> listFromTmdb(
    Map<String, dynamic>? videos, {
    String? preferredLanguage,
  }) {
    final results = videos?['results'];
    if (results is! List) return const [];

    final parsed = <MediaVideo>[];
    for (final raw in results) {
      if (raw is! Map) continue;
      final site = raw['site'] as String? ?? '';
      final key = raw['key'] as String? ?? '';
      if (site.toLowerCase() != 'youtube' || key.isEmpty) continue;

      parsed.add(
        MediaVideo(
          site: site,
          key: key,
          name: raw['name'] as String? ?? '',
          kind: kindFromTmdbType(raw['type'] as String?),
          official: raw['official'] == true,
          language: _nonEmpty(raw['iso_639_1'] as String?),
          publishedAt: DateTime.tryParse(raw['published_at'] as String? ?? ''),
        ),
      );
    }
    return orderVideos(parsed, preferredLanguage: preferredLanguage);
  }

  /// Tráiler anotado por Trakt: una clave de YouTube o, a veces, una URL.
  factory MediaVideo.fromTrakt(String raw) {
    final value = raw.trim();
    final key = youTubeId(value);
    if (key != null) {
      return MediaVideo(name: 'Trailer', key: key, kind: VideoKind.trailer);
    }
    return MediaVideo(
      name: 'Trailer',
      site: '',
      kind: VideoKind.trailer,
      externalUrl: value.isEmpty ? null : value,
    );
  }

  static VideoKind kindFromTmdbType(String? type) {
    switch ((type ?? '').toLowerCase()) {
      case 'trailer':
        return VideoKind.trailer;
      case 'teaser':
        return VideoKind.teaser;
      case 'clip':
        return VideoKind.clip;
      case 'featurette':
        return VideoKind.featurette;
      default:
        return VideoKind.other;
    }
  }

  /// Etiqueta corta para la ficha: distingue el tráiler del estudio del resto.
  String get kindLabel {
    switch (kind) {
      case VideoKind.trailer:
        return official ? 'Tráiler oficial' : 'Tráiler';
      case VideoKind.teaser:
        return 'Teaser';
      case VideoKind.clip:
        return 'Clip';
      case VideoKind.featurette:
        return 'Making of';
      case VideoKind.other:
        return 'Vídeo';
    }
  }

  /// Título visible: el de la fuente si aporta algo, y si no la clase de vídeo.
  String get displayName {
    final cleaned = name.trim();
    if (cleaned.isEmpty || cleaned.toLowerCase() == 'trailer') return kindLabel;
    return cleaned;
  }

  /// Idioma en mayúsculas para el distintivo de la ficha (`ES`, `EN`…).
  String? get languageBadge {
    final code = language?.trim();
    if (code == null || code.isEmpty) return null;
    return code.toUpperCase();
  }

  bool get isYouTube => site.toLowerCase() == 'youtube' && key.isNotEmpty;

  /// Sólo YouTube se puede resolver y reproducir con el motor de la app.
  bool get isPlayableInApp => isYouTube;

  String get watchUrl =>
      isYouTube ? 'https://www.youtube.com/watch?v=$key' : (externalUrl ?? '');

  /// Miniatura de YouTube en 16:9; vacía si no es de YouTube.
  String get thumbnailUrl =>
      isYouTube ? 'https://i.ytimg.com/vi/$key/mqdefault.jpg' : '';

  /// Extrae el id de un vídeo de YouTube de una clave suelta o de una URL
  /// (`watch?v=`, `youtu.be/`, `embed/`). Null si no hay nada reconocible.
  static String? youTubeId(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;
    if (RegExp(r'^[A-Za-z0-9_-]{6,20}$').hasMatch(value)) return value;
    final match = RegExp(
      r'(?:v=|youtu\.be/|embed/|shorts/)([A-Za-z0-9_-]{6,20})',
    ).firstMatch(value);
    return match?.group(1);
  }

  static String? _nonEmpty(String? value) =>
      (value == null || value.trim().isEmpty) ? null : value.trim();

  @override
  List<Object?> get props => [site, key, name, kind, official, externalUrl];
}

/// Ordena los vídeos por interés para el usuario: primero los tráilers (y de
/// ellos el oficial), luego teasers, clips y making-of; a igualdad de tipo, los
/// del idioma pedido y los más recientes.
List<MediaVideo> orderVideos(
  Iterable<MediaVideo> videos, {
  String? preferredLanguage,
}) {
  final ranked = videos.toList();
  final wanted = _languageCode(preferredLanguage);
  ranked.sort((a, b) {
    final byKind = _kindRank(a).compareTo(_kindRank(b));
    if (byKind != 0) return byKind;

    final byLanguage = _languageRank(
      a,
      wanted,
    ).compareTo(_languageRank(b, wanted));
    if (byLanguage != 0) return byLanguage;

    final aDate = a.publishedAt;
    final bDate = b.publishedAt;
    if (aDate != null && bDate != null) return bDate.compareTo(aDate);
    if (aDate != null) return -1;
    if (bDate != null) return 1;
    return 0;
  });
  return List<MediaVideo>.unmodifiable(ranked);
}

int _kindRank(MediaVideo video) {
  if (video.kind == VideoKind.trailer) return video.official ? 0 : 1;
  switch (video.kind) {
    case VideoKind.teaser:
      return 2;
    case VideoKind.clip:
      return 3;
    case VideoKind.featurette:
      return 4;
    case VideoKind.other:
    case VideoKind.trailer:
      return 5;
  }
}

int _languageRank(MediaVideo video, String? wanted) {
  if (wanted == null) return 0;
  return _languageCode(video.language) == wanted ? 0 : 1;
}

String? _languageCode(String? value) {
  final code = value?.trim().toLowerCase();
  if (code == null || code.isEmpty) return null;
  return code.split(RegExp('[-_]')).first;
}
