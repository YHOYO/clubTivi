// Sin ningún servicio debrid habilitado la app debe seguir funcionando: las
// fuentes directas se reproducen y los torrents se marcan como no disponibles
// con un motivo, en vez de fallar al pulsar. Ahora todo pasa por StreamSource.
import 'dart:convert';

import 'package:clubtivi/data/datasources/remote/debrid_service.dart';
import 'package:clubtivi/data/datasources/remote/torrent_search_client.dart';
import 'package:clubtivi/data/models/language_preferences.dart';
import 'package:clubtivi/data/models/show.dart';
import 'package:clubtivi/data/models/stream_source.dart';
import 'package:clubtivi/data/repositories/shows_repository.dart';
import 'package:clubtivi/data/services/debrid_settings.dart';
import 'package:clubtivi/features/shows/shows_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeTorrentSearch extends TorrentSearchClient {
  _FakeTorrentSearch(this.results);

  final List<StreamSource> results;

  @override
  Future<List<StreamSource>> searchMovie(String imdbId) async => results;

  @override
  Future<List<StreamSource>> searchEpisode(
    String imdbId, {
    required int season,
    required int episode,
  }) async => results;
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

const _infoHash = 'ABCDEF0123456789ABCDEF0123456789ABCDEF01';

const _torrentSource = StreamSource(
  id: 'torrentio:abcdef0123456789abcdef0123456789abcdef01:0',
  providerId: 'torrentio',
  providerName: 'torrent',
  kind: SourceKind.torrent,
  title: 'Movie.2024.1080p.WEB-DL.Latino',
  infoHash: _infoHash,
  magnetUrl: 'magnet:?xt=urn:btih:$_infoHash',
  quality: '1080p',
  sizeBytes: 4 * 1024 * 1024 * 1024,
  seeds: 42,
  audioLanguages: {kLanguageSpanishLatin},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  ShowsRepository repository({
    List<DebridService> debrid = const [],
    List<StreamSource> sources = const [_torrentSource],
  }) {
    return ShowsRepository(
      debridServices: debrid,
      torrentSearch: _FakeTorrentSearch(sources),
    );
  }

  /// Solo interesan las fuentes: los fallos de proveedor tienen sus propias
  /// pruebas en `stremio_addon_resolution_test.dart`.
  Future<List<StreamSource>> sourcesOf(ShowsRepository repo) async =>
      (await repo.resolveStreams(imdbId: 'tt1234567')).sources;

  test(
    'sin debrid los torrents se listan como no disponibles con motivo',
    () async {
      final streams = await sourcesOf(repository());

      expect(streams, hasLength(1));
      final source = streams.single;
      expect(source.isAvailable, isFalse);
      expect(source.unavailableReason, kDebridRequiredReason);
      expect(source.locator, StreamLocator.magnet);
      expect(source.providerName, 'torrent');
      expect(source.kind, SourceKind.torrent);
      expect(source.audioLanguages, {kLanguageSpanishLatin});
    },
  );

  test('con debrid habilitado los torrents quedan disponibles', () async {
    final streams = await sourcesOf(repository(debrid: [_FakeDebrid()]));

    expect(streams.single.isAvailable, isTrue);
    expect(streams.single.unavailableReason, isNull);
  });

  test(
    'marca como cacheados los hashes del servicio en orden de prioridad',
    () async {
      final streams = await sourcesOf(
        repository(
          debrid: [
            _FakeDebrid(name: 'Second', cached: {_infoHash.toLowerCase()}),
          ],
        ),
      );

      final source = streams.single;
      expect(source.isCached, isTrue);
      expect(source.kind, SourceKind.debrid);
      expect(
        source.providerName,
        'torrent',
        reason: 'el debrid no oculta de qué addon viene la fuente',
      );
      expect(source.cachedBy, 'Second');
      expect(source.isAvailable, isTrue);
      expect(
        source.sizeBytes,
        4 * 1024 * 1024 * 1024,
        reason: 'enriquecer con debrid no pierde los metadatos',
      );
    },
  );

  test(
    'un servicio sin consulta de caché no tapa al siguiente',
    () async {
      // AllDebrid ya no tiene endpoint de disponibilidad: contesta vacío. El
      // bucle no debe pararse ahí o se perderían los hashes de Real-Debrid.
      final streams = await sourcesOf(
        repository(
          debrid: [
            _FakeDebrid(name: 'AllDebrid'),
            _FakeDebrid(name: 'Real-Debrid', cached: {_infoHash.toLowerCase()}),
          ],
        ),
      );

      expect(streams.single.isCached, isTrue);
      expect(streams.single.cachedBy, 'Real-Debrid');
    },
  );

  test('si el primer servicio falla al consultar, sigue disponible', () async {
    final streams = await sourcesOf(
      repository(
        debrid: [
          _FakeDebrid(name: 'Broken', failAvailability: true),
          _FakeDebrid(name: 'Healthy'),
        ],
      ),
    );

    expect(streams.single.isAvailable, isTrue);
  });

  test('una URL directa se reproduce sin debrid', () async {
    const source = StreamSource(
      id: 'addon:1',
      providerId: 'addon',
      providerName: 'direct',
      kind: SourceKind.addon,
      title: 'movie.m3u8',
      url: 'https://example.com/movie.m3u8',
    );

    expect(source.isDirect, isTrue);
    expect(source.locator, StreamLocator.url);
    expect(source.isAvailable, isTrue);
    expect(source.unavailableReason, isNull);
  });

  test('resolver un magnet sin debrid explica el motivo', () async {
    final repo = repository();

    await expectLater(
      repo.resolveMagnet(_torrentSource.magnetUrl!),
      throwsA(isA<DebridUnavailableException>()),
    );
  });

  test(
    'la resolución prueba los servicios en orden y cae al siguiente',
    () async {
      final repo = repository(
        debrid: [
          _FakeDebrid(name: 'Broken', failResolve: true),
          _FakeDebrid(name: 'Working'),
        ],
      );

      final resolved = await repo.resolveMagnet(_torrentSource.magnetUrl!);

      expect(resolved, isNotNull);
      expect(resolved!.source, 'Working');
      expect(repo.debridServiceNames, ['Broken', 'Working']);
    },
  );

  test(
    'el repositorio usa el estado habilitado y el orden, no el enum',
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
      expect(repo.debridServiceNames, [
        'Real-Debrid',
      ], reason: 'un servicio deshabilitado no resuelve');

      await notifier.setEnabled(DebridType.realDebrid, false);
      repo = await container.read(showsRepositoryProvider.future);
      expect(repo.hasDebrid, isFalse, reason: 'modo sin debrid');
    },
  );
}
