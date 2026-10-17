// La búsqueda de fuentes es donde se mezclan Torrentio y los addons: un addon
// caído o lento no puede tumbar la lista ni bloquear a los demás, y sin addons
// instalados nada de esto debe cambiar lo que ya había.
import 'package:clubtivi/data/datasources/remote/stremio_addon_client.dart';
import 'package:clubtivi/data/datasources/remote/torrent_search_client.dart';
import 'package:clubtivi/data/models/language_preferences.dart';
import 'package:clubtivi/data/models/stremio_addon.dart';
import 'package:clubtivi/data/models/stream_source.dart';
import 'package:clubtivi/data/repositories/shows_repository.dart';
import 'package:clubtivi/data/services/debrid_settings.dart';
import 'package:clubtivi/data/services/language_preferences_store.dart';
import 'package:clubtivi/data/services/stremio_addon_settings.dart';
import 'package:clubtivi/features/shows/shows_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _torrentioAddon = InstalledAddon(
  url: 'https://torrentio.strem.fun',
  name: 'Torrentio',
  manifestId: 'com.stremio.torrentio.addon',
);

const _slowAddon = InstalledAddon(
  url: 'https://slow.test',
  name: 'Slow Addon',
  manifestId: 'test.slow',
);

class _FakeSearch extends TorrentSearchClient {
  _FakeSearch(this.sources);

  final List<StreamSource> sources;

  @override
  Future<List<StreamSource>> searchMovie(String imdbId) async => sources;

  @override
  Future<List<StreamSource>> searchEpisode(
    String imdbId, {
    required int season,
    required int episode,
  }) async =>
      sources;
}

class _FakeStremioClient extends StremioAddonClient {
  _FakeStremioClient({this.sourcesByUrl = const {}, this.errorsByUrl = const {}});

  final Map<String, List<StreamSource>> sourcesByUrl;
  final Map<String, Object> errorsByUrl;
  final List<String> calls = [];

  @override
  Future<List<StreamSource>> fetchStreams({
    required InstalledAddon addon,
    required String type,
    required String id,
  }) async {
    calls.add('${addon.url}|$type|$id');
    final error = errorsByUrl[addon.url];
    if (error != null) throw error;
    return sourcesByUrl[addon.url] ?? const [];
  }
}

