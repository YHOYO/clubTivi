/// Ranking puro de fuentes de reproducción.
///
/// Sin Flutter, sin red y sin estado global: recibe la lista y las preferencias,
/// y devuelve una lista nueva ordenada. El orden es lexicográfico por tramos:
///
///   1. idioma de audio preferido (latino → español → inglés por defecto)
///   2. subtítulos en idioma preferido
///   3. fuente cacheada
///   4. tipo de fuente (debrid > addon > scraper > torrent)
///   5. calidad (4K > 1080p > 720p > 480p; CAM/TS siempre al final)
///   6. seeds (más seeds primero)
///   7. título e id, para que el resultado sea determinista
library;

import '../models/language_preferences.dart';
import '../models/stream_source.dart';

/// Ordena [sources] sin mutar la entrada.
List<StreamSource> rankStreams(
  List<StreamSource> sources,
  LanguagePreferences preferences,
) {
  final ranked = [...sources];
  ranked.sort((a, b) => compareStreams(a, b, preferences));
  return ranked;
}

/// Comparador de dos fuentes. Negativo si [a] debe ir antes que [b].
int compareStreams(
  StreamSource a,
  StreamSource b,
  LanguagePreferences preferences,
) {
  // 1. Audio: el índice en la lista de preferencias manda.
  final audio = preferences
      .audioRank(a.audioLanguages)
      .compareTo(preferences.audioRank(b.audioLanguages));
  if (audio != 0) return audio;

  // 2. Subtítulos: desempate cuando el audio empata.
  final subtitles = preferences
      .subtitleRank(a.subtitleLanguages)
      .compareTo(preferences.subtitleRank(b.subtitleLanguages));
  if (subtitles != 0) return subtitles;

  // 3. Caché: una fuente instantánea gana a una que hay que resolver.
  if (a.isCached != b.isCached) return a.isCached ? -1 : 1;

  // 4. Tipo de fuente.
  final kind = _kindPriority(a.kind).compareTo(_kindPriority(b.kind));
  if (kind != 0) return kind;

  // 5. Calidad, de mejor a peor.
  final quality = _qualityScore(b).compareTo(_qualityScore(a));
  if (quality != 0) return quality;

  // 6. Seeds, de más a menos; sin dato queda detrás de cualquier valor.
  final aSeeds = a.seeds ?? -1;
  final bSeeds = b.seeds ?? -1;
  final seeds = bSeeds.compareTo(aSeeds);
  if (seeds != 0) return seeds;

  // 7. Desempate estable y determinista.
  final byTitle = a.title.toLowerCase().compareTo(b.title.toLowerCase());
  if (byTitle != 0) return byTitle;
  return a.id.compareTo(b.id);
}

/// True cuando la fuente ofrece audio en español (latino o castellano).
bool hasSpanishAudio(StreamSource source) =>
    source.audioLanguages.any(_isSpanishCode);

/// True cuando la fuente ofrece subtítulos en español (castellano o latino).
bool hasSpanishSubtitles(StreamSource source) =>
    source.subtitleLanguages.any(_isSpanishCode);

/// Una fuente entra en «Solo español» si tiene audio o subtítulos en español.
bool isSpanishSource(StreamSource source) =>
    hasSpanishAudio(source) || hasSpanishSubtitles(source);

/// Preferencias guardadas con español delante, conservando el orden relativo
/// que el usuario eligió dentro del español y entre los demás idiomas. Si su
/// lista no incluye ninguna variante, se añaden las dos por defecto.
LanguagePreferences spanishFirstPreferences(LanguagePreferences preferences) {
  List<String> promoted(List<String> order, List<String> defaults) {
    final normalized = <String>[];
    for (final code in order) {
      final value = normalizeLanguageCode(code);
      if (value != null) normalized.add(value);
    }
    final spanish = normalized.where(_isSpanishCode).toList();
    final rest = normalized.where((code) => !_isSpanishCode(code)).toList();
    final group = spanish.isEmpty ? [...defaults] : spanish;
    for (final code in defaults) {
      if (!group.contains(code)) group.add(code);
    }
    return [...group, ...rest];
  }

  return preferences.copyWith(
    audioOrder: promoted(preferences.audioOrder, const [
      kLanguageSpanishLatin,
      kLanguageSpanish,
    ]),
    subtitleOrder: promoted(preferences.subtitleOrder, const [
      kLanguageSpanish,
      kLanguageSpanishLatin,
    ]),
  );
}

/// Filtra y ordena lo que se va a pintar en el selector.
///
/// [sources] llega ya rankeado por el provider con las preferencias guardadas;
/// si no se pide «español primero» se respeta ese orden. El filtro nunca debe
/// aplicarse antes de este punto: el provider ya no recorta a 10.
List<StreamSource> selectStreams(
  List<StreamSource> sources, {
  required LanguagePreferences preferences,
  bool spanishOnly = false,
  bool spanishFirst = false,
}) {
  final filtered = spanishOnly
      ? sources.where(isSpanishSource).toList(growable: false)
      : List<StreamSource>.of(sources);
  if (!spanishFirst) return filtered;
  return rankStreams(filtered, spanishFirstPreferences(preferences));
}

bool _isSpanishCode(String code) {
  final normalized = normalizeLanguageCode(code);
  return normalized == kLanguageSpanish || normalized == kLanguageSpanishLatin;
}

int _kindPriority(SourceKind kind) {
  switch (kind) {
    case SourceKind.debrid:
      return 0;
    case SourceKind.addon:
      return 1;
    case SourceKind.scraper:
      return 2;
    case SourceKind.torrent:
      return 3;
  }
}

/// Puntúa la calidad; CAM/TS se hunde aunque el nombre diga 4K.
int _qualityScore(StreamSource source) {
  final text = '${source.quality ?? ''} ${source.title}'.toLowerCase();
  if (RegExp(r'\b(cam|hdts|ts|telesync|telecine)\b').hasMatch(text)) {
    return -1;
  }
  if (RegExp(r'\b(2160p|4k)\b').hasMatch(text)) return 4;
  if (RegExp(r'\b1080p\b').hasMatch(text)) return 3;
  if (RegExp(r'\b720p\b').hasMatch(text)) return 2;
  if (RegExp(r'\b480p\b').hasMatch(text)) return 1;
  return 0;
}
