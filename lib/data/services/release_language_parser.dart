/// Extrae idiomas de audio y subtítulos de un nombre de release.
///
/// Es deliberadamente conservador: solo marca un idioma cuando el nombre lo
/// declara (`LATINO`, `Castellano`, `VOSE`…) o cuando el addon lo publica como
/// bandera (`🇬🇧 / 🇷🇺`, que es como Torrentio informa de los idiomas). No
/// asume inglés por defecto ni convierte `MULTi`/`DUAL` en español: esos
/// términos solo indican que hay varias pistas, no cuáles.
///
/// Lógica pura: sin Flutter ni red.
library;

import '../models/language_preferences.dart';

/// Banderas de país/región → idioma, tal y como las usan los addons. El mapa
/// no pretende ser exhaustivo: solo cubre lo que aparece en los payloads.
const Map<String, String> _flagLanguages = {
  '🇬🇧': kLanguageEnglish,
  '🇺🇸': kLanguageEnglish,
  '🇦🇺': kLanguageEnglish,
  '🇨🇦': kLanguageEnglish,
  '🇪🇸': kLanguageSpanish,
  '🇲🇽': kLanguageSpanishLatin,
  '🇦🇷': kLanguageSpanishLatin,
  '🇨🇴': kLanguageSpanishLatin,
  '🇨🇱': kLanguageSpanishLatin,
  '🇵🇪': kLanguageSpanishLatin,
  '🇻🇪': kLanguageSpanishLatin,
  '🇷🇺': 'ru',
  '🇵🇹': 'pt',
  '🇧🇷': 'pt',
  '🇫🇷': 'fr',
  '🇩🇪': 'de',
  '🇮🇹': 'it',
  '🇯🇵': 'ja',
  '🇰🇷': 'ko',
  '🇨🇳': 'zh',
  '🇮🇳': 'hi',
  '🇹🇷': 'tr',
  '🇵🇱': 'pl',
  '🇳🇱': 'nl',
  '🇸🇪': 'sv',
  '🇺🇦': 'uk',
  '🇸🇦': 'ar',
};

/// Alias de idioma que aparecen justo después de un marcador de subtítulos
/// (`Sub (Rus Eng)`, `Subtitulado Esp`, `Subs ES`…).
const Map<String, String> _subtitleAliases = {
  'es': kLanguageSpanish,
  'esp': kLanguageSpanish,
  'spa': kLanguageSpanish,
  'espanol': kLanguageSpanish,
  'español': kLanguageSpanish,
  'spanish': kLanguageSpanish,
  'castellano': kLanguageSpanish,
  'latino': kLanguageSpanishLatin,
  'latina': kLanguageSpanishLatin,
  // `en` no entra como alias: en «Subtitulado en Español» es la preposición
  // española, no el código de inglés. `Eng`/`English` sí son inequívocos.
  'eng': kLanguageEnglish,
  'ingles': kLanguageEnglish,
  'inglés': kLanguageEnglish,
  'ru': 'ru',
  'rus': 'ru',
  'ruso': 'ru',
  'fr': 'fr',
  'fre': 'fr',
  'frances': 'fr',
  'francés': 'fr',
  'pt': 'pt',
  'por': 'pt',
  'portugues': 'pt',
  'portugués': 'pt',
  'it': 'it',
  'ita': 'it',
  'de': 'de',
  'ger': 'de',
  'aleman': 'de',
  'alemán': 'de',
  'ja': 'ja',
  'jap': 'ja',
  'japones': 'ja',
  'japonés': 'ja',
  'ko': 'ko',
  'kor': 'ko',
  'coreano': 'ko',
  'zh': 'zh',
  'chi': 'zh',
  'chino': 'zh',
};

class ReleaseLanguages {
  final Set<String> audio;
  final Set<String> subtitles;

  /// `MULTI` o `DUAL` cuando el release declara varias pistas sin decir cuáles.
  final String? audioMode;

  /// True cuando hay un marcador de subtítulos aunque no se conozca el idioma
  /// (`Subs`, sin más). Permite decir «Subs: sí» en vez de «Subs: —».
  final bool hasSubtitles;

