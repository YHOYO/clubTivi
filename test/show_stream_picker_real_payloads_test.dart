// El selector se prueba con las respuestas reales ya capturadas: la misma
// fila que el usuario ve tiene que decir el idioma correcto y el filtro tiene
// que dejar entrar la fuente española aunque el addon la publique en
// `description` o con una bandera.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clubtivi/data/models/stream_search_result.dart';
import 'package:clubtivi/data/models/stream_source.dart';
import 'package:clubtivi/data/services/stremio_stream_mapper.dart';
import 'package:clubtivi/features/shows/stream_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

List<StreamSource> _mapFixture(String fixture, String providerName) {
  final raw = File('test/fixtures/stremio/$fixture').readAsStringSync();
  final data = jsonDecode(raw) as Map<String, dynamic>;
  final streams = data['streams'] as List;
  final sources = <StreamSource>[];
  for (var i = 0; i < streams.length; i++) {
    final entry = streams[i];
    if (entry is! Map) continue;
    final source = stremioStreamToSource(
      Map<String, dynamic>.from(entry),
      providerId: providerName.toLowerCase(),
      providerName: providerName,
      index: i,
    );
    if (source != null) sources.add(source);
  }
  return sources;
}

StreamSource _oneWith(List<StreamSource> sources, String needle) =>
    sources.firstWhere(
      (source) => source.title.contains(needle),
      orElse: () => throw StateError('No hay fuente con "$needle"'),
    );

Finder _rowWithTitle(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(ListTile));

Future<void> _openPicker(
  WidgetTester tester,
  List<StreamSource> sources,
) async {
  tester.view.physicalSize = const Size(1200, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => unawaited(
                  showStreamPicker(
                    context,
                    result: StreamSearchResult(sources: sources),
                    title: 'MobLand S01E01',
                    onPlay: (_) async {},
                    onDownload: (_) async {},
                  ),
                ),
                child: const Text('PLAY'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('PLAY'));
  await tester.pumpAndSettle();
  expect(find.text('Select Stream'), findsOneWidget);
}

Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    280,
    scrollable: find.byType(Scrollable).last,
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Torrentio real: la fila MULTi no dice Español y el filtro deja '
      'la Castellano', (tester) async {
    final sources = _mapFixture('torrentio_mobland_s01e01.json', 'Torrentio');
    final multi = _oneWith(sources, 'MobLand.S01.MULTi.2160p');
    final spanish = _oneWith(sources, 'Castellano.1080p.x264');

    await _openPicker(tester, sources);
    await _scrollTo(tester, find.text(multi.displayName));

    final multiRow = _rowWithTitle(multi.displayName);
    expect(
      find.descendant(
        of: multiRow,
        matching: find.textContaining('Audio: Inglés, Polaco (Multi)'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: multiRow, matching: find.textContaining('Español')),
      findsNothing,
      reason: 'MULTi no declara español',
    );

    await tester.tap(find.text('Solo español'));
    await tester.pumpAndSettle();
    await _scrollTo(tester, find.text(spanish.displayName));

    expect(find.text(multi.displayName), findsNothing);
    expect(find.text(spanish.displayName), findsOneWidget);
    expect(
      find.descendant(
        of: _rowWithTitle(spanish.displayName),
        matching: find.textContaining('Audio: Español'),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'Comet real: la bandera 🇪🇸 es subtítulo y sobrevive al filtro',
    (tester) async {
      final sources = _mapFixture('comet_mobland_s01e01.json', 'Comet');
      final multi = _oneWith(sources, 'Stick.or.Twist.MULTi');
      final spanish = _oneWith(sources, 'Subtitulado.Esp');

      await _openPicker(tester, sources);

      final multiRow = _rowWithTitle(multi.displayName);
      expect(
        find.descendant(of: multiRow, matching: find.textContaining('Español')),
        findsNothing,
        reason: 'Comet MULTi no es español',
      );

      await tester.tap(find.text('Solo español'));
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.text(spanish.displayName));

      expect(find.text(multi.displayName), findsNothing);
      expect(find.text(spanish.displayName), findsOneWidget);
      expect(
        find.descendant(
          of: _rowWithTitle(spanish.displayName),
          matching: find.textContaining('Audio: sin datos · Subs: Español'),
        ),
        findsOneWidget,
        reason: 'la bandera 🇪🇸 describe subtítulos, no audio',
      );
    },
  );

  testWidgets(
    'anime real: japonés con subtítulos y DUB latino entran al filtro',
    (tester) async {
      final sources = _mapFixture(
        'animes_jujutsu_spanish_streams.json',
        'AnimES',
      );

      await _openPicker(tester, sources);

      expect(
        find.textContaining('Audio: Japonés · Subs: Español'),
        findsNWidgets(2),
      );
      expect(find.textContaining('Audio: Latino'), findsOneWidget);

      await tester.tap(find.text('Solo español'));
      await tester.pumpAndSettle();

      expect(find.text('Jujutsu Kaisen Ep. 1'), findsNWidgets(3));
      expect(find.text('No Spanish sources'), findsNothing);
    },
  );
}
