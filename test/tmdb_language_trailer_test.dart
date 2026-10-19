// TMDB devuelve TODOS los vídeos del título en `videos` (tráilers, teasers,
// clips) y puede hacerlo en el idioma elegido. Estas pruebas fijan las piezas
// que no dependen de la red: qué vídeos se conservan y en qué orden, cuál elige
// el botón principal, qué flujo se reproduce dentro de la app y que el idioma
// se recuerda entre sesiones.
import 'package:clubtivi/data/datasources/remote/tmdb_client.dart';
import 'package:clubtivi/data/models/media_video.dart';
import 'package:clubtivi/data/models/show.dart';
import 'package:clubtivi/data/services/trailer_stream_resolver.dart';
import 'package:clubtivi/data/services/tmdb_language_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _videos(List<Map<String, dynamic>> results) => {
  'results': results,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MediaVideo.listFromTmdb', () {
    test('conserva todos los vídeos de YouTube, no sólo un tráiler', () {
      final videos = MediaVideo.listFromTmdb(
        _videos([
          {
            'site': 'YouTube',
            'type': 'Trailer',
            'key': 'trailer1',
            'name': 'Trailer',
            'official': true,
          },
          {'site': 'YouTube', 'type': 'Teaser', 'key': 'teaser1'},
          {'site': 'YouTube', 'type': 'Clip', 'key': 'clip1'},
          {'site': 'YouTube', 'type': 'Featurette', 'key': 'making1'},
          {
            'site': 'Vimeo',
            'type': 'Trailer',
            'key': 'vimeo1',
            'name': 'Otro sitio',
          },
        ]),
      );

      expect(
        videos.map((v) => v.key),
        ['trailer1', 'teaser1', 'clip1', 'making1'],
        reason: 'los de otros sitios no se pueden reproducir dentro de la app',
      );
      expect(videos.first.kindLabel, 'Tráiler oficial');
      expect(videos[1].kindLabel, 'Teaser');
      expect(videos[3].kindLabel, 'Making of');
    });

    test('ordena por interés y luego por idioma y fecha', () {
      final videos = MediaVideo.listFromTmdb(
        _videos([
          {
            'site': 'YouTube',
            'type': 'Trailer',
            'key': 'sinOficial',
            'name': 'Trailer B',
            'published_at': '2024-01-01T00:00:00.000Z',
          },
          {
            'site': 'YouTube',
            'type': 'Trailer',
            'key': 'oficialEn',
            'name': 'Trailer A',
            'official': true,
            'iso_639_1': 'en',
          },
          {
            'site': 'YouTube',
            'type': 'Trailer',
            'key': 'oficialEs',
            'name': 'Trailer A',
            'official': true,
            'iso_639_1': 'es',
          },
        ]),
        preferredLanguage: 'es-ES',
      );

      expect(videos.map((v) => v.key), [
        'oficialEs',
        'oficialEn',
        'sinOficial',
      ], reason: 'el tráiler oficial manda, y a igualdad el del idioma pedido');
      expect(videos.first.languageBadge, 'ES');
      expect(videos[1].languageBadge, 'EN');
    });

    test('sin vídeos devuelve una lista vacía', () {
      expect(MediaVideo.listFromTmdb(null), isEmpty);
      expect(MediaVideo.listFromTmdb(_videos(const [])), isEmpty);
    });
  });

  group('MediaVideo.fromTrakt', () {
    test('acepta la clave suelta y la URL completa', () {
      expect(MediaVideo.fromTrakt('abc123').key, 'abc123');
      expect(
        MediaVideo.fromTrakt('https://www.youtube.com/watch?v=xyz789').key,
        'xyz789',
      );
      expect(
        MediaVideo.fromTrakt('https://youtu.be/qwe456').isPlayableInApp,
        isTrue,
      );
    });

    test('un tráiler que no es de YouTube se abre fuera', () {
      final video = MediaVideo.fromTrakt('https://video.test/trailer.m3u8');
      expect(video.isPlayableInApp, isFalse);
      expect(video.watchUrl, 'https://video.test/trailer.m3u8');
      expect(video.kindLabel, 'Tráiler');
    });
  });

  group('Show.promotionalVideos', () {
    test('prefiere los vídeos de TMDB', () {
      final show = Show(
        traktId: 1,
        title: 'Cars',
        trailer: 'traktKey',
        videos: const [MediaVideo(name: 'Trailer', key: 'tmdbKey')],
      );

      expect(show.promotionalVideos.single.key, 'tmdbKey');
    });

    test('sin vídeos de TMDB usa el tráiler de Trakt', () {
      final show = Show(traktId: 1, title: 'Cars', trailer: 'traktKey');
      expect(show.promotionalVideos.single.key, 'traktKey');
      expect(Show(traktId: 2, title: 'Sin nada').promotionalVideos, isEmpty);
    });
  });

  group('pickBestMuxed', () {
    MuxedCandidate candidate(int height, String container, String url) =>
        MuxedCandidate(
          height: height,
          qualityLabel: '${height}p',
          container: container,
          url: url,
        );

    test('prefiere mp4 y, dentro de él, la calidad más alta', () {
      final best = pickBestMuxed([
        candidate(0, 'webm', 'https://v.test/low.webm'),
        candidate(3, 'mp4', 'https://v.test/sd.mp4'),
        candidate(6, 'mp4', 'https://v.test/hd.mp4'),
        candidate(9, 'webm', 'https://v.test/4k.webm'),
      ]);

      expect(best!.url, 'https://v.test/hd.mp4');
    });

    test('descarta los flujos sin URL y no inventa nada', () {
      expect(pickBestMuxed([candidate(2, 'mp4', '')]), isNull);
      expect(pickBestMuxed(const []), isNull);
    });
  });

  group('muxedCandidatesFromPlayerResponse', () {
    test('se queda con vídeo que trae audio y URL directa', () {
      final candidates = muxedCandidatesFromPlayerResponse({
        'streamingData': {
          'formats': [
            {
              'itag': 18,
              'mimeType': 'video/mp4; codecs="avc1.42001E, mp4a.40.2"',
              'qualityLabel': '360p',
              'height': 360,
              'url': 'https://v.test/360.mp4',
            },
          ],
          'adaptiveFormats': [
            {
              'itag': 137,
              'mimeType': 'video/mp4; codecs="avc1.640028"',
              'qualityLabel': '1080p',
              'height': 1080,
              'url': 'https://v.test/video-only.mp4',
            },
            {
              'itag': 140,
              'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
              'url': 'https://v.test/audio.mp4',
            },
            {
              'itag': 22,
              'mimeType': 'video/mp4; codecs="avc1.64001F, mp4a.40.2"',
              'qualityLabel': '720p',
              'height': 720,
              'signatureCipher': 's=abc&url=https%3A%2F%2Fv.test%2F720.mp4',
            },
          ],
        },
      });

      expect(candidates.map((c) => c.url), ['https://v.test/360.mp4']);
      expect(candidates.single.height, 360);
      expect(candidates.single.container, 'mp4');
    });

    test('sin streamingData no hay nada que reproducir', () {
      expect(muxedCandidatesFromPlayerResponse(const {}), isEmpty);
      expect(
        muxedCandidatesFromPlayerResponse(const {
          'playabilityStatus': {'status': 'LOGIN_REQUIRED'},
        }),
        isEmpty,
      );
    });
  });

  group('TmdbShowDetail', () {
    test('lee título, sinopsis y todos los vídeos del idioma pedido', () {
      final detail = TmdbShowDetail.fromJson({
        'id': 123,
        'title': 'Cars',
        'overview': 'Un coche de carreras.',
        'release_date': '2006-06-09',
        'videos': {
          'results': [
            {
              'site': 'YouTube',
              'type': 'Trailer',
              'key': 'abc123',
              'official': true,
            },
            {'site': 'YouTube', 'type': 'Teaser', 'key': 'teaser1'},
          ],
        },
      });

      expect(detail.title, 'Cars');
      expect(detail.overview, 'Un coche de carreras.');
      expect(detail.year, 2006);
      expect(detail.videos.map((v) => v.key), ['abc123', 'teaser1']);
      expect(detail.primaryTrailer!.key, 'abc123');
    });

    test('sin vídeos la lista queda vacía', () {
      final detail = TmdbShowDetail.fromJson({'id': 1, 'name': 'Serie'});
      expect(detail.videos, isEmpty);
      expect(detail.primaryTrailer, isNull);
    });
  });

  group('idioma de metadatos', () {
    test('por defecto español y recuerda el idioma elegido', () async {
      SharedPreferences.setMockInitialValues({});
      final first = TmdbLanguageNotifier();
      await first.load();
      expect(first.state, defaultTmdbLanguage);

      await first.select('en-US');
      expect(first.state, 'en-US');

      final second = TmdbLanguageNotifier();
      await second.load();
      expect(
        second.state,
        'en-US',
        reason: 'el idioma debe sobrevivir al reinicio',
      );
    });

    test('ignora idiomas que no están en la lista', () async {
      SharedPreferences.setMockInitialValues({});
      final notifier = TmdbLanguageNotifier();
      await notifier.load();
      await notifier.select('xx-XX');
      expect(notifier.state, defaultTmdbLanguage);
      expect(tmdbLanguageFor('xx-XX').code, defaultTmdbLanguage);
    });
  });
}
