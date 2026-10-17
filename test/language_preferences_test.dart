import 'dart:convert';

import 'package:clubtivi/data/models/language_preferences.dart';
import 'package:clubtivi/data/services/language_preferences_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('por defecto: latino, español, inglés y subtítulos en español', () {
    const prefs = LanguagePreferences.defaults;

    expect(prefs.audioOrder, [kLanguageSpanishLatin, kLanguageSpanish, kLanguageEnglish]);
    expect(prefs.subtitleOrder, [kLanguageSpanish]);
  });

  test('normaliza alias de releases y códigos', () {
    expect(normalizeLanguageCode('Latino'), kLanguageSpanishLatin);
    expect(normalizeLanguageCode('ES-LA'), kLanguageSpanishLatin);
    expect(normalizeLanguageCode('es_419'), kLanguageSpanishLatin);
    expect(normalizeLanguageCode('Español Latino'), kLanguageSpanishLatin);
    expect(normalizeLanguageCode('CASTELLANO'), kLanguageSpanish);
    expect(normalizeLanguageCode('spa'), kLanguageSpanish);
    expect(normalizeLanguageCode('English'), kLanguageEnglish);
    expect(normalizeLanguageCode('eng'), kLanguageEnglish);
    expect(normalizeLanguageCode('PT'), 'pt');
    expect(normalizeLanguageCode('de'), 'de');
    expect(normalizeLanguageCode('   '), isNull);
    expect(normalizeLanguageCode(null), isNull);
  });

  test('audio: el índice de la preferencia es el tramo', () {
    const prefs = LanguagePreferences.defaults;

    expect(prefs.audioRank({kLanguageSpanishLatin}), 0);
    expect(prefs.audioRank({'latino'}), 0);
    expect(prefs.audioRank({kLanguageSpanish}), 1);
    expect(prefs.audioRank({kLanguageEnglish}), 2);
    expect(prefs.audioRank({'fr'}), 4, reason: 'conocido no preferido');
    expect(prefs.audioRank({}), 3, reason: 'sin datos queda entre medias');
  });

  test('subtítulos: mismo criterio', () {
    const prefs = LanguagePreferences.defaults;

    expect(prefs.subtitleRank({kLanguageSpanish}), 0);
    expect(prefs.subtitleRank({}), 1);
    expect(prefs.subtitleRank({kLanguageEnglish}), 2);
  });

  test('un orden personalizado manda sobre el de por defecto', () {
    const prefs = LanguagePreferences(
      audioOrder: [kLanguageEnglish, kLanguageSpanishLatin],
      subtitleOrder: [kLanguageEnglish, kLanguageSpanish],
    );

    expect(prefs.audioRank({kLanguageEnglish}), 0);
    expect(prefs.audioRank({kLanguageSpanishLatin}), 1);
    expect(prefs.subtitleRank({kLanguageEnglish}), 0);
    expect(prefs.subtitleRank({kLanguageSpanish}), 1);
  });

  test('un orden vacío no penaliza ninguna fuente', () {
    const prefs = LanguagePreferences(audioOrder: [], subtitleOrder: []);

    expect(prefs.audioRank({'fr'}), 0);
    expect(prefs.subtitleRank({'en'}), 0);
  });

  test('fromJson normaliza, deduplica y tolera datos corruptos', () {
    final parsed = LanguagePreferences.fromJson({
      'audioOrder': ['English', 'eng', 'Latino'],
      'subtitleOrder': ['CASTELLANO'],
    });
    expect(parsed.audioOrder, [kLanguageEnglish, kLanguageSpanishLatin]);
    expect(parsed.subtitleOrder, [kLanguageSpanish]);

    expect(LanguagePreferences.fromJson('nope'), LanguagePreferences.defaults);
    expect(
      LanguagePreferences.fromJson({'audioOrder': 'en'}),
      LanguagePreferences.defaults,
    );
  });

  test('persiste el orden y lo recarga en un notifier nuevo', () async {
    final first = LanguagePreferencesNotifier();
    await first.load();
    expect(first.state, LanguagePreferences.defaults);

    const custom = LanguagePreferences(
      audioOrder: [kLanguageEnglish, kLanguageSpanishLatin],
      subtitleOrder: [kLanguageEnglish],
    );
    await first.save(custom);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(languagePreferencesKey), contains('en'));

    final second = LanguagePreferencesNotifier();
    await second.load();
    expect(second.state, custom);
  });

  test('JSON persistido corrupto cae a los valores por defecto', () async {
    SharedPreferences.setMockInitialValues({
      languagePreferencesKey: '{not json',
    });

    final notifier = LanguagePreferencesNotifier();
    await notifier.load();

    expect(notifier.state, LanguagePreferences.defaults);
  });

  test('sin clave persistida arranca con las preferencias por defecto',
      () async {
    final notifier = LanguagePreferencesNotifier();
    await notifier.load();

    expect(notifier.state, LanguagePreferences.defaults);
    expect(jsonEncode(notifier.state.toJson()), contains('es-419'));
  });
}
