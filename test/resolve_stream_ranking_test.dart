// El provider de fuentes es el punto de composición: repositorio + ranking con
// el orden persistido. Este test fija que las preferencias guardadas mandan y
// que la pantalla sigue recibiendo como máximo 10 fuentes.
import 'dart:convert';

import 'package:clubtivi/data/datasources/remote/torrent_search_client.dart';
import 'package:clubtivi/data/models/language_preferences.dart';
import 'package:clubtivi/data/models/stream_source.dart';
import 'package:clubtivi/data/repositories/shows_repository.dart';
import 'package:clubtivi/data/services/language_preferences_store.dart';
import 'package:clubtivi/features/shows/shows_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeSearch extends TorrentSearchClient {
  _FakeSearch(this.sources);

  final List<StreamSource> sources;

  @override
  Future<List<StreamSource>> searchMovie(String imdbId) async => sources;
}

StreamSource _source(String id, Set<String> audio, {int seeds = 10}) {
  return StreamSource(
    id: id,
    providerId: 'torrentio',
    providerName: 'torrent',
    kind: SourceKind.torrent,
    title: 'Movie.2024.1080p.$id',
    quality: '1080p',
    seeds: seeds,
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

  test('el orden persistido decide la primera fuente', () async {
    SharedPreferences.setMockInitialValues({
      languagePreferencesKey: jsonEncode({
        'audioOrder': [kLanguageEnglish, kLanguageSpanishLatin],
        'subtitleOrder': [kLanguageEnglish],
      }),
    });
    final preferences = LanguagePreferencesNotifier();
    await preferences.load();

    final repository = ShowsRepository(
      torrentSearch: _FakeSearch([
        _source('latino', {kLanguageSpanishLatin}, seeds: 500),
        _source('english', {kLanguageEnglish}, seeds: 2),
      ]),
    );

    final container = ProviderContainer(
      overrides: [
        languagePreferencesProvider.overrideWith((ref) => preferences),
        showsRepositoryProvider.overrideWith((ref) async => repository),
      ],
    );
    addTearDown(container.dispose);

    const params = StreamResolveParams('tt1234567');
    container.listen(resolveStreamProvider(params), (_, _) {});
    final sources = await container.read(resolveStreamProvider(params).future);

    expect(sources.map((s) => s.id).toList(), ['english', 'latino']);
  });

  test('la pantalla recibe como máximo 10 fuentes', () async {
    final preferences = LanguagePreferencesNotifier();
    await preferences.load();

    final repository = ShowsRepository(
      torrentSearch: _FakeSearch([
        for (var i = 0; i < 13; i++)
          _source('s$i', {kLanguageSpanishLatin}, seeds: i),
      ]),
    );

    final container = ProviderContainer(
      overrides: [
        languagePreferencesProvider.overrideWith((ref) => preferences),
        showsRepositoryProvider.overrideWith((ref) async => repository),
      ],
    );
    addTearDown(container.dispose);

    const params = StreamResolveParams('tt1234567');
    container.listen(resolveStreamProvider(params), (_, _) {});
    final sources = await container.read(resolveStreamProvider(params).future);

    expect(sources, hasLength(10));
    expect(sources.first.id, 's12', reason: 'más seeds primero');
  });
}
