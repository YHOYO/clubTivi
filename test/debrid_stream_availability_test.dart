// Sin ningún servicio debrid habilitado la app debe seguir funcionando: las
// fuentes directas se reproducen y los torrents se marcan como no disponibles
// con un motivo, en vez de fallar al pulsar.
import 'dart:convert';

import 'package:clubtivi/data/datasources/remote/debrid_service.dart';
import 'package:clubtivi/data/datasources/remote/debrid_client.dart';
import 'package:clubtivi/data/datasources/remote/torrent_search_client.dart';
import 'package:clubtivi/data/models/show.dart';
import 'package:clubtivi/data/repositories/shows_repository.dart';
import 'package:clubtivi/data/services/debrid_settings.dart';
import 'package:clubtivi/features/shows/shows_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeTorrentSearch extends TorrentSearchClient {
  _FakeTorrentSearch(this.results);

  final List<TorrentResult> results;

  @override
  Future<List<TorrentResult>> searchMovie(String imdbId) async => results;

  @override
  Future<List<TorrentResult>> searchEpisode(
    String imdbId, {
    required int season,
    required int episode,
  }) async =>
      results;
}

class _FakeDebrid implements DebridService {
  _FakeDebrid({
    this.name = 'FakeDebrid',
    this.cached = const {},
    this.failAvailability = false,
    this.failResolve = false,
  });

  final String name;
  final Set<String> cached;
  final bool failAvailability;
  final bool failResolve;

  @override
  String get serviceName => name;

  @override
  Future<Map<String, List<DebridFile>>> checkInstantAvailability(
    List<String> hashes,
  ) async {
    if (failAvailability) throw Exception('availability down');
    return {
      for (final hash in hashes)
        if (cached.contains(hash.toLowerCase()))
          hash.toLowerCase(): [
            const DebridFile(id: 0, filename: 'cached.mkv', filesize: 0),
          ],
    };
  }

  @override
  Future<ResolvedStream> unrestrictLink(String link) async =>
      ResolvedStream(url: link, filename: 'x.mkv', source: name);

  @override
  Future<ResolvedStream?> resolveFromMagnet(
    String magnetLink, {
    void Function(String status, int progress)? onProgress,
  }) async {
    if (failResolve) throw Exception('$name down');
    return ResolvedStream(
      url: 'https://cdn.example/$name.mkv',
      filename: 'x.mkv',
      source: name,
    );
  }

  @override
  Future<bool> verifyToken() async => true;
}

const _torrent = TorrentResult(
  title: 'Movie.2024.1080p.WEB-DL',
  name: 'Movie.2024.1080p.WEB-DL',
  infoHash: 'ABCDEF0123456789ABCDEF0123456789ABCDEF01',
  quality: '1080p',
  seeds: 42,
  magnetUrl: 'magnet:?xt=urn:btih:ABCDEF0123456789ABCDEF0123456789ABCDEF01',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  ShowsRepository repository({
    List<DebridService> debrid = const [],
    List<TorrentResult> torrents = const [_torrent],
  }) {
    return ShowsRepository(
      debridServices: debrid,
      torrentSearch: _FakeTorrentSearch(torrents),
    );
  }

  test('sin debrid los torrents se listan como no disponibles con motivo',
      () async {
    final streams = await repository().resolveStreams(imdbId: 'tt1234567');

    expect(streams, hasLength(1));
    expect(streams.single.isAvailable, isFalse);
    expect(streams.single.unavailableReason, kDebridRequiredReason);
    expect(streams.single.magnetUrl, isNotEmpty);
    expect(streams.single.source, 'torrent');
  });

  test('con debrid habilitado los torrents quedan disponibles', () async {
    final streams = await repository(debrid: [_FakeDebrid()])
        .resolveStreams(imdbId: 'tt1234567');

    expect(streams.single.isAvailable, isTrue);
    expect(streams.single.unavailableReason, isNull);
  });

  test('marca como cacheados los hashes del servicio en orden de prioridad',
      () async {
    final streams = await repository(debrid: [
      _FakeDebrid(name: 'Second', cached: {_torrent.infoHash.toLowerCase()}),
    ]).resolveStreams(imdbId: 'tt1234567');

    expect(streams.single.isCached, isTrue);
    expect(streams.single.source, contains('Second'));
    expect(streams.single.isAvailable, isTrue);
  });

  test('si el primer servicio falla al consultar, sigue disponible', () async {
    final streams = await repository(debrid: [
      _FakeDebrid(name: 'Broken', failAvailability: true),
      _FakeDebrid(name: 'Healthy'),
    ]).resolveStreams(imdbId: 'tt1234567');

    expect(streams.single.isAvailable, isTrue);
  });

  test('una URL directa se reproduce sin debrid', () async {
    const stream = ResolvedStream(
      url: 'https://example.com/movie.m3u8',
      filename: 'movie.m3u8',
      source: 'direct',
    );

    expect(stream.isDirect, isTrue);
    expect(stream.isAvailable, isTrue);
    expect(stream.unavailableReason, isNull);
  });

  test('resolver un magnet sin debrid explica el motivo', () async {
    final repo = repository();

    await expectLater(
      repo.resolveMagnet(_torrent.magnetUrl),
      throwsA(isA<DebridUnavailableException>()),
    );
  });

  test('la resolución prueba los servicios en orden y cae al siguiente',
      () async {
    final repo = repository(debrid: [
      _FakeDebrid(name: 'Broken', failResolve: true),
      _FakeDebrid(name: 'Working'),
    ]);

    final resolved = await repo.resolveMagnet(_torrent.magnetUrl);

    expect(resolved, isNotNull);
    expect(resolved!.source, 'Working');
    expect(repo.debridServiceNames, ['Broken', 'Working']);
  });

  test('el repositorio usa el estado habilitado y el orden, no el enum',
      () async {
    SharedPreferences.setMockInitialValues({
      debridConfigsKey: jsonEncode({
        'version': 2,
        'services': [
          {'type': 'allDebrid', 'token': 'ad', 'enabled': true},
          {'type': 'realDebrid', 'token': 'rd', 'enabled': true},
        ],
      }),
    });
    final notifier = DebridSettingsNotifier();
    await notifier.load();
    final container = ProviderContainer(
      overrides: [debridSettingsProvider.overrideWith((ref) => notifier)],
    );
    addTearDown(container.dispose);
    // En la app un widget mantiene vivo el provider; aquí hace falta el
    // listener para que el FutureProvider llegue a resolverse.
    container.listen(showsRepositoryProvider, (_, _) {});

    var repo = await container.read(showsRepositoryProvider.future);
    expect(repo.debridServiceNames, ['AllDebrid', 'Real-Debrid']);

    await notifier.setEnabled(DebridType.allDebrid, false);
    repo = await container.read(showsRepositoryProvider.future);
    expect(repo.debridServiceNames, ['Real-Debrid'],
        reason: 'un servicio deshabilitado no resuelve');

    await notifier.setEnabled(DebridType.realDebrid, false);
    repo = await container.read(showsRepositoryProvider.future);
    expect(repo.hasDebrid, isFalse, reason: 'modo sin debrid');
  });
}
