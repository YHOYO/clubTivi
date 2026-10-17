// El ranking es lexicográfico: audio → subtítulos → caché → tipo → calidad →
// seeds → desempate. Sin Flutter, sin red y sin mutar la entrada.
import 'package:clubtivi/data/models/language_preferences.dart';
import 'package:clubtivi/data/models/stream_source.dart';
import 'package:clubtivi/data/services/stream_ranker.dart';
import 'package:flutter_test/flutter_test.dart';

StreamSource source({
  required String id,
  Set<String> audio = const {},
  Set<String> subs = const {},
  bool cached = false,
  SourceKind kind = SourceKind.torrent,
  String quality = '1080p',
  int? seeds = 10,
  String? title,
}) {
  return StreamSource(
    id: id,
    providerId: 'test',
    providerName: 'test',
    kind: kind,
    title: title ?? id,
    quality: quality,
    seeds: seeds,
    isCached: cached,
    audioLanguages: audio,
    subtitleLanguages: subs,
    magnetUrl: 'magnet:?xt=urn:btih:$id',
  );
}

class _RankCase {
  final String name;
  final List<StreamSource> input;
  final LanguagePreferences preferences;
  final List<String> expected;

  const _RankCase(this.name, this.input, this.preferences, this.expected);
}

void main() {
  final defaults = LanguagePreferences.defaults;

  final cases = <_RankCase>[
    _RankCase(
      'latino con menos seeds gana a inglés con más seeds',
      [
        source(id: 'english-500', audio: {kLanguageEnglish}, seeds: 500),
        source(id: 'latino-5', audio: {kLanguageSpanishLatin}, seeds: 5),
      ],
      defaults,
      ['latino-5', 'english-500'],
    ),
    _RankCase(
      'los subtítulos desempatan cuando el audio empata',
      [
        source(id: 'sin-subs', audio: {kLanguageSpanishLatin}),
        source(id: 'con-subs', audio: {kLanguageSpanishLatin}, subs: {kLanguageSpanish}),
      ],
      defaults,
      ['con-subs', 'sin-subs'],
    ),
    _RankCase(
      'una fuente cacheada gana a una no cacheada',
      [
        source(id: 'fria', audio: {kLanguageSpanishLatin}),
        source(id: 'cacheada', audio: {kLanguageSpanishLatin}, cached: true),
      ],
      defaults,
      ['cacheada', 'fria'],
    ),
    _RankCase(
      'preferencias personalizadas cambian el ganador',
      [
        source(id: 'latino', audio: {kLanguageSpanishLatin}),
        source(id: 'english', audio: {kLanguageEnglish}),
      ],
      const LanguagePreferences(
        audioOrder: [kLanguageEnglish, kLanguageSpanish, kLanguageSpanishLatin],
      ),
      ['english', 'latino'],
    ),
    _RankCase(
      'lista vacía devuelve lista vacía',
      [],
      defaults,
      [],
    ),
    _RankCase(
      'el tipo de fuente ordena tras idioma y subtítulos',
      [
        source(id: 'torrent', kind: SourceKind.torrent, audio: {kLanguageSpanishLatin}),
        source(id: 'addon', kind: SourceKind.addon, audio: {kLanguageSpanishLatin}),
        source(id: 'debrid', kind: SourceKind.debrid, audio: {kLanguageSpanishLatin}),
      ],
      defaults,
      ['debrid', 'addon', 'torrent'],
    ),
    _RankCase(
      'la calidad ordena después del tipo',
      [
        source(id: '720p', quality: '720p', audio: {kLanguageSpanishLatin}),
        source(id: '4k', quality: '4K', audio: {kLanguageSpanishLatin}),
        source(id: '1080p', quality: '1080p', audio: {kLanguageSpanishLatin}),
      ],
      defaults,
      ['4k', '1080p', '720p'],
    ),
    _RankCase(
      'un CAM en 4K queda por debajo de un 1080p limpio',
      [
        source(
          id: 'cam-4k',
          quality: '4K',
          title: 'Movie.2024.2160p.CAM',
          audio: {kLanguageSpanishLatin},
        ),
        source(
          id: 'web-1080p',
          quality: '1080p',
          title: 'Movie.2024.1080p.WEB-DL',
          audio: {kLanguageSpanishLatin},
        ),
      ],
      defaults,
      ['web-1080p', 'cam-4k'],
    ),
    _RankCase(
      'sin datos de idioma queda por delante de un idioma no preferido',
      [
        source(id: 'frances', audio: {'fr'}),
        source(id: 'sin-datos'),
      ],
      defaults,
      ['sin-datos', 'frances'],
    ),
    _RankCase(
      'mismo audio y calidad: más seeds primero',
      [
        source(id: 'pocas', seeds: 3, audio: {kLanguageSpanishLatin}),
        source(id: 'muchas', seeds: 90, audio: {kLanguageSpanishLatin}),
      ],
      defaults,
      ['muchas', 'pocas'],
    ),
  ];

  for (final testCase in cases) {
    test(testCase.name, () {
      final ranked = rankStreams(testCase.input, testCase.preferences);
      expect(ranked.map((s) => s.id).toList(), testCase.expected);
    });
  }

  test('es determinista y no modifica la lista de entrada', () {
    final a = source(id: 'b', title: 'Same.Release', audio: {kLanguageSpanishLatin});
    final b = source(id: 'a', title: 'Same.Release', audio: {kLanguageSpanishLatin});
    final input = [a, b];

    final first = rankStreams(input, defaults).map((s) => s.id).toList();
    final second = rankStreams(input, defaults).map((s) => s.id).toList();

    expect(first, ['a', 'b'], reason: 'desempate por id');
    expect(second, first);
    expect(input.map((s) => s.id).toList(), ['b', 'a'],
        reason: 'rankStreams no ordena la lista original');
  });
}
