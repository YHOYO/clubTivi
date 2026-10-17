// La ficha de un catálogo debe aprovechar lo que ya trae el catálogo, pedir
// los episodios al addon y resolver las fuentes con el id propio del título.
import 'package:clubtivi/data/models/stremio_addon.dart';
import 'package:clubtivi/data/models/stream_search_result.dart';
import 'package:clubtivi/data/models/stream_source.dart';
import 'package:clubtivi/data/repositories/shows_repository.dart';
import 'package:clubtivi/features/shows/shows_providers.dart';
import 'package:clubtivi/features/shows/stremio_meta_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _initial = StremioMeta(
  id: 'kitsu:7442',
  type: 'series',
  name: 'Attack on Titan',
  poster: 'https://img.test/poster.jpg',
  releaseInfo: '2013',
  description: 'Centuries ago, mankind was slaughtered.',
);

const _detail = StremioMeta(
  id: 'kitsu:7442',
  type: 'series',
  name: 'Attack on Titan',
  poster: 'https://img.test/poster.jpg',
  releaseInfo: '2013',
  imdbRating: '8.4',
  imdbId: 'tt2560140',
  genres: ['Action', 'Fantasy'],
  description: 'Centuries ago, mankind was slaughtered.',
  videos: [
    StremioVideo(
      id: 'kitsu:7442:1',
      season: 1,
      episode: 1,
      title: 'To You Two Thousand Years Later',
    ),
    StremioVideo(
      id: 'kitsu:7442:2',
      season: 1,
      episode: 2,
      title: 'That Day',
    ),
  ],
);

const _source = StreamSource(
  id: 'kitsu:url:0',
  providerId: 'community.anime.kitsu',
  providerName: 'Anime Kitsu',
  kind: SourceKind.addon,
  title: 'Direct source',
  url: 'https://cdn.test/episode.mp4',
);

Future<void> _pump(
  WidgetTester tester, {
  Object? metaError,
  StreamSearchResult? streams,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const StremioMetaScreen(
          initialMeta: _initial,
          addonUrl: 'https://anime-kitsu.strem.fun',
        ),
      ),
      GoRoute(
        path: '/player',
        builder: (context, state) => const Scaffold(body: Text('PLAYER')),
      ),
      GoRoute(
        path: '/debrid-services',
        builder: (context, state) =>
            const Scaffold(body: Text('DEBRID SETTINGS')),
      ),
      GoRoute(
        path: '/stremio-addons',
        builder: (context, state) => const Scaffold(body: Text('ADDONS')),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        stremioMetaProvider.overrideWith((ref, params) async {
          if (metaError != null) throw metaError;
          return _detail;
        }),
        addonStreamsProvider.overrideWith(
          (ref, params) async =>
              streams ?? const StreamSearchResult(sources: [_source]),
        ),
        showsRepositoryProvider.overrideWith((ref) async => ShowsRepository()),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('muestra la ficha completa con temporadas y episodios',
      (tester) async {
    await _pump(tester);

    expect(find.text('Attack on Titan'), findsOneWidget);
    expect(find.textContaining('2013'), findsOneWidget);
    expect(find.textContaining('Action'), findsOneWidget);
    expect(find.text('Season 1'), findsOneWidget);
    expect(find.textContaining('To You Two Thousand Years Later'),
        findsOneWidget);
    expect(find.textContaining('S01E02'), findsOneWidget);
  });

  testWidgets('reproducir un episodio abre el selector y luego el reproductor',
      (tester) async {
    await _pump(tester);

    await tester.tap(find.textContaining('To You Two Thousand Years Later'));
    await tester.pumpAndSettle();

    expect(find.text('Select Stream'), findsOneWidget);
    expect(find.textContaining('Attack on Titan S01E01'), findsOneWidget);

    await tester.tap(find.text('Direct source'));
    await tester.pumpAndSettle();

    expect(find.text('PLAYER'), findsOneWidget);
  });

  testWidgets('si el addon no publica ficha, se queda con el catálogo',
      (tester) async {
    await _pump(
      tester,
      metaError: const StremioAddonException('El addon respondió HTTP 500'),
    );

    expect(find.text('Attack on Titan'), findsOneWidget);
    expect(find.textContaining('No se pudo cargar la ficha completa'),
        findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Play'), findsOneWidget,
        reason: 'sin episodios se ofrece reproducir el título del catálogo');
  });
}
