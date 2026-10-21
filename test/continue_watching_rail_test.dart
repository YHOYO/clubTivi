// La fila de «continuar viendo» es la superficie del progreso guardado: lo
// último visto, por dónde iba y la forma de quitarlo. Se prueba contra la base
// real en memoria y el mismo provider que usa la pantalla.
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/datasources/local/playback_dao.dart';
import 'package:clubtivi/data/datasources/remote/debrid_service.dart';
import 'package:clubtivi/data/datasources/remote/torrent_hash_resolver.dart';
import 'package:clubtivi/data/datasources/remote/torrent_search_client.dart';
import 'package:clubtivi/data/models/playback_request.dart';
import 'package:clubtivi/data/models/show.dart' show ResolvedStream;
import 'package:clubtivi/data/models/stream_source.dart';
import 'package:clubtivi/data/repositories/shows_repository.dart';
import 'package:clubtivi/features/player/player_service.dart';
import 'package:clubtivi/features/providers/provider_manager.dart';
import 'package:clubtivi/features/shows/continue_watching_rail.dart';
import 'package:clubtivi/features/shows/shows_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _FakeDebrid implements DebridService, TorrentHashResolver {
  String? hash;
  int? fileIdx;

  @override
  String get serviceName => 'FakeDebrid';

  @override
  Future<ResolvedStream?> resolveTorrentHash(
    String infoHash, {
    int? fileIdx,
    int? season,
    int? episode,
    void Function(String status, int progress)? onProgress,
  }) async {
    hash = infoHash;
    this.fileIdx = fileIdx;
    return const ResolvedStream(
      url: 'https://debrid.test/dl/carrie-s01e02.mkv',
      filename: 'carrie-s01e02.mkv',
      source: 'fake',
    );
  }

  @override
  Future<ResolvedStream?> resolveFromMagnet(
    String magnetLink, {
    void Function(String status, int progress)? onProgress,
  }) async => throw StateError('el magnet no se usa con un release recordado');

  @override
  Future<Map<String, List<DebridFile>>> checkInstantAvailability(
    List<String> hashes,
  ) async => {};

  @override
  Future<ResolvedStream> unrestrictLink(String link) async =>
      throw StateError('no se esperaba');

  @override
  Future<bool> verifyToken() async => true;
}

class _ForbiddenSearch extends TorrentSearchClient {
  int calls = 0;

  @override
  Future<List<StreamSource>> searchEpisode(
    String imdbId, {
    required int season,
    required int episode,
  }) async {
    calls++;
    throw StateError('no se vuelve a buscar si hay release recordado');
  }
}

class _SilentPlayer extends PlayerService {
  @override
  Future<void> stop() async {}
}

const _episode = PlaybackRequest(
  kind: PlaybackKind.series,
  mediaKey: 'imdb:tt7654321',
  season: 1,
  episode: 2,
  title: 'Carrie S01E02',
  sourceId: 'torrentio:abc:3',
);

void main() {
  late db.AppDatabase database;
  late PlaybackDao dao;

  setUp(() {
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    dao = PlaybackDao(database);
  });

  tearDown(() => database.close());

  Future<void> pumpRail(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(database)],
        child: const MaterialApp(home: Scaffold(body: ContinueWatchingRail())),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('sin nada visto no ocupa espacio', (tester) async {
    await pumpRail(tester);

    expect(find.byKey(const ValueKey('continue-watching')), findsNothing);
    expect(find.text('Continue watching'), findsNothing);
  });

  testWidgets('muestra el capítulo y cuánto queda', (tester) async {
    await dao.saveProgress(
      _episode,
      position: const Duration(minutes: 12),
      duration: const Duration(minutes: 45),
      mediaTitle: 'Carrie',
    );

    await pumpRail(tester);

    expect(find.text('Continue watching'), findsOneWidget);
    expect(find.text('Carrie'), findsOneWidget);
    expect(find.text('S1 · E2 · 33m left'), findsOneWidget);
  });

  testWidgets('olvidar el título limpia la fila y el release recordado', (
    tester,
  ) async {
    await dao.saveProgress(
      _episode,
      position: const Duration(minutes: 12),
      duration: const Duration(minutes: 45),
      mediaTitle: 'Carrie',
    );
    await dao.recordSource(
      _episode,
      providerId: 'torrentio',
      infoHash: 'ABCDEF',
      fileIdx: 3,
    );
    await pumpRail(tester);

    await tester.tap(
      find.byKey(const ValueKey('continue-remove-imdb:tt7654321')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Remove from Continue watching?'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('continue-watching')), findsNothing);
    expect(await dao.recentlyWatched(), isEmpty);
    expect(
      await dao.rememberedSource('imdb:tt7654321'),
      isNull,
      reason: 'olvidar la fila también olvida con qué release se abría',
    );
  });

  testWidgets('pulsar la tarjeta reabre el release sin buscar en addons', (
    tester,
  ) async {
    await dao.saveProgress(
      _episode,
      position: const Duration(minutes: 12),
      duration: const Duration(minutes: 45),
      mediaTitle: 'Carrie',
    );
    await dao.recordSource(
      _episode,
      providerId: 'torrentio',
      infoHash: 'ABCDEF',
      fileIdx: 3,
    );
    final debrid = _FakeDebrid();
    final search = _ForbiddenSearch();
    final repo = ShowsRepository(
      debridServices: [debrid],
      torrentSearch: search,
    );
    Map<String, dynamic>? playerExtra;
    final router = GoRouter(
      initialLocation: '/shows',
      routes: [
        GoRoute(
          path: '/shows',
          builder: (_, _) => const Scaffold(body: ContinueWatchingRail()),
        ),
        GoRoute(
          path: '/player',
          builder: (_, state) {
            playerExtra = state.extra as Map<String, dynamic>?;
            return const Scaffold(body: Text('PLAYER'));
          },
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(database),
          showsRepositoryProvider.overrideWith((ref) async => repo),
          playerServiceProvider.overrideWithValue(_SilentPlayer()),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('continue-card-imdb:tt7654321')),
    );
    await tester.pumpAndSettle();

    expect(find.text('PLAYER'), findsOneWidget);
    expect(
      playerExtra!['streamUrl'],
      'https://debrid.test/dl/carrie-s01e02.mkv',
    );
    final playback = playerExtra!['playback'] as PlaybackRequest;
    expect(playback.mediaKey, 'imdb:tt7654321');
    expect(playback.season, 1);
    expect(playback.episode, 2);
    expect(debrid.hash, 'ABCDEF');
    expect(debrid.fileIdx, 3);
    expect(search.calls, 0, reason: 'la memoria del release evita la búsqueda');
  });

  testWidgets('cancelar no borra nada', (tester) async {
    await dao.saveProgress(
      _episode,
      position: const Duration(minutes: 12),
      duration: const Duration(minutes: 45),
      mediaTitle: 'Carrie',
    );
    await pumpRail(tester);

    await tester.tap(
      find.byKey(const ValueKey('continue-remove-imdb:tt7654321')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Carrie'), findsOneWidget);
    expect(await dao.recentlyWatched(), hasLength(1));
  });
}
