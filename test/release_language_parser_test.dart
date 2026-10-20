import 'package:clubtivi/data/models/language_preferences.dart';
import 'package:clubtivi/data/services/release_language_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final cases =
      <
        ({
          String release,
          Set<String> audio,
          Set<String> subtitles,
          String? mode,
          bool hasSubtitles,
        })
      >[
        (
          release: 'Movie.2024.1080p.WEB-DL.Latino.mkv',
          audio: {kLanguageSpanishLatin},
          subtitles: <String>{},
          mode: null,
          hasSubtitles: false,
        ),
        (
          release: 'Movie.2024.CASTELLANO.1080p.BluRay',
          audio: {kLanguageSpanish},
          subtitles: <String>{},
          mode: null,
          hasSubtitles: false,
        ),
        (
          release: 'Movie.2024.Spanish.1080p.WEB-DL',
          audio: {kLanguageSpanish},
          subtitles: <String>{},
          mode: null,
          hasSubtitles: false,
        ),
        (
          // MULTi dice que hay varias pistas, no que una sea español.
          release: 'Movie.2024.MULTI.1080p.WEB-DL',
          audio: <String>{},
          subtitles: <String>{},
          mode: 'MULTI',
          hasSubtitles: false,
        ),
        (
          release: 'Movie.2024.DUAL.1080p.WEB-DL',
          audio: <String>{},
          subtitles: <String>{},
          mode: 'DUAL',
          hasSubtitles: false,
        ),
        (
          release: 'Movie.2024.VOSE.1080p',
          audio: <String>{},
          subtitles: {kLanguageSpanish},
          mode: null,
          hasSubtitles: true,
        ),
        (
          release: 'Movie.2024.VOSTFR.1080p',
          audio: <String>{},
          subtitles: {'fr'},
          mode: null,
          hasSubtitles: true,
        ),
        (
          release: 'Movie.2024.English.1080p',
          audio: {kLanguageEnglish},
          subtitles: <String>{},
          mode: null,
          hasSubtitles: false,
        ),
        (
          release: 'Serie.S01E02.ESPANOL.LATINO.SUBTITULADO',
          audio: {kLanguageSpanishLatin},
          subtitles: {kLanguageSpanish},
          mode: null,
          hasSubtitles: true,
        ),
        (
          release: 'Movie.2024.1080p.WEB-DL.DDP5.1.H.264-GROUP',
          audio: <String>{},
          subtitles: <String>{},
          mode: null,
          hasSubtitles: false,
        ),
        (
          // Forma real de Torrentio: los idiomas viajan como banderas.
          release:
              'Big Buck Bunny 3D [2008 BDRemux 1080p]\n👤 3 💾 2.32 GB 🇬🇧 / 🇷🇺',
          audio: {kLanguageEnglish, 'ru'},
          subtitles: <String>{},
          mode: null,
          hasSubtitles: false,
        ),
        (
          release: 'Película 1080p WEB-DL 🇲🇽',
          audio: {kLanguageSpanishLatin},
          subtitles: <String>{},
          mode: null,
          hasSubtitles: false,
        ),
        (
          // Fila 9 real de Torrentio para MobLand S01E01: MULTi con banderas
          // inglesa y polaca. No hay español.
          release:
              'Torrentio\n4k DV | HDR10+ | HDR\n'
              'MobLand.S01.MULTi.2160p.WEB-DL.DV.HDR.H265.DDP5.1-K83\n'
              '👤 5 💾 6.21 GB ⚙️ EXT\nMulti Audio / 🇬🇧 / 🇵🇱',
          audio: {kLanguageEnglish, 'pl'},
          subtitles: <String>{},
          mode: 'MULTI',
          hasSubtitles: false,
        ),
        (
          // Fila 24 real: DUAL con banderas inglesa y portuguesa. Tampoco hay
          // español.
          release:
              'Torrentio\n1080p\n'
              'MobLand.S01E01-02-03.1080p.WEB-DL.DUAL.5.1\n'
              '👤 65 💾 1.11 GB ⚙️ Comando\nDual Audio / 🇬🇧 / 🇵🇹',
          audio: {kLanguageEnglish, 'pt'},
          subtitles: <String>{},
          mode: 'DUAL',
          hasSubtitles: false,
        ),
        (
          // Fila 30 real: la única Castellano de las tres que se ven.
          release:
              'Torrentio\n1080p\n'
              '(2025-05) MobLand (Tierra de Mafiosos) - Temporada 1\n'
              'MobLand (Tierra de Mafiosos) 1x01(Castellano.1080p.x264.AC3.by.Ercius).mkv\n'
              '👤 26 💾 1.37 GB ⚙️ EXT\n🇪🇸',
          audio: {kLanguageSpanish},
          subtitles: <String>{},
          mode: null,
          hasSubtitles: false,
        ),
        (
          // `Sub (Rus Eng)` no son subtítulos españoles.
          release:
              'Гангстерленд / MobLand / Сезон 1\n'
              'MobLand.S01E01.1080p.WEB-DL\n👤 238 💾 5.6 GB\n'
              'Sub (Rus Eng) 🇬🇧 / 🇷🇺',
          audio: {kLanguageEnglish, 'ru'},
          subtitles: {'ru', kLanguageEnglish},
          mode: null,
          hasSubtitles: true,
        ),
        (
          // `Subs Español` describe subtítulos aunque la bandera 🇪🇸 acompañe:
          // la bandera no debe convertirse en audio español.
          release: 'Movie.2024.1080p.WEB-DL.Subs.Español 🇪🇸',
          audio: <String>{},
          subtitles: {kLanguageSpanish},
          mode: null,
          hasSubtitles: true,
        ),
        (
          // `en` en «Subtitulado en Español» es una preposición, no inglés.
          release: 'Movie.2024.1080p.Subtitulado.en.Español',
          audio: <String>{},
          subtitles: {kLanguageSpanish},
          mode: null,
          hasSubtitles: true,
        ),
        (
          // También se reconoce `Spanish` dentro de un marcador de subtítulos.
          release: 'Movie.2024.1080p.WEB-DL.Subs.Spanish',
          audio: <String>{},
          subtitles: {kLanguageSpanish},
          mode: null,
          hasSubtitles: true,
        ),
        (
          // Igual con subtítulos latinos, que también cuentan para el filtro.
          release: 'Movie.2024.1080p.WEB-DL.Subs.Latino 🇲🇽',
          audio: <String>{},
          subtitles: {kLanguageSpanishLatin},
          mode: null,
          hasSubtitles: true,
        ),
        (
          // Un audio español explícito no se pierde porque además haya subtítulos.
          release: 'Movie.2024.ESPANOL.1080p.SUBTITULADO',
          audio: {kLanguageSpanish},
          subtitles: {kLanguageSpanish},
          mode: null,
          hasSubtitles: true,
        ),
        (
          // Comet: la bandera española acompaña a `Subtitulado`, así que es
          // subtítulo, no una pista de audio.
          release:
              'MobLand.S01E01.HDTV.Subtitulado.Esp.SC.mp4\n'
              '⭐ HDTV\n💾 611.0 MB 🔎 StremThru\n🇪🇸',
          audio: <String>{},
          subtitles: {kLanguageSpanish},
          mode: null,
          hasSubtitles: true,
        ),
        (
          // Anime real (AnimES/AnimeAV1): japonés + subtítulos españoles.
          release:
              'AnimeAV1\nMP4Upload\n'
              'Jujutsu Kaisen Ep. 1\n⚙️ MP4Upload\n🇯🇵🇪🇸',
          audio: {'ja'},
          subtitles: {kLanguageSpanish},
          mode: null,
          hasSubtitles: true,
        ),
        (
          // Anime real con DUB latino explícito: aquí la bandera sí es audio.
          release:
              'AnimeAV1\nMP4Upload\n🗣️🎙️(🇲🇽DUB)\n'
              'Jujutsu Kaisen Ep. 1',
          audio: {kLanguageSpanishLatin},
          subtitles: <String>{},
          mode: null,
          hasSubtitles: false,
        ),
      ];

  for (final testCase in cases) {
    test('parsea ${testCase.release.split('\n').last}', () {
      final parsed = ReleaseLanguageParser.parse(testCase.release);

      expect(parsed.audio, testCase.audio);
      expect(parsed.subtitles, testCase.subtitles);
      expect(parsed.audioMode, testCase.mode);
      expect(parsed.hasSubtitles, testCase.hasSubtitles);
    });
  }

  test('un SUB suelto no inventa el idioma', () {
    final parsed = ReleaseLanguageParser.parse('Movie.2024.1080p.SUB');

    expect(parsed.subtitles, isEmpty);
    expect(parsed.hasSubtitles, isTrue);
  });
}
