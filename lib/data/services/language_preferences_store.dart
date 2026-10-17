import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/language_preferences.dart';

/// Clave persistida de las preferencias de idioma.
const String languagePreferencesKey = 'stream_language_preferences';

/// Estado persistido de idiomas: es el dueño del orden de audio y subtítulos.
class LanguagePreferencesNotifier extends StateNotifier<LanguagePreferences> {
  LanguagePreferencesNotifier({
    LanguagePreferences initial = LanguagePreferences.defaults,
    SharedPreferences? preferences,
  })  : _prefs = preferences,
        super(initial);

  SharedPreferences? _prefs;
  Future<void>? _loading;
  bool _loaded = false;

  bool get isLoaded => _loaded;

  Future<SharedPreferences> _preferences() async =>
      _prefs ??= await SharedPreferences.getInstance();

  /// Lectura compartida: las mutaciones esperan a que termine para no escribir
  /// encima de una lectura a medio hacer.
  Future<void> load() {
    if (_loaded) return Future<void>.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    final prefs = await _preferences();
    final raw = prefs.getString(languagePreferencesKey);
    var value = LanguagePreferences.defaults;
    if (raw != null && raw.isNotEmpty) {
      try {
        value = LanguagePreferences.fromJson(jsonDecode(raw));
      } catch (_) {
        value = LanguagePreferences.defaults;
      }
    }
    _loaded = true;
    if (!mounted) return;
    state = value;
  }

  Future<void> save(LanguagePreferences preferences) async {
    await load();
    final prefs = await _preferences();
    await prefs.setString(
      languagePreferencesKey,
      jsonEncode(preferences.toJson()),
    );
    if (!mounted) return;
    state = preferences;
  }

  Future<void> setAudioOrder(List<String> order) =>
      save(state.copyWith(audioOrder: order));

  Future<void> setSubtitleOrder(List<String> order) =>
      save(state.copyWith(subtitleOrder: order));

  Future<void> reset() => save(LanguagePreferences.defaults);
}

final languagePreferencesProvider =
    StateNotifierProvider<LanguagePreferencesNotifier, LanguagePreferences>(
  (ref) {
    final notifier = LanguagePreferencesNotifier();
    notifier.load();
    return notifier;
  },
);
