// El selector de fuentes es donde se decide si algo se puede ver: una fuente
// directa debe abrir el reproductor sin depender de debrid, y un torrent sin
// debrid debe explicar el motivo en vez de fallar.
import 'package:clubtivi/data/models/show.dart';
import 'package:clubtivi/data/models/stream_search_result.dart';
import 'package:clubtivi/data/models/stream_source.dart';
import 'package:clubtivi/data/services/debrid_settings.dart';
import 'package:clubtivi/features/shows/show_detail_screen.dart';
import 'package:clubtivi/features/shows/shows_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _movie = Show(
  traktId: 1,
  imdbId: 'tt1234567',
  title: 'Test Movie',
  year: 2024,
  type: ShowType.movie,
);

const _directStream = StreamSource(
  id: 'addon:1',
  providerId: 'addon',
  providerName: 'addon',
  kind: SourceKind.addon,
  title: 'Test.Movie.1080p.m3u8',
  url: 'https://example.com/movie.m3u8',
  quality: '1080p',
);

const _torrentStream = StreamSource(
  id: 'torrentio:abcdef0123456789abcdef0123456789abcdef01:0',
  providerId: 'torrentio',
  providerName: 'torrent',
  kind: SourceKind.torrent,
  title: 'Test.Movie.1080p.WEB-DL',
  quality: '1080p',
  magnetUrl: 'magnet:?xt=urn:btih:ABCDEF0123456789ABCDEF0123456789ABCDEF01',
  unavailableReason: kDebridRequiredReason,
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<Map<String, dynamic>? Function()> pumpScreen(
    WidgetTester tester,
    List<StreamSource> streams, {
    List<StreamProviderFailure> failures = const [],
  }) async {
    Map<String, dynamic>? playerExtra;

    final router = GoRouter(
      initialLocation: '/shows/1',
      routes: [
        GoRoute(
          path: '/shows/:id',
          builder: (context, state) => const ShowDetailScreen(
            traktId: 1,
            initialShow: _movie,
          ),
        ),
        GoRoute(
          path: '/player',
          builder: (context, state) {
            playerExtra = state.extra as Map<String, dynamic>?;
            return const Scaffold(body: Text('PLAYER'));
          },
        ),
        GoRoute(
          path: '/debrid-services',
          builder: (context, state) =>
              const Scaffold(body: Text('DEBRID SETTINGS')),
        ),
        GoRoute(
          path: '/stremio-addons',
          builder: (context, state) =>
              const Scaffold(body: Text('STREMIO ADDONS')),
        ),
      ],
    );

    // Se devuelve un lector del extra de navegación una vez montado el árbol.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          showDetailProvider.overrideWith(
            (ref, params) async => ShowDetail(show: _movie),
          ),
          resolveStreamProvider.overrideWith(
            (ref, params) async =>
                StreamSearchResult(sources: streams, failures: failures),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    return () => playerExtra;
  }

  testWidgets('una fuente directa abre el reproductor sin debrid',
      (tester) async {
    final extra = await pumpScreen(tester, const [_directStream]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();

    expect(find.text('Select Stream'), findsOneWidget);
    await tester.tap(find.text('Test.Movie.1080p.m3u8'));
    await tester.pumpAndSettle();

    expect(find.text('PLAYER'), findsOneWidget);
    expect(extra()!['streamUrl'], 'https://example.com/movie.m3u8');
  });

  testWidgets('un torrent sin debrid se explica y no navega', (tester) async {
    final extra = await pumpScreen(tester, const [_torrentStream]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();

    expect(find.textContaining('None of these sources can play'), findsOneWidget);
    expect(find.textContaining(kDebridRequiredReason), findsOneWidget);

    await tester.tap(find.text('Test.Movie.1080p.WEB-DL'));
    await tester.pumpAndSettle();

    expect(find.text('Source unavailable'), findsOneWidget);
    expect(find.text('PLAYER'), findsNothing);
    expect(extra(), isNull, reason: 'no se navegó al reproductor');

    await tester.tap(find.text('Open Settings'));
    await tester.pumpAndSettle();
    expect(find.text('DEBRID SETTINGS'), findsOneWidget);
  });

  testWidgets('un addon caído se explica junto a las fuentes que sí llegaron',
      (tester) async {
    await pumpScreen(
      tester,
      const [_directStream],
      failures: const [
        StreamProviderFailure(
          providerId: 'com.stremio.torrentio.addon',
          providerName: 'Torrentio',
          reason: 'El addon tardó demasiado en responder',
        ),
      ],
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Torrentio'), findsOneWidget);
    expect(
      find.textContaining('El addon tardó demasiado en responder'),
      findsOneWidget,
    );

    await tester.tap(find.text('Addons'));
    await tester.pumpAndSettle();
    expect(find.text('STREMIO ADDONS'), findsOneWidget);
  });
}
