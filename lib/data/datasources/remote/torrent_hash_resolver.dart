import '../../models/show.dart';

/// Un servicio debrid que sabe reabrir un release por su `infoHash` y elegir
/// el fichero dentro de un pack.
///
/// Es una interfaz aparte —y no un método más de `DebridService`— para que los
/// servicios que no pueden elegir fichero (y los dobles de los tests) sigan
/// valiendo sin tocarse: quien no la implementa se queda con el magnet de toda
/// la vida.
abstract class TorrentHashResolver {
  /// Resuelve [infoHash] con el debrid.
  ///
  /// [fileIdx] es el fichero que se usó la última vez y [season]/[episode] la
  /// pista para reconocer el capítulo dentro de un pack de temporada.
  Future<ResolvedStream?> resolveTorrentHash(
    String infoHash, {
    int? fileIdx,
    int? season,
    int? episode,
    void Function(String status, int progress)? onProgress,
  });
}

/// Magnet mínimo para pedir un hash ya conocido: el debrid no necesita trackers
/// para encontrar un torrent que ya tiene, y la huella guardada no los lleva.
String magnetForTorrentHash(String infoHash) =>
    'magnet:?xt=urn:btih:${infoHash.trim()}';

/// Marca que delata un episodio en un nombre de fichero (`S01E02`), tal y como
/// lo escriben los releases. Devuelve null sin temporada o sin episodio.
String? episodeFileMarker(int? season, int? episode) {
  if (season == null || episode == null) return null;
  final s = season.toString().padLeft(2, '0');
  final e = episode.toString().padLeft(2, '0');
  return 's${s}e$e';
}

/// Nombre de fichero de un episodio concreto dentro de un pack, o null.
///
/// Los releases escriben el capítulo de dos formas: `S01E02` y `1x02` (la que
/// usan muchos packs en castellano). Se aceptan las dos.
String? findEpisodeFile(Iterable<String> names, int? season, int? episode) {
  final marker = episodeFileMarker(season, episode);
  if (marker == null) return null;
  final alt =
      '${season}x${episode.toString().padLeft(2, '0')}';
  for (final name in names) {
    final lower = name.toLowerCase();
    if (lower.contains(marker) || lower.contains(alt)) return name;
  }
  return null;
}
