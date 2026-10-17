/// Elección automática de pistas según las preferencias de idioma.
///
/// Lógica pura sobre listas de pistas: no conoce media_kit, ni Flutter, ni el
/// reproductor. La pantalla traduce sus `AudioTrack`/`SubtitleTrack` a
/// [SelectableTrack], pide la elección y aplica el resultado.
///
/// Reglas:
///
///   * una elección manual del usuario siempre gana, mientras la pista siga
///     existiendo en la lista;
///   * una pista solo se elige si su idioma está entre las preferencias: no se
///     activan subtítulos en un idioma que nadie pidió;
///   * si no hay coincidencia no se toca nada (`null`), y el reproductor
///     conserva su comportamiento por defecto.
library;

import '../models/language_preferences.dart';
import 'release_language_parser.dart';

/// Pista tal y como la ve el selector.
class SelectableTrack {
  final String id;

  /// Idioma declarado por el contenedor (`es`, `es-419`, `Spanish`…).
  final String? language;

  /// Título visible de la pista (`Español Latino`, `English 5.1`…).
  final String? title;

  const SelectableTrack({required this.id, this.language, this.title});

  /// Idiomas normalizados que declara la pista, por su idioma o por su título.
  ///
  /// `und` (indefinido) o vacío no cuentan: es justo el caso en el que la app
  /// no debe inventarse un idioma.
  Set<String> get languages {
    final codes = <String>{};
    final declared = normalizeLanguageCode(language);
    if (declared != null && declared != 'und') codes.add(declared);

    final parsed = ReleaseLanguageParser.parse(
      '${language ?? ''} ${title ?? ''}',
    );
    codes.addAll(parsed.audio);
    return codes;
  }

  @override
  String toString() => 'SelectableTrack($id, ${language ?? '-'}, ${title ?? '-'})';
}

/// Elección manual del usuario durante una reproducción.
class ManualTrackChoice {
  /// Pista de audio elegida a mano.
  final String? audioId;

  /// Pista de subtítulos elegida a mano.
  final String? subtitleId;

  /// El usuario apagó los subtítulos: no se vuelven a activar solos.
  final bool subtitlesOff;

  /// El usuario decidió los subtítulos (pista, archivo externo o apagados).
  final bool subtitlesLocked;

  const ManualTrackChoice({
    this.audioId,
    this.subtitleId,
    this.subtitlesOff = false,
    this.subtitlesLocked = false,
  });

  /// Nadie ha tocado nada todavía.
  static const ManualTrackChoice none = ManualTrackChoice();

  ManualTrackChoice copyWith({
    String? audioId,
    String? subtitleId,
    bool? subtitlesOff,
    bool? subtitlesLocked,
  }) {
    return ManualTrackChoice(
      audioId: audioId ?? this.audioId,
      subtitleId: subtitleId ?? this.subtitleId,
      subtitlesOff: subtitlesOff ?? this.subtitlesOff,
      subtitlesLocked: subtitlesLocked ?? this.subtitlesLocked,
    );
  }

  @override
  String toString() =>
      'ManualTrackChoice(audio: $audioId, subtitles: $subtitleId, '
      'off: $subtitlesOff, locked: $subtitlesLocked)';
}

/// Pistas que conviene aplicar al reproductor, o `null` para no tocar.
class TrackSelection {
  final SelectableTrack? audio;
  final SelectableTrack? subtitles;

  const TrackSelection({this.audio, this.subtitles});

  /// Nada que aplicar: el reproductor se queda como está.
  static const TrackSelection none = TrackSelection();

  bool get isEmpty => audio == null && subtitles == null;

  @override
  String toString() => 'TrackSelection(audio: $audio, subtitles: $subtitles)';
}

/// Elige la pista de audio y los subtítulos para una reproducción.
TrackSelection selectTracks({
  required List<SelectableTrack> audioTracks,
  required List<SelectableTrack> subtitleTracks,
  required LanguagePreferences preferences,
  ManualTrackChoice manual = ManualTrackChoice.none,
}) {
  return TrackSelection(
    audio: _pick(
      tracks: audioTracks,
      order: preferences.audioOrder,
      manualId: manual.audioId,
    ),
    subtitles: _pickSubtitles(subtitleTracks, preferences, manual),
  );
}

SelectableTrack? _pickSubtitles(
  List<SelectableTrack> tracks,
  LanguagePreferences preferences,
  ManualTrackChoice manual,
) {
  if (manual.subtitlesLocked) {
    // Apagados o un archivo externo: la elección manda aunque exista una pista
    // preferida. Una pista concreta se devuelve solo si sigue estando.
    return _byId(tracks, manual.subtitleId);
  }
  return _pick(
    tracks: tracks,
    order: preferences.subtitleOrder,
    manualId: null,
  );
}

/// Primera pista cuyo idioma coincide con el orden de [order].
///
/// Se recorre [order] entero: una pista que declare dos idiomas (por ejemplo
/// `Español Latino` con `es-419` y `es`) puntúa por el mejor de ellos, y si la
/// primera preferencia no está, la segunda todavía puede ganar.
SelectableTrack? _pick({
  required List<SelectableTrack> tracks,
  required List<String> order,
  required String? manualId,
}) {
  final manual = _byId(tracks, manualId);
  if (manual != null) return manual;
  if (tracks.isEmpty) return null;

  for (final preferred in order) {
    final wanted = normalizeLanguageCode(preferred);
    if (wanted == null) continue;
    for (final track in tracks) {
      if (track.languages.contains(wanted)) return track;
    }
  }
  return null;
}

SelectableTrack? _byId(List<SelectableTrack> tracks, String? id) {
  if (id == null || id.isEmpty) return null;
  for (final track in tracks) {
    if (track.id == id) return track;
  }
  return null;
}
