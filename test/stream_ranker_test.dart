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
  String? audioMode,
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
    audioMode: audioMode,
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
        source(
          id: 'con-subs',
          audio: {kLanguageSpanishLatin},
          subs: {kLanguageSpanish},
        ),
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
    _RankCase('lista vacía devuelve lista vacía', [], defaults, []),
    _RankCase(
      'el tipo de fuente ordena tras idioma y subtítulos',
      [
        source(
          id: 'torrent',
          kind: SourceKind.torrent,
          audio: {kLanguageSpanishLatin},
        ),
        source(
          id: 'addon',
          kind: SourceKind.addon,
          audio: {kLanguageSpanishLatin},
        ),
        source(
          id: 'debrid',
          kind: SourceKind.debrid,
          audio: {kLanguageSpanishLatin},
        ),
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

  test('Solo español deja fuera MULTi/DUAL sin bandera española', () {
    final input = [
      source(id: 'multi', audio: {kLanguageEnglish, 'pl'}, audioMode: 'MULTI'),
      source(id: 'castellano', audio: {kLanguageSpanish}),
      source(id: 'vose', subs: {kLanguageSpanish}),
      source(id: 'english', audio: {kLanguageEnglish}),
      source(id: 'latino', audio: {kLanguageSpanishLatin}),
    ];

    final selected = selectStreams(
      input,
      preferences: defaults,
      spanishOnly: true,
    );

    expect(selected.map((s) => s.id), ['castellano', 'vose', 'latino']);
    expect(isSpanishSource(input.first), isFalse);
    expect(isSpanishSource(input[1]), isTrue);
    expect(
      isSpanishSource(input[2]),
      isTrue,
      reason: 'VOSE son subtítulos españoles',
    );
  });

  test('Solo español también reconoce subtítulos latinos', () {
    final input = [
      source(id: 'sub-latino', subs: {kLanguageSpanishLatin}),
      source(id: 'english', audio: {kLanguageEnglish}),
    ];

    expect(hasSpanishSubtitles(input.first), isTrue);
    final selected = selectStreams(
      input,
      preferences: defaults,
      spanishOnly: true,
    );
    expect(selected.map((s) => s.id), ['sub-latino']);
  });

  test(
    'Español primero sube audio español aunque las preferencias sean inglés',
    () {
      const englishFirst = LanguagePreferences(
        audioOrder: [kLanguageEnglish, 'fr'],
        subtitleOrder: [kLanguageEnglish],
      );
      final input = [
        source(id: 'english', audio: {kLanguageEnglish}),
        source(id: 'castellano', audio: {kLanguageSpanish}),
        source(id: 'latino', audio: {kLanguageSpanishLatin}),
        source(id: 'frances', audio: {'fr'}),
      ];

      final selected = selectStreams(
        input,
        preferences: englishFirst,
        spanishFirst: true,
      );

      expect(selected.map((s) => s.id), [
        'latino',
        'castellano',
        'english',
        'frances',
      ]);
      expect(input.map((s) => s.id), [
        'english',
        'castellano',
        'latino',
        'frances',
      ], reason: 'no muta la entrada');
    },
  );

  test(
    'las preferencias guardadas siguen mandando dentro y fuera de español',
    () {
      const englishFirst = LanguagePreferences(
        audioOrder: [kLanguageEnglish, kLanguageSpanish],
        subtitleOrder: [kLanguageEnglish],
      );

      final adjusted = spanishFirstPreferences(englishFirst);

      expect(adjusted.audioRank({kLanguageEnglish}), greaterThan(0));
      expect(
        adjusted.audioRank({kLanguageSpanish}),
        0,
        reason: 'el usuario ya prefería castellano sobre latino',
      );
      expect(adjusted.audioRank({kLanguageSpanishLatin}), 1);
      expect(adjusted.subtitleRank({kLanguageEnglish}), greaterThan(0));
      expect(adjusted.subtitleRank({kLanguageSpanish}), 0);
    },
  );

  test('Español primero conserva el orden guardado entre variantes', () {
    const custom = LanguagePreferences(
      audioOrder: [kLanguageEnglish, kLanguageSpanish, kLanguageSpanishLatin],
      subtitleOrder: [
        kLanguageEnglish,
        kLanguageSpanishLatin,
        kLanguageSpanish,
      ],
    );

    final adjusted = spanishFirstPreferences(custom);

    expect(adjusted.audioOrder, [
      kLanguageSpanish,
      kLanguageSpanishLatin,
      kLanguageEnglish,
    ]);
    expect(adjusted.subtitleOrder, [
      kLanguageSpanishLatin,
      kLanguageSpanish,
      kLanguageEnglish,
    ]);
  });

  test('es determinista y no modifica la lista de entrada', () {
    final a = source(
      id: 'b',
      title: 'Same.Release',
      audio: {kLanguageSpanishLatin},
    );
    final b = source(
      id: 'a',
      title: 'Same.Release',
      audio: {kLanguageSpanishLatin},
    );
    final input = [a, b];

    final first = rankStreams(input, defaults).map((s) => s.id).toList();
    final second = rankStreams(input, defaults).map((s) => s.id).toList();

    expect(first, ['a', 'b'], reason: 'desempate por id');
    expect(second, first);
    expect(input.map((s) => s.id).toList(), [
      'b',
      'a',
    ], reason: 'rankStreams no ordena la lista original');
  });
}
