// El selector de fuentes es donde se decide si algo se puede ver: una fuente
// directa debe abrir el reproductor sin depender de debrid, y un torrent sin
// debrid debe explicar el motivo en vez de fallar.
import 'dart:async';

import 'package:clubtivi/data/datasources/remote/debrid_service.dart';
import 'package:clubtivi/data/models/language_preferences.dart';
import 'package:clubtivi/data/models/show.dart';
import 'package:clubtivi/data/models/stream_search_result.dart';
import 'package:clubtivi/data/models/stream_source.dart';
import 'package:clubtivi/data/repositories/shows_repository.dart';
import 'package:clubtivi/data/services/debrid_settings.dart';
import 'package:clubtivi/features/player/player_service.dart';
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

const _series = Show(
  traktId: 2,
  imdbId: 'tt7654321',
  title: 'Carrie',
  year: 2026,
  type: ShowType.show,
);

const _episode = Episode(
  season: 1,
  number: 1,
  title: 'FIRST PERIOD',
  runtime: 56,
);

/// Debrid de mentira que resuelve un magnet al instante y avisa del progreso,
/// para poder recorrer el camino completo hasta el reproductor sin red.
class _ResolvingDebrid implements DebridService {
  static const url = 'https://p1.alldebrid.com/dl/1234/carrie-s01e01.mkv';

  int resolves = 0;

  @override
  String get serviceName => 'AllDebrid';

  @override
  Future<Map<String, List<DebridFile>>> checkInstantAvailability(
    List<String> hashes,
  ) async => {};

  @override
  Future<ResolvedStream> unrestrictLink(String link) async =>
      ResolvedStream(url: url, filename: 'carrie.mkv', source: 'alldebrid');

  @override
  Future<ResolvedStream?> resolveFromMagnet(
    String magnetLink, {
    void Function(String status, int progress)? onProgress,
  }) async {
    resolves++;
    onProgress?.call('downloading', 75);
    return ResolvedStream(url: url, filename: 'carrie.mkv', source: 'alldebrid');
  }

  @override
  Future<bool> verifyToken() async => true;
}

