/// Preferencias de idioma para ordenar fuentes de reproducción.
///
/// Lógica pura: sin Flutter, sin red y sin almacenamiento. La persistencia vive
/// en `language_preferences_store.dart`; el ranking solo consume este valor.
library;

/// Español latinoamericano (`es-419`).
const String kLanguageSpanishLatin = 'es-419';

/// Español de España (`es`).
const String kLanguageSpanish = 'es';

/// Inglés (`en`).
const String kLanguageEnglish = 'en';

/// Alias que aparecen en nombres de release y en pistas de audio.
const Map<String, String> _languageAliases = {
  'es-419': kLanguageSpanishLatin,
  'es_419': kLanguageSpanishLatin,
  'es-la': kLanguageSpanishLatin,
  'esla': kLanguageSpanishLatin,
  'lat': kLanguageSpanishLatin,
  'latino': kLanguageSpanishLatin,
  'latina': kLanguageSpanishLatin,
  'espanol latino': kLanguageSpanishLatin,
  'español latino': kLanguageSpanishLatin,
  'spanish latino': kLanguageSpanishLatin,
  'es': kLanguageSpanish,
  'es-es': kLanguageSpanish,
  'spa': kLanguageSpanish,
  'esp': kLanguageSpanish,
  'castellano': kLanguageSpanish,
  'espanol': kLanguageSpanish,
  'español': kLanguageSpanish,
  'spanish': kLanguageSpanish,
  'en': kLanguageEnglish,
  'eng': kLanguageEnglish,
  'english': kLanguageEnglish,
  'ingles': kLanguageEnglish,
  'inglés': kLanguageEnglish,
  'pt': 'pt',
  'por': 'pt',
  'portugues': 'pt',
  'portugués': 'pt',
  'portuguese': 'pt',
  'fr': 'fr',
  'fra': 'fr',
  'fre': 'fr',
  'frances': 'fr',
  'francés': 'fr',
  'french': 'fr',
};

/// Normaliza un código o nombre de idioma a una forma estable.
///
/// Devuelve `null` para texto vacío. Los códigos desconocidos de dos o tres
/// letras se conservan en minúsculas: no se inventan equivalencias.
String? normalizeLanguageCode(String? raw) {
  if (raw == null) return null;
  final value = raw
      .trim()
      .toLowerCase()
      .replaceAll('_', '-')
      .replaceAll(RegExp(r'\s+'), ' ');
  if (value.isEmpty) return null;
  final alias = _languageAliases[value];
  if (alias != null) return alias;
  if (RegExp(r'^[a-z]{2,3}$').hasMatch(value)) return value;
  return value;
}

/// Catálogo de idiomas que la interfaz ofrece para audio y subtítulos.
///
/// No pretende ser exhaustivo: cubre los idiomas que aparecen en las fuentes y
/// los que un usuario puede querer poner por delante.
const Map<String, String> kLanguageCatalog = {
  kLanguageSpanishLatin: 'Español (Latino)',
  kLanguageSpanish: 'Español',
  kLanguageEnglish: 'Inglés',
  'pt': 'Portugués',
  'fr': 'Francés',
  'it': 'Italiano',
  'de': 'Alemán',
  'ru': 'Ruso',
  'ja': 'Japonés',
  'ko': 'Coreano',
  'zh': 'Chino',
  'ar': 'Árabe',
};

/// Etiqueta legible de un código (`es-419` → `Español (Latino)`).
///
/// Un idioma fuera del catálogo se muestra con su código en mayúsculas: es
/// preferible un `DE` a inventar un nombre a medias.
String languageLabel(String? code) {
  final normalized = normalizeLanguageCode(code);
  if (normalized == null) return '';
  return kLanguageCatalog[normalized] ?? normalized.toUpperCase();
}

/// Etiqueta corta para los badges del selector (`es-419` → `LAT`).
String languageBadge(String? code) {
  final normalized = normalizeLanguageCode(code);
  if (normalized == null) return '';
  return _languageBadges[normalized] ?? normalized.toUpperCase();
}

