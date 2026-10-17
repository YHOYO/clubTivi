// La pantalla de idiomas es la única puerta visible a las preferencias: si no
// escribe en el store que ya existe, el ranking y el reproductor seguirían con
// los valores por defecto sin que nadie lo note.
import 'dart:convert';

import 'package:clubtivi/data/models/language_preferences.dart';
import 'package:clubtivi/data/services/language_preferences_store.dart';
import 'package:clubtivi/features/settings/language_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<ProviderContainer> pumpScreen(WidgetTester tester) async {
    // Una ventana alta deja todas las filas montadas: la pantalla es una lista
    // larga y las opciones de subtítulos no caben en el viewport de test.
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: LanguageSettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('muestra el orden por defecto y el idioma de subtítulos',
      (tester) async {
    final container = await pumpScreen(tester);

    // El mismo nombre aparece en la lista de subtítulos: se comprueba dentro
    // de cada fila de audio, no en toda la pantalla.
    for (final (code, label) in const [
      ('es-419', 'Español (Latino)'),
      ('es', 'Español'),
      ('en', 'Inglés'),
    ]) {
      expect(
        find.descendant(
          of: find.byKey(ValueKey('audio-row-$code')),
          matching: find.text(label),
        ),
        findsOneWidget,
      );
    }
    expect(
      container.read(languagePreferencesProvider).subtitleOrder,
      [kLanguageSpanish],
      reason: 'el subtítulo por defecto sigue siendo español',
    );

    final latino = tester.getTopLeft(find.byKey(const ValueKey('audio-row-es-419'))).dy;
    final spanish = tester.getTopLeft(find.byKey(const ValueKey('audio-row-es'))).dy;
    final english = tester.getTopLeft(find.byKey(const ValueKey('audio-row-en'))).dy;
    expect(latino, lessThan(spanish));
    expect(spanish, lessThan(english));

    // «Español» ya está elegido como subtítulo por defecto: repetirlo en la
    // lista de añadir no tiene sentido.
    expect(find.byKey(const ValueKey('add-language-es')), findsNothing);
    expect(find.byKey(const ValueKey('add-language-pt')), findsOneWidget);
  });

  testWidgets('reordena el audio y lo persiste en el store', (tester) async {
    final container = await pumpScreen(tester);

    await tapKey(tester, 'audio-up-es');

    expect(
      container.read(languagePreferencesProvider).audioOrder,
      [kLanguageSpanish, kLanguageSpanishLatin, kLanguageEnglish],
    );

    final raw = (await SharedPreferences.getInstance())
        .getString(languagePreferencesKey);
    expect(raw, isNotNull);
    expect(
      LanguagePreferences.fromJson(jsonDecode(raw!)).audioOrder,
      [kLanguageSpanish, kLanguageSpanishLatin, kLanguageEnglish],
    );
  });

  testWidgets('quita un idioma y lo puede volver a añadir', (tester) async {
    final container = await pumpScreen(tester);

    await tapKey(tester, 'audio-remove-en');
    expect(
      container.read(languagePreferencesProvider).audioOrder,
      [kLanguageSpanishLatin, kLanguageSpanish],
    );
    expect(find.byKey(const ValueKey('add-language-en')), findsOneWidget);

    await tapKey(tester, 'add-language-en');
    expect(
      container.read(languagePreferencesProvider).audioOrder,
      [kLanguageSpanishLatin, kLanguageSpanish, kLanguageEnglish],
    );
  });

  testWidgets('elige el idioma de subtítulos por defecto', (tester) async {
    final container = await pumpScreen(tester);

    await tapKey(tester, 'subtitle-option-en');

    expect(
      container.read(languagePreferencesProvider).subtitleOrder,
      [kLanguageEnglish],
    );

    final raw = (await SharedPreferences.getInstance())
        .getString(languagePreferencesKey);
    expect(
      LanguagePreferences.fromJson(jsonDecode(raw!)).subtitleOrder,
      [kLanguageEnglish],
    );
  });

  testWidgets('«None» deja los subtítulos apagados por defecto',
      (tester) async {
    final container = await pumpScreen(tester);

    await tapKey(tester, 'subtitle-option-none');

    expect(container.read(languagePreferencesProvider).subtitleOrder, isEmpty);
    expect(
      container.read(languagePreferencesProvider).subtitleRank({kLanguageSpanish}),
      0,
      reason: 'sin idioma configurado, el ranking no penaliza a nadie',
    );
  });
}
