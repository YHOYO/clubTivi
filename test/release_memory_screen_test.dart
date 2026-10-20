// La ficha no debe abrir el selector cuando ya sabe con qué release se vio:
// pulsar el episodio tiene que ir directo al reproductor, sin consultar addons.
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/datasources/local/playback_dao.dart';
import 'package:clubtivi/data/datasources/remote/debrid_service.dart';
import 'package:clubtivi/data/datasources/remote/torrent_hash_resolver.dart';
import 'package:clubtivi/data/datasources/remote/torrent_search_client.dart';
import 'package:clubtivi/data/models/playback_request.dart';
import 'package:clubtivi/data/models/show.dart';
import 'package:clubtivi/data/models/stream_search_result.dart';
import 'package:clubtivi/data/models/stream_source.dart';
import 'package:clubtivi/data/repositories/shows_repository.dart';
import 'package:clubtivi/data/services/release_memory.dart';
import 'package:clubtivi/features/player/player_service.dart';
import 'package:clubtivi/features/providers/provider_manager.dart'
    show databaseProvider;
import 'package:clubtivi/features/shows/show_detail_screen.dart';
import 'package:clubtivi/features/shows/shows_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _series = Show(
  traktId: 2,
  imdbId: 'tt7654321',
  title: 'Carrie',
  year: 2026,
  type: ShowType.show,
);

const _episode2 = Episode(
  season: 1,
  number: 2,
  title: 'SECOND PERIOD',
  runtime: 50,
);

const _request = PlaybackRequest(
  kind: PlaybackKind.series,
  mediaKey: 'imdb:tt7654321',
  season: 1,
  episode: 2,
  title: 'Carrie S01E02',
  sourceId: 'torrentio:abc123def:3',
);

const _release = StreamSource(
  id: 'torrentio:abc123def:3',
  providerId: 'torrentio',
  providerName: 'Torrentio',
  kind: SourceKind.torrent,
  title: 'Carrie.S01.1080p.WEB-DL',
  infoHash: 'abc123def',
  fileIdx: 3,
  quality: '1080p',
  magnetUrl: 'magnet:?xt=urn:btih:abc123def',
);

class _FakeDebrid implements DebridService, TorrentHashResolver {
  String? lastHash;
  int? lastFileIdx;
  int? lastEpisode;

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
    lastHash = infoHash;
    lastFileIdx = fileIdx;
    lastEpisode = episode;
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
  }) async =>
      throw StateError('no se esperaba resolver el magnet entero');

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
    throw StateError('el buscador de addons no debe llamarse');
  }
}

class _SilentPlayer extends PlayerService {
  @override
  Future<void> stop() async {}
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('el episodio recordado va al reproductor sin abrir el selector',
      (tester) async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final debrid = _FakeDebrid();
    final search = _ForbiddenSearch();
    final repo = ShowsRepository(debridServices: [debrid], torrentSearch: search);
    // Se dejó guardado que este capítulo se vio con ese release.
    await ReleaseMemory(dao: PlaybackDao(database)).remember(_request, _release);

    Map<String, dynamic>? playerExtra;
    var sourceSearches = 0;

    final router = GoRouter(
      initialLocation: '/shows/2',
      routes: [
        GoRoute(
          path: '/shows/:id',
          builder: (context, state) =>
              ShowDetailScreen(traktId: 2, initialShow: _series),
        ),
        GoRoute(
          path: '/player',
          builder: (context, state) {
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
          showDetailProvider.overrideWith(
            (ref, params) async => ShowDetail(
              show: _series,
              seasons: const [Season(number: 1, episodeCount: 2)],
            ),
          ),
          episodesProvider.overrideWith((ref, params) async => [_episode2]),
          resolveStreamProvider.overrideWith((ref, params) async {
            sourceSearches++;
            return const StreamSearchResult(sources: []);
          }),
          showsRepositoryProvider.overrideWith((ref) async => repo),
          playerServiceProvider.overrideWithValue(_SilentPlayer()),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.textContaining('SECOND PERIOD'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('SECOND PERIOD'));
    await tester.pumpAndSettle();

    expect(find.text('PLAYER'), findsOneWidget);
    expect(find.text('Select Stream'), findsNothing);
    expect(sourceSearches, 0, reason: 'no se vuelve a buscar en addons');
    expect(search.calls, 0);
    expect(debrid.lastHash, 'abc123def');
    expect(debrid.lastFileIdx, 3);
    expect(debrid.lastEpisode, 2);
    expect(playerExtra!['streamUrl'], 'https://debrid.test/dl/carrie-s01e02.mkv');
    final playback = playerExtra!['playback'] as PlaybackRequest;
    expect(playback.mediaKey, 'imdb:tt7654321');
    expect(playback.episode, 2);
    expect(
      playback.sourceId,
      ReleaseMemory.sourceIdFor(_release),
      reason: 'el reproductor recibe el id del release recordado',
    );
  });
}