StreamSource _source(String id, String providerName, Set<String> audio) {
  return StreamSource(
    id: id,
    providerId: providerName,
    providerName: providerName,
    kind: SourceKind.torrent,
    title: 'Movie.2024.1080p.$id',
    quality: '1080p',
    seeds: 10,
    infoHash: id,
    magnetUrl: 'magnet:?xt=urn:btih:$id',
    audioLanguages: audio,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  ShowsRepository repository({
    List<InstalledAddon> addons = const [],
    _FakeStremioClient? client,
    List<StreamSource> torrentio = const [],
  }) {
    return ShowsRepository(
      torrentSearch: _FakeSearch(torrentio),
      stremioAddons: addons,
      stremioClient: client ?? _FakeStremioClient(),
    );
  }

  test('mezcla Torrentio con los addons y explica el que se cayó', () async {
    final client = _FakeStremioClient(
      sourcesByUrl: {
        _torrentioAddon.url: [_source('addon-1', 'Torrentio', const {})],
      },
      errorsByUrl: {
        _slowAddon.url: const StremioAddonException(
          'El addon tardó demasiado en responder',
        ),
      },
    );

    final result = await repository(
      addons: const [_torrentioAddon, _slowAddon],
      client: client,
      torrentio: [_source('tt-1', 'torrent', const {})],
    ).resolveStreams(imdbId: 'tt1234567');

    expect(result.sources.map((s) => s.id), containsAll(['tt-1', 'addon-1']));
    expect(result.failures, hasLength(1));
    expect(result.failures.single.providerName, 'Slow Addon');
    expect(result.failures.single.providerId, 'test.slow');
    expect(result.failures.single.reason, contains('tardó demasiado'));
    expect(client.calls, contains('https://torrentio.strem.fun|movie|tt1234567'));
    expect(client.calls, contains('https://slow.test|movie|tt1234567'));
  });

  test('un addon que revienta con algo inesperado tampoco tumba la búsqueda',
      () async {
    final client = _FakeStremioClient(errorsByUrl: {
      _slowAddon.url: StateError('boom'),
    });

    final result = await repository(
      addons: const [_slowAddon],
      client: client,
      torrentio: [_source('tt-1', 'torrent', const {})],
    ).resolveStreams(imdbId: 'tt1234567');

    expect(result.sources, hasLength(1));
    expect(result.failures.single.reason, 'El addon no pudo responder');
  });

  test('para series el addon recibe el id con temporada y episodio', () async {
    final client = _FakeStremioClient();

    await repository(addons: const [_torrentioAddon], client: client)
        .resolveStreams(imdbId: 'tt1234567', season: 1, episode: 2);

    expect(client.calls, ['https://torrentio.strem.fun|series|tt1234567:1:2']);
  });

  test('sin addons la ruta actual no cambia', () async {
    final client = _FakeStremioClient();
    final result = await repository(
      torrentio: [_source('tt-1', 'torrent', const {})],
    ).resolveStreams(imdbId: 'tt1234567');

    expect(result.sources, hasLength(1));
    expect(result.failures, isEmpty);
    expect(client.calls, isEmpty);
    expect(
      result.sources.single.unavailableReason,
      kDebridRequiredReason,
      reason: 'sin debrid ni addons el torrent sigue marcado como no disponible',
    );
  });

  test('los addons deshabilitados no llegan al repositorio', () async {
    final notifier = StremioAddonSettingsNotifier();
    await notifier.load();
    await notifier.save(
      const StremioManifest(
        id: 'com.stremio.torrentio.addon',
        name: 'Torrentio',
        version: '1.0.0',
        types: ['movie'],
        resources: ['stream'],
      ),
      _torrentioAddon.url,
    );
    await notifier.save(
      const StremioManifest(
        id: 'test.slow',
        name: 'Slow Addon',
        version: '1.0.0',
        types: ['movie'],
        resources: ['stream'],
      ),
      _slowAddon.url,
    );
    await notifier.setEnabled(_slowAddon.url, false);

    final container = ProviderContainer(overrides: [
      stremioAddonSettingsProvider.overrideWith((ref) => notifier),
    ]);
    addTearDown(container.dispose);

    final enabled = container.read(enabledStremioAddonsProvider);
    expect(enabled.map((a) => a.url), [_torrentioAddon.url]);

    final repo = repository(addons: enabled, client: _FakeStremioClient());
    expect(repo.stremioAddonUrls, [_torrentioAddon.url]);
    expect(repo.hasStremioAddons, isTrue);
  });

  test('el ranking por idioma manda también sobre fuentes de addon', () async {
    final preferences = LanguagePreferencesNotifier();
    await preferences.load();

    final repo = repository(
      addons: const [_torrentioAddon],
      client: _FakeStremioClient(sourcesByUrl: {
        _torrentioAddon.url: [
          _source('latino', 'Torrentio', const {kLanguageSpanishLatin}),
        ],
      }),
      torrentio: [
        StreamSource(
          id: 'english',
          providerId: 'torrentio',
          providerName: 'torrent',
          kind: SourceKind.torrent,
          title: 'Movie.2024.1080p.English',
          quality: '1080p',
          seeds: 500,
          infoHash: 'english',
          magnetUrl: 'magnet:?xt=urn:btih:english',
          audioLanguages: const {kLanguageEnglish},
        ),
      ],
    );

    final container = ProviderContainer(overrides: [
      languagePreferencesProvider.overrideWith((ref) => preferences),
      showsRepositoryProvider.overrideWith((ref) async => repo),
    ]);
    addTearDown(container.dispose);

    const params = StreamResolveParams('tt1234567');
    container.listen(resolveStreamProvider(params), (_, _) {});
    final result = await container.read(resolveStreamProvider(params).future);

    expect(result.sources.map((s) => s.id), ['latino', 'english'],
        reason: 'latino con menos seeds gana a inglés con más');
    expect(result.failures, isEmpty);
  });
}
