import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Idioma en el que TMDB devuelve títulos, sinopsis y tráilers.
class TmdbLanguage {
  const TmdbLanguage(this.code, this.label);

  final String code;
  final String label;
}

/// Idiomas ofrecidos en el selector de Shows & Movies. TMDB usa el formato
/// `idioma-PAÍS`; añadir uno aquí lo hace aparecer en la interfaz.
const List<TmdbLanguage> tmdbLanguages = [
  TmdbLanguage('es-ES', 'Español (España)'),
  TmdbLanguage('es-MX', 'Español (México)'),
  TmdbLanguage('en-US', 'English'),
  TmdbLanguage('pt-BR', 'Português (Brasil)'),
  TmdbLanguage('fr-FR', 'Français'),
  TmdbLanguage('de-DE', 'Deutsch'),
  TmdbLanguage('it-IT', 'Italiano'),
];

const String tmdbLanguageKey = 'tmdb_metadata_language';

/// Español por defecto: es lo que el usuario espera al abrir la app.
const String defaultTmdbLanguage = 'es-ES';

TmdbLanguage tmdbLanguageFor(String code) => tmdbLanguages.firstWhere(
  (language) => language.code == code,
  orElse: () => tmdbLanguages.first,
);

/// Estado persistido del idioma de metadatos. Cambiarlo reconstruye el
/// repositorio de Shows & Movies, que vuelve a pedir catálogos y fichas.
class TmdbLanguageNotifier extends StateNotifier<String> {
  TmdbLanguageNotifier({SharedPreferences? preferences})
    : _prefs = preferences,
      super(defaultTmdbLanguage);

  SharedPreferences? _prefs;
  Future<void>? _loading;

  Future<SharedPreferences> _preferences() async =>
      _prefs ??= await SharedPreferences.getInstance();

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final prefs = await _preferences();
    final saved = prefs.getString(tmdbLanguageKey);
    if (!mounted) return;
    if (saved == null || tmdbLanguages.every((l) => l.code != saved)) return;
    state = saved;
  }

  Future<void> select(String code) async {
    await load();
    if (tmdbLanguages.every((l) => l.code != code)) return;
    final prefs = await _preferences();
    await prefs.setString(tmdbLanguageKey, code);
    if (!mounted) return;
    state = code;
  }
}

final tmdbLanguageProvider =
    StateNotifierProvider<TmdbLanguageNotifier, String>((ref) {
      final notifier = TmdbLanguageNotifier();
      notifier.load();
      return notifier;
    });