const _directStream = StreamSource(
  id: 'addon:1',
  providerId: 'addon',
  providerName: 'addon',
  kind: SourceKind.addon,
  title: 'Test.Movie.1080p.m3u8',
  url: 'https://example.com/movie.m3u8',
  quality: '1080p',
  headers: {'Referer': 'https://cdn.test/'},
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

const _debridTorrent = StreamSource(
  id: 'torrentio:abcdef0123456789abcdef0123456789abcdef01:0',
  providerId: 'torrentio',
  providerName: 'torrent',
  kind: SourceKind.torrent,
  title: 'Test.Movie.1080p.WEB-DL',
  quality: '1080p',
  magnetUrl: 'magnet:?xt=urn:btih:ABCDEF0123456789ABCDEF0123456789ABCDEF01',
);

const _multiStream = StreamSource(
  id: 'torrentio:multi:0',
  providerId: 'torrentio',
  providerName: 'Torrentio',
  kind: SourceKind.torrent,
  title:
      'MobLand.S01.MULTi.2160p.WEB-DL.DV.HDR.H265.DDP5.1-K83\n'
      'MobLand.S01E01.MULTi.2160p.mkv\n👤 5 💾 6.21 GB ⚙️ EXT',
  quality: '4K',
  qualityDetail: 'HEVC · DV · WEB-DL',
  sizeBytes: 6668428275,
  seeds: 5,
  audioLanguages: {kLanguageEnglish, 'pl'},
  audioMode: 'MULTI',
  magnetUrl: 'magnet:?xt=urn:btih:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
);

const _spanishStream = StreamSource(
  id: 'torrentio:spanish:0',
  providerId: 'torrentio',
  providerName: 'Torrentio',
  kind: SourceKind.torrent,
  title:
      '(2025-05) MobLand (Tierra de Mafiosos) - Temporada 1\n'
      'MobLand (Tierra de Mafiosos) 1x01(Castellano.1080p.x264).mkv\n'
      '👤 26 💾 1.37 GB ⚙️ EXT\n🇪🇸',
  quality: '1080p',
  qualityDetail: 'H.264 · WEB-DL',
  sizeBytes: 1470000000,
  seeds: 26,
  audioLanguages: {kLanguageSpanish},
  magnetUrl: 'magnet:?xt=urn:btih:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
);

/// Registra si la ficha suelta el canal en vivo al pedir otra reproducción.
class _RecordingPlayerService extends PlayerService {
  int stops = 0;

  @override
  Future<void> stop() async {
    stops++;
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<Map<String, dynamic>? Function()> pumpScreen(
    WidgetTester tester,
    List<StreamSource> streams, {
    List<StreamProviderFailure> failures = const [],
    PlayerService? playerService,
    Show show = _movie,
    List<Season> seasons = const [],
    List<Episode> episodes = const [],
    ShowsRepository? repository,
    Future<StreamSearchResult>? pendingSearch,
  }) async {
    Map<String, dynamic>? playerExtra;

    final router = GoRouter(
      initialLocation: '/shows/1',
      routes: [
        GoRoute(
          path: '/shows/:id',
          builder: (context, state) =>
              ShowDetailScreen(traktId: 1, initialShow: show),
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
            (ref, params) async => ShowDetail(show: show, seasons: seasons),
          ),
          episodesProvider.overrideWith((ref, params) async => episodes),
          resolveStreamProvider.overrideWith(
            (ref, params) async =>
                pendingSearch ??
                StreamSearchResult(sources: streams, failures: failures),
          ),
          // El selector resuelve una URL directa sin debrid; el repositorio
          // real sólo aporta el resolvedor de magnets.
          showsRepositoryProvider.overrideWith(
            (ref) async => repository ?? ShowsRepository(),
          ),
          if (playerService != null)
            playerServiceProvider.overrideWithValue(playerService),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    return () => playerExtra;
  }

  testWidgets('una fuente directa abre el reproductor sin debrid', (
    tester,
  ) async {
    final extra = await pumpScreen(tester, const [_directStream]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();

    expect(find.text('Select Stream'), findsOneWidget);
    await tester.tap(find.text('Test.Movie.1080p.m3u8'));
    await tester.pumpAndSettle();

    expect(find.text('PLAYER'), findsOneWidget);
    expect(extra()!['streamUrl'], 'https://example.com/movie.m3u8');
    expect(extra()!['httpHeaders'], {
      'Referer': 'https://cdn.test/',
    }, reason: 'el reproductor necesita el Referer del CDN');
  });

  testWidgets('pulsar Play suelta el canal en vivo antes de resolver', (
    tester,
  ) async {
    final live = _RecordingPlayerService();
    addTearDown(live.dispose);
    await pumpScreen(tester, const [_directStream], playerService: live);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();

    expect(
      live.stops,
      1,
      reason:
          'el canal en vivo no debe seguir sonando mientras se busca'
          ' la fuente de la serie',
    );
    expect(find.text('Select Stream'), findsOneWidget);
  });

  testWidgets('un torrent sin debrid se explica y no navega', (tester) async {
    final extra = await pumpScreen(tester, const [_torrentStream]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('None of these sources can play'),
      findsOneWidget,
    );
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

  testWidgets(
    'la fila muestra idioma, tamaño, calidad y addon; MULTi no es español',
    (tester) async {
      await pumpScreen(tester, const [_multiStream, _spanishStream]);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();

      expect(find.text('Solo español'), findsOneWidget);
      expect(find.text('Español primero'), findsOneWidget);
      expect(find.textContaining('Audio: Español'), findsOneWidget);
      expect(
        find.textContaining('Audio: Inglés, Polaco (Multi)'),
        findsOneWidget,
        reason: 'MULTi no debe anunciarse como español',
      );
      expect(find.textContaining('6.2 GB'), findsOneWidget);
      expect(find.textContaining('1.4 GB'), findsOneWidget);
      expect(find.textContaining('HEVC · DV · WEB-DL'), findsOneWidget);
      expect(find.textContaining('Torrentio'), findsNWidgets(2));
    },
  );

  testWidgets('una fuente cacheada conserva el addon y muestra el debrid', (
    tester,
  ) async {
    final cached = _spanishStream.copyWith(
      kind: SourceKind.debrid,
      isCached: true,
      cachedBy: 'Real-Debrid',
    );
    await pumpScreen(tester, [cached]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Torrentio'),
      findsOneWidget,
      reason: 'cachear no borra el addon de origen',
    );
    expect(find.textContaining('Real-Debrid'), findsOneWidget);
  });

  testWidgets('Solo español quita la fila MULTi y deja la Castellano', (
    tester,
  ) async {
    await pumpScreen(tester, const [_multiStream, _spanishStream]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Solo español'));
    await tester.pumpAndSettle();

    expect(find.textContaining('MobLand.S01.MULTi'), findsNothing);
    expect(find.textContaining('Tierra de Mafiosos'), findsOneWidget);
    expect(find.textContaining('1 of 2 sources'), findsOneWidget);
  });

  testWidgets('Español primero sube la fila Castellano', (tester) async {
    await pumpScreen(tester, const [_multiStream, _spanishStream]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Español primero'));
    await tester.pumpAndSettle();

    final spanishTop = tester
        .getTopLeft(find.text(_spanishStream.displayName))
        .dy;
    final multiTop = tester.getTopLeft(find.text(_multiStream.displayName)).dy;
    expect(spanishTop, lessThan(multiTop));
  });

  testWidgets('sin fuentes españolas el filtro se puede deshacer', (
    tester,
  ) async {
    await pumpScreen(tester, const [_multiStream]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Solo español'));
    await tester.pumpAndSettle();

    expect(find.text('No Spanish sources'), findsOneWidget);
    await tester.tap(find.text('Show all'));
    await tester.pumpAndSettle();

    expect(find.textContaining('MobLand.S01.MULTi'), findsOneWidget);
    expect(find.text('No Spanish sources'), findsNothing);
  });

  testWidgets('pulsar un episodio muestra que se están buscando fuentes', (
    tester,
  ) async {
    final search = Completer<StreamSearchResult>();
    await pumpScreen(
      tester,
      const [],
      show: _series,
      seasons: const [Season(number: 1, episodeCount: 1)],
      episodes: const [_episode],
      pendingSearch: search.future,
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.textContaining('FIRST PERIOD'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('FIRST PERIOD'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.tap(find.textContaining('FIRST PERIOD'));
    await tester.pump();

    expect(
      find.byType(CircularProgressIndicator),
      findsOneWidget,
      reason: 'el clic debe tener respuesta visible en la fila pulsada',
    );

    search.complete(const StreamSearchResult(sources: []));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('No streams found'), findsOneWidget);
  });

  testWidgets(
    'un torrent con debrid acaba en el reproductor con la URL desbloqueada',
    (tester) async {
      final debrid = _ResolvingDebrid();
      final extra = await pumpScreen(
        tester,
        const [_debridTorrent],
        repository: ShowsRepository(debridServices: [debrid]),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Test.Movie.1080p.WEB-DL'));
      await tester.pumpAndSettle();

      expect(debrid.resolves, 1);
      expect(find.text('PLAYER'), findsOneWidget);
      expect(extra()!['streamUrl'], _ResolvingDebrid.url);
      expect(
        extra()!['httpHeaders'],
        isNot(contains('Referer')),
        reason: 'un enlace debrid no usa las cabeceras del addon',
      );
    },
  );

  testWidgets('un addon caído se explica junto a las fuentes que sí llegaron', (
    tester,
  ) async {
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
