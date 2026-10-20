// Reabrir el release recordado no puede volver a buscar en addons: es la
// diferencia entre «empezar a ver en un segundo» y esperar el selector. Y un
// fallo del debrid no borra la memoria del release, sólo la retira tras varios.
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/datasources/local/playback_dao.dart';
import 'package:clubtivi/data/datasources/remote/debrid_service.dart';
import 'package:clubtivi/data/datasources/remote/torrent_hash_resolver.dart';
import 'package:clubtivi/data/datasources/remote/torrent_search_client.dart';
import 'package:clubtivi/data/models/playback_request.dart';
import 'package:clubtivi/data/models/show.dart';
import 'package:clubtivi/data/models/stream_source.dart';
import 'package:clubtivi/data/repositories/shows_repository.dart';
import 'package:clubtivi/data/services/release_memory.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const _request = PlaybackRequest(
  kind: PlaybackKind.series,
  mediaKey: 'imdb:tt7654321',
  season: 1,
  episode: 2,
  title: 'Carrie S01E02',
  sourceId: 'torrentio:abc:3',
);

const _release = StreamSource(
  id: 'torrentio:abc:3',
  providerId: 'torrentio',
  providerName: 'Torrentio',
  kind: SourceKind.torrent,
  title: 'Carrie.S01.1080p.WEB-DL',
  infoHash: 'abc123def',
  fileIdx: 3,
  quality: '1080p',
  sizeBytes: 1470000000,
  magnetUrl: 'magnet:?xt=urn:btih:abc123def',
);

/// Debrid de mentira: sólo sabe reabrir por hash y falla si le piden el flujo
/// completo del magnet, que es justo el que no debe usarse aquí.
class _FakeDebrid implements DebridService, TorrentHashResolver {
  bool fail = false;
  int hashCalls = 0;
  int magnetCalls = 0;
  String? lastHash;
  int? lastFileIdx;
  int? lastSeason;
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
    hashCalls++;
    lastHash = infoHash;
    lastFileIdx = fileIdx;
    lastSeason = season;
    lastEpisode = episode;
    if (fail) return null;
    onProgress?.call('ready', 100);
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
  }) async {
    magnetCalls++;
    throw StateError('el camino de memoria no debe pedir el magnet entero');
  }

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

/// Buscador que falla si alguien lo llama: el release recordado se reabre sin
/// pasar por los addons.
class _ForbiddenSearch extends TorrentSearchClient {
  int calls = 0;

  @override
  Future<List<StreamSource>> searchMovie(String imdbId) async {
    calls++;
    throw StateError('el buscador de addons no debe llamarse');
  }

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

void main() {
  late db.AppDatabase database;
  late PlaybackDao dao;
  late ReleaseMemory memory;
  late _FakeDebrid debrid;
  late _ForbiddenSearch search;
  late ShowsRepository repo;

  setUp(() {
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    dao = PlaybackDao(database);
    memory = ReleaseMemory(dao: dao);
    debrid = _FakeDebrid();
    search = _ForbiddenSearch();
    repo = ShowsRepository(debridServices: [debrid], torrentSearch: search);
  });

  tearDown(() => database.close());

  test('el mismo release se reabre por hash sin llamar al buscador', () async {
    await memory.remember(_request, _release);

    final reopened = await memory.reopen(
      repo,
      mediaKey: _request.mediaKey,
      season: _request.season,
      episode: _request.episode,
    );

    expect(reopened, isNotNull);
    expect(reopened!.url, 'https://debrid.test/dl/carrie-s01e02.mkv');
    expect(reopened.sourceId, ReleaseMemory.sourceIdFor(_release));
    expect(debrid.lastHash, 'abc123def');
    expect(debrid.lastFileIdx, 3, reason: 'se reabre el fichero del pack');
    expect(debrid.lastSeason, 1);
    expect(debrid.lastEpisode, 2);
    expect(debrid.magnetCalls, 0);
    expect(
      search.calls,
      0,
      reason: 'con el release recordado no se busca en addons',
    );
  });

  test('la huella guardada no incluye la URL resuelta', () async {
    await memory.remember(_request, _release);

    final row = await dao.sourceFor(
      _request.mediaKey,
      ReleaseMemory.sourceIdFor(_release),
    );
    expect(row, isNotNull);
    expect(row!.infoHash, 'abc123def');
    expect(row.fileIdx, 3);
    expect(row.quality, '1080p');
    expect(row.sourceId, isNot(contains('https')));
  });

  test('el mismo release dos veces no duplica la fila', () async {
    await memory.remember(_request, _release);
    await memory.remember(_request, _release);

    final rows = await database
        .customSelect('SELECT COUNT(*) AS c FROM playback_sources')
        .getSingle();
    expect(rows.read<int>('c'), 1);
  });

  test('un fallo no borra el release y sube fail_count', () async {
    await memory.remember(_request, _release);
    debrid.fail = true;

    final first = await memory.reopen(repo, mediaKey: _request.mediaKey);
    expect(first, isNull);

    final row = await dao.sourceFor(
      _request.mediaKey,
      ReleaseMemory.sourceIdFor(_release),
    );
    expect(row, isNotNull, reason: 'un fallo no borra la fila');
    expect(row!.failCount, 1);
  });

  test('tras el umbral el release deja de ofrecerse', () async {
    await memory.remember(_request, _release);
    debrid.fail = true;

    await memory.reopen(repo, mediaKey: _request.mediaKey);
    await memory.reopen(repo, mediaKey: _request.mediaKey);
    expect(debrid.hashCalls, 2);
    expect(await memory.recall(_request.mediaKey), isNull);

    // Ni siquiera se intenta: ya no se ofrece.
    final third = await memory.reopen(repo, mediaKey: _request.mediaKey);
    expect(third, isNull);
    expect(debrid.hashCalls, 2, reason: 'no se insiste con lo retirado');

    // La fila sigue ahí, con sus dos fallos.
    final row = await dao.sourceFor(
      _request.mediaKey,
      ReleaseMemory.sourceIdFor(_release),
    );
    expect(row, isNotNull);
    expect(row!.failCount, 2);
  });

  test('volver a elegir el release a mano lo devuelve a la lista', () async {
    await memory.remember(_request, _release);
    debrid.fail = true;
    await memory.reopen(repo, mediaKey: _request.mediaKey);
    await memory.reopen(repo, mediaKey: _request.mediaKey);
    expect(await memory.recall(_request.mediaKey), isNull);

    await memory.remember(_request, _release);
    expect(await memory.recall(_request.mediaKey), isNotNull);
  });

  test('sin debrid configurado no hay nada que reabrir', () async {
    await memory.remember(_request, _release);
    final sinDebrid = ShowsRepository(torrentSearch: search);

    expect(
      await memory.reopen(sinDebrid, mediaKey: _request.mediaKey),
      isNull,
    );
    expect(debrid.hashCalls, 0);
  });
}