  const ReleaseLanguages({
    this.audio = const {},
    this.subtitles = const {},
    this.audioMode,
    this.hasSubtitles = false,
  });

  bool get isEmpty =>
      audio.isEmpty && subtitles.isEmpty && audioMode == null && !hasSubtitles;

  @override
  String toString() =>
      'ReleaseLanguages(audio: $audio, subs: $subtitles, '
      'mode: $audioMode, hasSubs: $hasSubtitles)';
}

class ReleaseLanguageParser {
  static Set<String> _flagsIn(String release) {
    final runes = release.runes.toList(growable: false);
    final flags = <String>{};
    for (var i = 0; i + 1 < runes.length; i++) {
      if (!_isRegionalIndicator(runes[i]) ||
          !_isRegionalIndicator(runes[i + 1])) {
        continue;
      }
      final flag = String.fromCharCodes([runes[i], runes[i + 1]]);
      final language = _flagLanguages[flag];
      if (language != null) flags.add(language);
      i++; // El segundo indicador ya forma parte de esta bandera.
    }
    return flags;
  }

  static bool _isRegionalIndicator(int rune) =>
      rune >= 0x1F1E6 && rune <= 0x1F1FF;

  static final _latino = RegExp(r'\b(latino|latina|es-419)\b');
  static final _castellano = RegExp(r'\bcastellano\b');
  static final _spanish = RegExp(
    r'\b(espa[nñ]ol|espanol|espa[nñ]a|espana|spa|spanish)\b',
  );
  static final _english = RegExp(r'\b(english|ingl[eé]s|eng)\b');
  static final _multi = RegExp(r'\bmulti\b');
  static final _dual = RegExp(r'\bdual\b');
  static final _dub = RegExp(r'\b(dub|doblaje|doblado)\b');
  static final _subtitleMarker = RegExp(
    r'\b(subs?|subtitles?|subtitulado|subbed|vose|vostfr)\b',
  );
  static final _vose = RegExp(r'\bvose\b');
  static final _vostfr = RegExp(r'\bvostfr\b');

  /// Copia de [text] sin los idiomas que aparecen dentro de un marcador de
  /// subtítulos (`Sub (Rus Eng)`, `Subs Español`). Así esos idiomas no se
  /// confunden con pistas de audio.
  static String _audioText(String text) {
    final units = text.codeUnits.toList(growable: false);
    for (final marker in _subtitleMarker.allMatches(text)) {
      var end = marker.end + 48 < text.length ? marker.end + 48 : text.length;
      // La lista de subtítulos vive en la misma línea; no hay que borrar
      // idiomas de la línea siguiente (que pueden ser audio).
      final newline = text.indexOf('\n', marker.end);
      if (newline != -1 && newline < end) end = newline;
      final window = text.substring(marker.start, end);
      for (final alias in _subtitleAliases.keys) {
        for (final match in RegExp(
          '\\b${RegExp.escape(alias)}\\b',
        ).allMatches(window)) {
          final start = marker.start + match.start;
          final stop = marker.start + match.end;
          for (var i = start; i < stop && i < units.length; i++) {
            units[i] = 0x20;
          }
        }
      }
    }
    return String.fromCharCodes(units);
  }

