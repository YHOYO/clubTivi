/// Extrae idiomas de audio y subtítulos de un nombre de release.
///
/// Es deliberadamente conservador: solo marca un idioma cuando el nombre lo
/// declara (`LATINO`, `Castellano`, `MULTI`, `VOSE`…) o cuando el addon lo
/// publica como bandera (`🇬🇧 / 🇷🇺`, que es como Torrentio informa de los
/// idiomas). No asume inglés por defecto, para no inventar preferencias donde
/// no hay datos.
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

class ReleaseLanguages {
  final Set<String> audio;
  final Set<String> subtitles;

  const ReleaseLanguages({
    this.audio = const {},
    this.subtitles = const {},
  });

  bool get isEmpty => audio.isEmpty && subtitles.isEmpty;

  @override
  String toString() => 'ReleaseLanguages(audio: $audio, subs: $subtitles)';
}

class ReleaseLanguageParser {
  static final _latino = RegExp(r'\b(latino|latina|es-419)\b');
  static final _castellano = RegExp(r'\bcastellano\b');
  static final _spanish =
      RegExp(r'\b(espa[nñ]ol|espanol|espa[nñ]a|espana|spa)\b');
  static final _english = RegExp(r'\b(english|ingl[eé]s|eng)\b');
  static final _multi = RegExp(r'\b(multi|dual)\b');
  static final _subtitled =
      RegExp(r'\b(vose|subs?|subtitles?|subtitulado|subbed)\b');

  /// [release] puede ser el nombre del archivo, el título de Torrentio o ambos.
  static ReleaseLanguages parse(String release) {
    final text = release.toLowerCase().replaceAll(RegExp(r'[._\-\[\](){}]'), ' ');
    final audio = <String>{};
    final subtitles = <String>{};

    final latino = _latino.hasMatch(text);
    if (latino) audio.add(kLanguageSpanishLatin);
    if (_castellano.hasMatch(text)) audio.add(kLanguageSpanish);
    // «Español Latino» es latino, no castellano: el término genérico solo
    // cuenta cuando el release no declara ya la variante latina.
    if (!latino && _spanish.hasMatch(text)) audio.add(kLanguageSpanish);
    if (_english.hasMatch(text)) audio.add(kLanguageEnglish);

    // MULTI/DUAL suelen ser español + inglés; se declaran ambos para que el
    // ranking pueda preferir el que corresponda.
    if (_multi.hasMatch(text)) {
      audio.addAll([kLanguageSpanish, kLanguageEnglish]);
    }

    // Banderas: un addon puede publicar los idiomas así en vez de con palabras.
    for (final entry in _flagLanguages.entries) {
      if (release.contains(entry.key)) audio.add(entry.value);
    }

    if (_subtitled.hasMatch(text)) {
      subtitles.add(kLanguageSpanish);
    }

    return ReleaseLanguages(audio: audio, subtitles: subtitles);
  }
}
