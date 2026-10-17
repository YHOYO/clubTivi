// La elección de pistas es lo que hace que las preferencias de idioma sirvan de
// algo: coincide por código o por alias, no inventa donde no hay datos y nunca
// pisa una elección manual del usuario.
import 'package:clubtivi/data/models/language_preferences.dart';
import 'package:clubtivi/data/services/track_selector.dart';
import 'package:flutter_test/flutter_test.dart';

SelectableTrack _track(String id, {String? language, String? title}) =>
    SelectableTrack(id: id, language: language, title: title);

const _defaults = LanguagePreferences.defaults;

class _AudioCase {
  final String name;
  final List<SelectableTrack> tracks;
  final LanguagePreferences preferences;
  final ManualTrackChoice manual;
  final String? expected;

  const _AudioCase(
    this.name,
    this.tracks, {
    this.preferences = _defaults,
    this.manual = ManualTrackChoice.none,
    required this.expected,
  });
}

class _SubtitleCase {
  final String name;
  final List<SelectableTrack> tracks;
  final LanguagePreferences preferences;
  final ManualTrackChoice manual;
  final String? expected;

  const _SubtitleCase(
    this.name,
    this.tracks, {
    this.preferences = _defaults,
    this.manual = ManualTrackChoice.none,
    required this.expected,
  });
}