  /// [release] puede ser el nombre del archivo, el título de Torrentio, la
  /// descripción de Comet o el nombre del addon; se pasan todos juntos.
  static ReleaseLanguages parse(String release) {
    final text = release.toLowerCase().replaceAll(
      RegExp(r'[._\-\[\](){}]'),
      ' ',
    );
    final audioText = _audioText(text);

    final audio = <String>{};
    final subtitles = <String>{};

    final latino = _latino.hasMatch(audioText);
    final castellano = _castellano.hasMatch(audioText);
    final spanishInSubtitleMarker =
        (_latino.hasMatch(text) && !_latino.hasMatch(audioText)) ||
        (_castellano.hasMatch(text) && !_castellano.hasMatch(audioText)) ||
        (_spanish.hasMatch(text) && !_spanish.hasMatch(audioText));
    final spanishSubtitleMarker =
        _vose.hasMatch(text) ||
        RegExp(r'\bsubtitulado\b').hasMatch(text) ||
        spanishInSubtitleMarker;
    final spanishWord = !latino && _spanish.hasMatch(audioText);
    if (latino) audio.add(kLanguageSpanishLatin);
    if (castellano) audio.add(kLanguageSpanish);
    // «Español Latino» es latino, no castellano: el término genérico solo
    // cuenta cuando el release no declara ya la variante latina. En
    // «Subtitulado Español» la palabra describe los subtítulos, no el audio.
    if (spanishWord) audio.add(kLanguageSpanish);
    if (_english.hasMatch(audioText)) audio.add(kLanguageEnglish);

    // MULTI/DUAL describen cuántas pistas hay, no cuáles. Se guardan como
    // etiqueta y se dejan de inventar español/inglés.
    final audioMode = _multi.hasMatch(audioText)
        ? 'MULTI'
        : (_dual.hasMatch(audioText) ? 'DUAL' : null);

    // Banderas: un addon puede publicar los idiomas así en vez de con palabras.
    // Se leen por pares de indicadores regionales, no con `contains`: en
    // `🇯🇵🇪🇸` la subcadena `🇵🇪` (Perú) cruza la frontera de las dos banderas.
    final flags = _flagsIn(release);

    final explicitSpanishAudio = latino || castellano || spanishWord;
    final isDub = _dub.hasMatch(text);
    final hasJapanese = flags.contains('ja');
    // `Subtitulado Esp`/`VOSE` con bandera española describen subtítulos, no
    // una pista de audio. Si además hay una palabra explícita de audio
    // (`Castellano`, `Latino`), esa sí manda.
    var hasSubtitles = false;

    if (hasJapanese && flags.length > 1 && !isDub && !explicitSpanishAudio) {
      // Anime subtitulado: `🇯🇵🇪🇸` significa audio japonés con subtítulos en
      // español, no una pista de audio española. Si el addon marca DUB, las
      // banderas vuelven a ser audio.
      audio.add('ja');
      for (final flag in flags) {
        if (flag == 'ja') continue;
        subtitles.add(flag);
      }
      hasSubtitles = true;
    } else {
      for (final flag in flags) {
        if (spanishSubtitleMarker &&
            !explicitSpanishAudio &&
            (flag == kLanguageSpanish || flag == kLanguageSpanishLatin)) {
          continue;
        }
        audio.add(flag);
      }
    }

    // Subtítulos: solo el idioma que se declara. Un `Sub (Rus Eng)` no es
    // español, y un `Subs` suelto no permite afirmar el idioma.
    for (final marker in _subtitleMarker.allMatches(text)) {
      hasSubtitles = true;
      final word = marker.group(0)!;
      if (word == 'vose') {
        subtitles.add(kLanguageSpanish);
        continue;
      }
      if (word == 'vostfr') {
        subtitles.add('fr');
        continue;
      }
      // «Subtitulado» es la palabra española: si no sigue otro idioma, son
      // subtítulos en español.
      if (word == 'subtitulado') subtitles.add(kLanguageSpanish);

      final end = marker.end + 48 < text.length ? marker.end + 48 : text.length;
      final window = text.substring(marker.start, end);
      for (final entry in _subtitleAliases.entries) {
        if (RegExp('\\b${RegExp.escape(entry.key)}\\b').hasMatch(window)) {
          subtitles.add(entry.value);
        }
      }
    }

    // `VOSE`/`VOSTFR` también pueden aparecer como marcador exacto sin que el
    // regex de palabra los capture por el contexto; se comprueban aparte.
    if (_vose.hasMatch(text)) {
      subtitles.add(kLanguageSpanish);
      hasSubtitles = true;
    }
    if (_vostfr.hasMatch(text)) {
      subtitles.add('fr');
      hasSubtitles = true;
    }

    return ReleaseLanguages(
      audio: audio,
      subtitles: subtitles,
      audioMode: audioMode,
      hasSubtitles: hasSubtitles || subtitles.isNotEmpty,
    );
  }
}
