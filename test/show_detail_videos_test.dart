// La ficha debe enseñar TODOS los vídeos que publica el título y llevar
// cualquiera de ellos al reproductor de la app, no a un único tráiler en el
// navegador.
import 'package:clubtivi/data/models/media_video.dart';
import 'package:clubtivi/data/models/show.dart';
import 'package:clubtivi/features/shows/show_detail_screen.dart';
import 'package:clubtivi/features/shows/shows_providers.dart';
import 'package:clubtivi/features/shows/trailer_player_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _trailer = MediaVideo(
  name: 'Trailer',
  key: 'trailerKey',
  kind: VideoKind.trailer,
  official: true,
  language: 'es',
);
const _teaser = MediaVideo(
  name: 'Teaser',
  key: 'teaserKey',
  kind: VideoKind.teaser,
  language: 'en',
);
const _clip = MediaVideo(name: 'Escena', key: 'clipKey', kind: VideoKind.clip);

final _show = Show(
  traktId: 42,
  tmdbId: 42,
  imdbId: 'tt0042',
  title: 'Cars',
  year: 2006,
  overview: 'Un coche de carreras.',
  type: ShowType.movie,
  videos: const [_trailer, _teaser, _clip],
);

Future<void> _pump(WidgetTester tester, {Show? show}) async {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) =>
            ShowDetailScreen(traktId: 42, initialShow: show ?? _show),
      ),
      GoRoute(
        path: '/trailer',
        builder: (context, state) {
          final args = state.extra as TrailerRouteArgs;
          return Scaffold(body: Text('TRAILER ${args.video.key}'));
        },
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        showDetailProvider.overrideWith(
          (ref, params) async => ShowDetail(show: show ?? _show),
        ),
        episodesProvider.overrideWith((ref, params) async => const []),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lista todos los vídeos del título', (tester) async {
    await _pump(tester);

    expect(find.text('Vídeos (3)'), findsOneWidget);
    expect(find.text('Tráiler oficial'), findsWidgets);
    expect(find.text('Teaser'), findsOneWidget);
    expect(find.text('Escena'), findsOneWidget);
    expect(find.text('Tráiler oficial · ES'), findsOneWidget);
    expect(find.text('Teaser · EN'), findsOneWidget);
  });

  testWidgets('el botón principal abre el tráiler más relevante', (
    tester,
  ) async {
    await _pump(tester);

    await tester.tap(find.text('Tráiler oficial').first);
    await tester.pumpAndSettle();

    expect(find.text('TRAILER trailerKey'), findsOneWidget);
  });

  testWidgets('se puede elegir cualquier vídeo de la lista', (tester) async {
    await _pump(tester);

    await tester.tap(find.text('Escena'));
    await tester.pumpAndSettle();

    expect(find.text('TRAILER clipKey'), findsOneWidget);
  });

  testWidgets('sin vídeos no aparece la sección', (tester) async {
    await _pump(
      tester,
      show: Show(traktId: 7, title: 'Sin vídeos', type: ShowType.movie),
    );

    expect(find.textContaining('Vídeos'), findsNothing);
    expect(find.textContaining('Tráiler'), findsNothing);
  });
}