const Map<String, String> _languageBadges = {
  kLanguageSpanishLatin: 'LAT',
  kLanguageSpanish: 'ESP',
  kLanguageEnglish: 'ENG',
  'pt': 'POR',
  'fr': 'FRA',
  'it': 'ITA',
  'de': 'ALE',
  'ru': 'RUS',
  'ja': 'JAP',
  'ko': 'COR',
  'zh': 'CHI',
  'ar': 'ARA',
};

/// Orden de idiomas preferido para audio y para subtítulos.
///
/// El orden es la prioridad: el índice 0 es el idioma favorito.
class LanguagePreferences {
  final List<String> audioOrder;
  final List<String> subtitleOrder;

  const LanguagePreferences({
    this.audioOrder = const [
      kLanguageSpanishLatin,
      kLanguageSpanish,
      kLanguageEnglish,
    ],
    this.subtitleOrder = const [kLanguageSpanish],
  });

  /// Latino → Español → Inglés; subtítulos en español.
  static const LanguagePreferences defaults = LanguagePreferences();

  LanguagePreferences copyWith({
    List<String>? audioOrder,
    List<String>? subtitleOrder,
  }) {
    return LanguagePreferences(
      audioOrder: audioOrder ?? this.audioOrder,
      subtitleOrder: subtitleOrder ?? this.subtitleOrder,
    );
  }

  /// Tramo de audio: 0 = primera preferencia, 1 = segunda…
  ///
  /// Un idioma desconocido (sin metadatos) queda justo después de las
  /// preferencias y por delante de un idioma conocido que no se prefiere, que
  /// es el caso que el plan penaliza.
  int audioRank(Set<String> languages) => _rank(languages, audioOrder);

  /// Tramo de subtítulos: mismo criterio que [audioRank].
  int subtitleRank(Set<String> languages) => _rank(languages, subtitleOrder);

  static int _rank(Set<String> languages, List<String> order) {
    if (order.isEmpty) return 0;

    final available = <String>{};
    for (final language in languages) {
      final normalized = normalizeLanguageCode(language);
      if (normalized != null) available.add(normalized);
    }
    if (available.isEmpty) return order.length;

    for (var i = 0; i < order.length; i++) {
      final preferred = normalizeLanguageCode(order[i]);
      if (preferred != null && available.contains(preferred)) return i;
    }
    // Idioma conocido que no está en la lista: peor que "sin datos".
    return order.length + 1;
  }

  Map<String, dynamic> toJson() => {
        'audioOrder': audioOrder,
        'subtitleOrder': subtitleOrder,
      };

  /// Tolerante a datos corruptos: cada campo inválido vuelve a su valor por
  /// defecto en vez de dejar la app sin preferencias.
  factory LanguagePreferences.fromJson(Object? json) {
    if (json is! Map) return defaults;

    final audio = _stringList(json['audioOrder']);
    final subtitles = _stringList(json['subtitleOrder']);
    return LanguagePreferences(
      audioOrder: audio ?? defaults.audioOrder,
      subtitleOrder: subtitles ?? defaults.subtitleOrder,
    );
  }

  static List<String>? _stringList(Object? value) {
    if (value is! List) return null;
    final result = <String>[];
    for (final entry in value) {
      if (entry is! String) return null;
      final normalized = normalizeLanguageCode(entry);
      if (normalized != null && !result.contains(normalized)) {
        result.add(normalized);
      }
    }
    return result;
  }

  @override
  bool operator ==(Object other) {
    if (other is! LanguagePreferences) return false;
    return _sameOrder(audioOrder, other.audioOrder) &&
        _sameOrder(subtitleOrder, other.subtitleOrder);
  }

  @override
  int get hashCode => Object.hash(
        Object.hashAll(audioOrder),
        Object.hashAll(subtitleOrder),
      );

  static bool _sameOrder(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  String toString() =>
      'LanguagePreferences(audio: $audioOrder, subtitles: $subtitleOrder)';
}
