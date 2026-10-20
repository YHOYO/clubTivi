// La identidad de lo que se reproduce no puede apoyarse en la URL resuelta
// (un enlace de debrid caduca) ni en el id de IMDB (no todas las fichas lo
// traen): estas pruebas fijan qué clave se guarda en cada caso.
import 'package:clubtivi/data/models/playback_request.dart';
import 'package:clubtivi/data/models/show.dart';
import 'package:clubtivi/data/models/stremio_addon.dart';
import 'package:flutter_test/flutter_test.dart';

const _movie = Show(
  traktId: 1,
  imdbId: 'tt1234567',
  title: 'Dune',
  year: 2021,
  type: ShowType.movie,
);

const _series = Show(
  traktId: 2,
  imdbId: 'tt7654321',
  title: 'Carrie',
  year: 2026,
);

const _firstEpisode = Episode(season: 1, number: 1, title: 'FIRST PERIOD');
const _secondEpisode = Episode(season: 1, number: 2, title: 'SECOND PERIOD');

const _stremioSeries = StremioMeta(
  id: 'kitsu:7442',
  type: 'series',
  name: 'Attack on Titan',
  imdbId: 'tt2560140',
  videos: [
    StremioVideo(id: 'kitsu:7442:1', season: 1, episode: 1, title: 'To You'),
    StremioVideo(id: 'kitsu:7442:2', season: 1, episode: 2, title: 'That Day'),
  ],
);

void main() {
  test('una película no arrastra temporada ni episodio', () {
    final request = PlaybackRequest.forShow(
      show: _movie,
      title: 'Dune',
      sourceId: 'torrentio:abc:0',
    );

    expect(request.kind, PlaybackKind.movie);
    expect(request.mediaKey, 'imdb:tt1234567');
    expect(request.season, isNull);
    expect(request.episode, isNull);
    expect(request.isEpisode, isFalse);
    expect(request.contentKey, 'imdb:tt1234567');
    expect(request.title, 'Dune');
    expect(request.sourceId, 'torrentio:abc:0');
  });

  test('un episodio hereda la identidad de la serie', () {
    final request = PlaybackRequest.forShow(
      show: _series,
      episode: _firstEpisode,
      title: 'Carrie S01E01',
      sourceId: 'torrentio:def:0',
    );

    expect(request.kind, PlaybackKind.series);
    expect(request.mediaKey, 'imdb:tt7654321');
    expect(request.season, 1);
    expect(request.episode, 1);
    expect(request.isEpisode, isTrue);
    expect(request.contentKey, 'imdb:tt7654321:s1e1');
  });

  test('dos episodios de la misma serie no comparten clave', () {
    final first = PlaybackRequest.forShow(
      show: _series,
      episode: _firstEpisode,
      title: 'Carrie S01E01',
      sourceId: 'torrentio:def:0',
    );
    final second = PlaybackRequest.forShow(
      show: _series,
      episode: _secondEpisode,
      title: 'Carrie S01E02',
      sourceId: 'torrentio:def:1',
    );

    expect(
      first.mediaKey,
      second.mediaKey,
      reason: 'la serie es la misma: lo distingue el episodio, no la clave',
    );
    expect(first.contentKey, isNot(second.contentKey));
    expect(first, isNot(second));
  });

  test('sin imdbId la identidad sigue siendo única y estable', () {
    const senzaImdb = Show(traktId: 77, title: 'Sin IMDB', year: 2019);
    const otraSenzaImdb = Show(traktId: 78, title: 'Sin IMDB', year: 2019);

    final request = PlaybackRequest.forShow(
      show: senzaImdb,
      title: 'Sin IMDB',
      sourceId: 'addon:1',
    );
    final otra = PlaybackRequest.forShow(
      show: otraSenzaImdb,
      title: 'Sin IMDB',
      sourceId: 'addon:1',
    );

    expect(request.mediaKey, 'trakt:77');
    expect(
      request.mediaKey,
      isNot(otra.mediaKey),
      reason: 'dos fichas sin IMDB no pueden compartir progreso por el título',
    );
    expect(
      PlaybackRequest.forShow(
        show: senzaImdb,
        title: 'Sin IMDB',
        sourceId: 'otro:2',
      ).mediaKey,
      request.mediaKey,
      reason: 'el release elegido no cambia la identidad del título',
    );
  });

  test('un imdbId en blanco no se convierte en clave compartida', () {
    const vacio = Show(
      traktId: 90,
      imdbId: '  ',
      tmdbId: 4242,
      title: 'Vacío',
    );

    expect(
      PlaybackRequest.forShow(
        show: vacio,
        title: 'Vacío',
        sourceId: 'addon:1',
      ).mediaKey,
      'tmdb:4242',
    );
  });

  test('el id de IMDB se normaliza para no duplicar la misma película', () {
    const griton = Show(traktId: 1, imdbId: ' TT1234567 ', title: 'Dune');

    expect(
      PlaybackRequest.forShow(
        show: griton,
        title: 'Dune',
        sourceId: 'addon:1',
      ).mediaKey,
      'imdb:tt1234567',
    );
  });

  test('la ficha de un addon coincide con la de Trakt cuando hay IMDB', () {
    final fromStremio = PlaybackRequest.forStremio(
      meta: _stremioSeries,
      video: _stremioSeries.videos.first,
      title: 'Attack on Titan S01E01',
      sourceId: 'kitsu:url:0',
    );

    expect(fromStremio.kind, PlaybackKind.series);
    expect(fromStremio.mediaKey, 'imdb:tt2560140');
    expect(fromStremio.season, 1);
    expect(fromStremio.episode, 1);
    expect(fromStremio.sourceId, 'kitsu:url:0');

    final fromTrakt = PlaybackRequest.forShow(
      show: const Show(traktId: 9, imdbId: 'tt2560140', title: 'Attack on Titan'),
      episode: _firstEpisode,
      title: 'Attack on Titan S01E01',
      sourceId: 'autre:0',
    );
    expect(
      fromTrakt.contentKey,
      fromStremio.contentKey,
      reason: 'el mismo episodio abierto desde otro catálogo debe reanudar igual',
    );
  });

  test('sin IMDB la ficha del addon conserva su propio id', () {
    const anime = StremioMeta(
      id: 'kitsu:7442',
      type: 'anime',
      name: 'Attack on Titan',
    );
    const otro = StremioMeta(
      id: 'kitsu:9999',
      type: 'anime',
      name: 'Attack on Titan',
    );

    final request = PlaybackRequest.forStremio(
      meta: anime,
      title: 'Attack on Titan',
      sourceId: 'addon:1',
    );

    expect(request.mediaKey, 'stremio:anime:kitsu:7442');
    expect(
      request.mediaKey,
      isNot(
        PlaybackRequest.forStremio(
          meta: otro,
          title: 'Attack on Titan',
          sourceId: 'addon:1',
        ).mediaKey,
      ),
      reason: 'un id de addon ausente no puede ser un placeholder común',
    );
  });

  test('un título de addon sin episodio se marca como película', () {
    const film = StremioMeta(id: 'tt5555555', type: 'movie', name: 'Film');

    final request = PlaybackRequest.forStremio(
      meta: film,
      title: 'Film',
      sourceId: 'addon:1',
    );

    expect(request.kind, PlaybackKind.movie);
    expect(request.isEpisode, isFalse);
    expect(request.mediaKey, 'imdb:tt5555555');
  });
}