void main() {
  group('audio', () {
    final cases = <_AudioCase>[
      _AudioCase(
        'coincidencia exacta con el idioma preferido',
        [
          _track('en', language: 'en'),
          _track('lat', language: 'es-419'),
        ],
        expected: 'lat',
      ),
      _AudioCase(
        'alias: latino en el título, sin código de idioma',
        [
          _track('en', language: 'en'),
          _track('lat', title: 'Latino 5.1'),
        ],
        expected: 'lat',
      ),
      _AudioCase(
        'alias: castellano cuenta como español',
        [
          _track('eng', language: 'eng'),
          _track('esp', title: 'Castellano'),
        ],
        expected: 'esp',
      ),
      _AudioCase(
        'alias: el mismo idioma declarado como palabra',
        [
          _track('en', language: 'English'),
          _track('es', language: 'Spanish'),
        ],
        expected: 'es',
      ),
      _AudioCase(
        'el orden configurado decide entre variantes del mismo idioma',
        [
          _track('lat', language: 'es-419'),
          _track('es', language: 'es'),
        ],
        expected: 'es',
        preferences: const LanguagePreferences(
          audioOrder: [kLanguageSpanish, kLanguageSpanishLatin],
        ),
      ),
      _AudioCase(
        'falta el idioma preferido: no se toca nada',
        [
          _track('fr', language: 'fr'),
          _track('de', language: 'de'),
        ],
        expected: null,
      ),
      _AudioCase(
        'una sola pista en otro idioma: no se toca',
        [_track('fr', language: 'fr')],
        expected: null,
      ),
      _AudioCase(
        'una sola pista en el idioma pedido: se elige',
        [_track('es', language: 'es')],
        expected: 'es',
      ),
      _AudioCase(
        'sin pistas no hay nada que elegir',
        const [],
        expected: null,
      ),
      _AudioCase(
        'una pista sin idioma declarado no se inventa',
        [_track('und', language: 'und'), _track('x')],
        expected: null,
      ),
      _AudioCase(
        'la elección manual gana a las preferencias',
        [
          _track('en', language: 'en'),
          _track('es', language: 'es'),
        ],
        manual: const ManualTrackChoice(audioId: 'en'),
        expected: 'en',
      ),
      _AudioCase(
        'una elección manual que ya no existe vuelve a las preferencias',
        [
          _track('es', language: 'es'),
          _track('en', language: 'en'),
        ],
        manual: const ManualTrackChoice(audioId: 'borrada'),
        expected: 'es',
      ),
      _AudioCase(
        'sin orden configurado no se cambia ninguna pista',
        [
          _track('es', language: 'es'),
          _track('en', language: 'en'),
        ],
        preferences: const LanguagePreferences(audioOrder: []),
        expected: null,
      ),
    ];

    for (final testCase in cases) {
      test(testCase.name, () {
        final selection = selectTracks(
          audioTracks: testCase.tracks,
          subtitleTracks: const [],
          preferences: testCase.preferences,
          manual: testCase.manual,
        );

        expect(selection.audio?.id, testCase.expected);
      });
    }
  });

  group('subtítulos', () {
    final cases = <_SubtitleCase>[
      _SubtitleCase(
        'coincidencia exacta con el idioma por defecto',
        [
          _track('en', language: 'en'),
          _track('es', language: 'es'),
        ],
        expected: 'es',
      ),
      _SubtitleCase(
        'alias castellano',
        [_track('es', title: 'Castellano (SRT)')],
        expected: 'es',
      ),
      _SubtitleCase(
        'solo hay subtítulos en otro idioma: se quedan apagados',
        [
          _track('fr', language: 'fr'),
          _track('de', language: 'de'),
        ],
        expected: null,
      ),
      _SubtitleCase(
        'un solo subtítulo en un idioma no pedido no se activa',
        [_track('fr', language: 'fr')],
        expected: null,
      ),
      _SubtitleCase(
        'sin subtítulos no se activa nada',
        const [],
        expected: null,
      ),
      _SubtitleCase(
        'el usuario eligió otra pista a mano y se respeta',
        [
          _track('es', language: 'es'),
          _track('en', language: 'en'),
        ],
        manual: const ManualTrackChoice(
          subtitleId: 'en',
          subtitlesLocked: true,
        ),
        expected: 'en',
      ),
      _SubtitleCase(
        'el usuario apagó los subtítulos: no se vuelven a encender',
        [_track('es', language: 'es')],
        manual: const ManualTrackChoice(
          subtitlesOff: true,
          subtitlesLocked: true,
        ),
        expected: null,
      ),
      _SubtitleCase(
        'un archivo externo bloquea la elección automática',
        [_track('es', language: 'es')],
        manual: const ManualTrackChoice(subtitlesLocked: true),
        expected: null,
      ),
      _SubtitleCase(
        'sin idioma de subtítulos configurado no se enciende ninguno',
        [_track('es', language: 'es')],
        preferences: const LanguagePreferences(subtitleOrder: []),
        expected: null,
      ),
      _SubtitleCase(
        'un idioma configurado distinto cambia la elección',
        [
          _track('es', language: 'es'),
          _track('en', language: 'en'),
        ],
        preferences: const LanguagePreferences(subtitleOrder: [kLanguageEnglish]),
        expected: 'en',
      ),
    ];

    for (final testCase in cases) {
      test(testCase.name, () {
        final selection = selectTracks(
          audioTracks: const [],
          subtitleTracks: testCase.tracks,
          preferences: testCase.preferences,
          manual: testCase.manual,
        );

        expect(selection.subtitles?.id, testCase.expected);
      });
    }
  });

  test('audio y subtítulos se deciden en la misma llamada', () {
    final selection = selectTracks(
      audioTracks: [
        _track('en', language: 'en'),
        _track('lat', language: 'es-419'),
      ],
      subtitleTracks: [
        _track('sub-es', language: 'es'),
      ],
      preferences: _defaults,
    );

    expect(selection.audio?.id, 'lat');
    expect(selection.subtitles?.id, 'sub-es');
    expect(selection.isEmpty, isFalse);
  });

  test('una pista que declara dos idiomas puntúa por el mejor', () {
    final selection = selectTracks(
      audioTracks: [
        _track('dual', language: 'es-419', title: 'Español Latino / Inglés'),
      ],
      subtitleTracks: const [],
      preferences: const LanguagePreferences(
        audioOrder: [kLanguageEnglish, kLanguageSpanishLatin],
      ),
    );

    expect(selection.audio?.id, 'dual');
  });
}
