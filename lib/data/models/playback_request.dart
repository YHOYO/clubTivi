/// Identidad de lo que el reproductor está reproduciendo.
///
/// Al reproductor sólo le llega una URL ya resuelta, y con ella se pierde el
/// título, el episodio y la fuente elegida. Este objeto viaja junto a esa URL
/// en el `extra` de `/player` para que un progreso se pueda guardar contra algo
/// estable: la URL de un debrid caduca, el `mediaKey` no.
///
/// Lógica pura: sin Flutter, sin red y sin almacenamiento.
library;

import 'package:equatable/equatable.dart';

import 'show.dart';
import 'stremio_addon.dart';

/// Película o serie: lo que decide si hay temporada y episodio que guardar.
enum PlaybackKind { movie, series }

/// Qué se está reproduciendo, de qué capítulo y con qué release.
class PlaybackRequest extends Equatable {
  final PlaybackKind kind;

  /// Identidad estable del título, independiente de la fuente y del enlace.
  ///
  /// Lleva prefijo de origen (`imdb:`, `tmdb:`, `trakt:`, `stremio:`, `title:`)
  /// para que dos catálogos distintos no compartan clave por accidente. La
  /// misma película abierta desde la ficha de Trakt y desde un catálogo de
  /// addon coincide en `imdb:` cuando ambas conocen el id.
  final String mediaKey;

  /// Temporada y episodio; null en una película y en una serie reproducida
  /// sin un capítulo concreto.
  final int? season;
  final int? episode;

  /// Título visible en el reproductor (el mismo que ya viaja como
  /// `channelName`).
  final String title;

  /// `StreamSource.id` del release elegido en el selector.
  final String sourceId;

  const PlaybackRequest({
    required this.kind,
    required this.mediaKey,
    required this.title,
    required this.sourceId,
    this.season,
    this.episode,
  });

  /// Identidad de una ficha de Trakt/TMDB. [episode] null al reproducir una
  /// película o la serie sin capítulo elegido.
  factory PlaybackRequest.forShow({
    required Show show,
    Episode? episode,
    required String title,
    required String sourceId,
  }) {
    return PlaybackRequest(
      kind: episode != null || show.type == ShowType.show
          ? PlaybackKind.series
          : PlaybackKind.movie,
      mediaKey: mediaKeyForShow(show),
      season: episode?.season,
      episode: episode?.number,
      title: title,
      sourceId: sourceId,
    );
  }

  /// Identidad de una ficha de addon. [video] null cuando el addon reproduce el
  /// título sin episodio (el botón Play de un catálogo de películas).
  factory PlaybackRequest.forStremio({
    required StremioMeta meta,
    StremioVideo? video,
    required String title,
    required String sourceId,
  }) {
    return PlaybackRequest(
      kind: video != null || meta.isSeries
          ? PlaybackKind.series
          : PlaybackKind.movie,
      mediaKey: mediaKeyForStremio(meta),
      season: video?.season,
      episode: video?.episode,
      title: title,
      sourceId: sourceId,
    );
  }

  bool get isEpisode => season != null && episode != null;

  /// Clave de lo que se reproduce, temporada y episodio incluidos: la fila de
  /// progreso de S01E02 no es la de S01E03 de la misma serie.
  String get contentKey =>
      isEpisode ? '$mediaKey:s${season}e$episode' : mediaKey;

  @override
  List<Object?> get props => [
    kind,
    mediaKey,
    season,
    episode,
    title,
    sourceId,
  ];

  @override
  String toString() =>
      'PlaybackRequest(${kind.name}, $contentKey, "$title", $sourceId)';
}

/// Identidad de una ficha de Trakt/TMDB, sin construir la petición entera.
///
/// Prefiere el id más compartido entre catálogos: IMDB lo conocen tanto Trakt
/// como la mayoría de addons. Sin él, el id propio de cada origen sigue
/// distinguiendo dos títulos con el mismo nombre.
String mediaKeyForShow(Show show) {
  final imdb = _nonEmpty(show.imdbId);
  if (imdb != null) return 'imdb:$imdb';
  final tmdb = show.tmdbId;
  if (tmdb != null && tmdb > 0) return 'tmdb:$tmdb';
  if (show.traktId > 0) return 'trakt:${show.traktId}';
  // Sin ningún id sólo quedan el título y el año; una ficha sin id no debe
  // heredar la clave de otra película homónima de otro año.
  return 'title:${show.title.trim().toLowerCase()}:${show.year ?? 'na'}';
}

final _imdbPattern = RegExp(r'^tt\d+$');

/// Identidad de una ficha de addon, sin construir la petición entera.

String mediaKeyForStremio(StremioMeta meta) {
  final id = meta.id.trim();
  // Un addon de IMDB usa el propio id como id del título; la ficha ya lo trata
  // así al pedir fuentes, y la clave tiene que coincidir con la de Trakt.
  final imdb = _nonEmpty(meta.imdbId) ??
      (_imdbPattern.hasMatch(id.toLowerCase()) ? id.toLowerCase() : null);
  if (imdb != null) return 'imdb:$imdb';
  // El id del addon es estable para ese addon aunque no sea un IMDB id.
  return 'stremio:${meta.type.toLowerCase()}:$id';
}

/// Un `imdbId` vacío o en blanco no puede contar como identidad: sería una
/// clave compartida por todos los títulos sin IMDB.
String? _nonEmpty(String? value) {
  final trimmed = value?.trim().toLowerCase();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}
