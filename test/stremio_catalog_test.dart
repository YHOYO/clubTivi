// Los catálogos son la otra mitad del protocolo: un addon de sólo catálogo
// (Kitsu) debe aceptarse, la URL de cada fila debe llevar sus extras y una
// ficha incompleta no puede romper el resto del catálogo.
import 'dart:io';
import 'dart:typed_data';

import 'package:clubtivi/data/datasources/remote/stremio_addon_client.dart';
import 'package:clubtivi/data/models/show.dart';
import 'package:clubtivi/data/models/stremio_addon.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

String _fixture(String name) =>
    File('test/fixtures/stremio/$name').readAsStringSync();

ResponseBody _json(String body, [int status = 200]) => ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;
  final List<String> requestedUris = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requestedUris.add(options.uri.toString());
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

StremioAddonClient _client(
  Future<ResponseBody> Function(RequestOptions options) handler, [
  _FakeAdapter? adapter,
]) {
  return StremioAddonClient(
    dio: Dio()..httpClientAdapter = adapter ?? _FakeAdapter(handler),
  );
}

const _kitsu = InstalledAddon(
  url: 'https://anime-kitsu.strem.fun',
  name: 'Anime Kitsu',
  manifestId: 'community.anime.kitsu',
);

void main() {
  test('un addon de sólo catálogo se acepta y sus extras se leen', () async {
    final client = _client((_) async => _json(_fixture('anime_kitsu_manifest.json')));

    final manifest = await client.fetchManifest('anime-kitsu.strem.fun');

    expect(manifest.supportsStreams, isFalse);
    expect(manifest.supportsCatalogs, isTrue);
    expect(manifest.isUsable, isTrue);
    expect(manifest.catalogs, hasLength(3));

    final top = manifest.catalogs[1];
    expect(top.needsSearch, isFalse);
    expect(top.genreExtra?.isRequired, isTrue);
    expect(top.genreExtra?.options, ['Action', 'Comedy']);
    expect(manifest.catalogs.last.needsSearch, isTrue,
        reason: 'un catálogo de sólo búsqueda no se puede pintar como fila');
    expect(manifest.catalogs.last.canBrowse, isFalse);
    expect(top.canBrowse, isTrue,
        reason: 'un género obligatorio sí se puede rellenar');

    const needsUnknownExtra = StremioCatalog(
      type: 'series',
      id: 'calendar-videos',
      extra: [StremioCatalogExtra(name: 'calendarVideosIds', isRequired: true)],
    );
    expect(needsUnknownExtra.canBrowse, isFalse,
        reason: 'no se puede inventar el id de un extra obligatorio');
  });

  test('la URL del catálogo lleva género y página, y la respuesta se filtra',
      () async {
    final adapter = _FakeAdapter(
      (_) async => _json(_fixture('kitsu_catalog.json')),
    );
    final client = _client((_) async => _json(''), adapter);

    final metas = await client.fetchCatalog(
      addon: _kitsu,
      catalog: const StremioCatalog(
        type: 'anime',
        id: 'kitsu-anime-top',
        name: 'Kitsu Top',
      ),
      genre: 'Action',
      skip: 20,
    );

    expect(
      adapter.requestedUris.single,
      'https://anime-kitsu.strem.fun/catalog/anime/kitsu-anime-top/'
      'genre=Action&skip=20.json',
    );
    expect(metas, hasLength(2),
        reason: 'las entradas sin id o que no son mapas se descartan');
    expect(metas.first.id, 'kitsu:7442');
    expect(metas.first.name, 'Attack on Titan');
    expect(metas.first.year, 2013);
    expect(metas.first.rating, 8.4);
  });

  test('los ids con caracteres especiales se codifican en la ruta', () async {
    final adapter = _FakeAdapter((_) async => _json('{"metas": []}'));
    final client = _client((_) async => _json(''), adapter);

    await client.fetchCatalog(
      addon: _torrentioLike,
      catalog: const StremioCatalog(type: 'Anime', id: 'animeav1|genres'),
      genre: 'accion',
    );

    expect(
      adapter.requestedUris.single,
      'https://addon.test/catalog/Anime/animeav1%7Cgenres/genre=accion.json',
    );
  });

  test('"metas" con forma inesperada se explica', () async {
    final client = _client((_) async => _json('{"metas": {"a": 1}}'));

    await expectLater(
      client.fetchCatalog(
        addon: _kitsu,
        catalog: const StremioCatalog(type: 'anime', id: 'x'),
      ),
      throwsA(
        isA<StremioAddonException>().having(
          (e) => e.message,
          'message',
          contains('forma inesperada'),
        ),
      ),
    );
  });

  test('la ficha trae episodios, géneros e id de IMDB', () async {
    final adapter = _FakeAdapter((_) async => _json(_fixture('kitsu_meta.json')));
    final client = _client((_) async => _json(''), adapter);

    final meta = await client.fetchMeta(
      addon: _kitsu,
      type: 'series',
      id: 'kitsu:7442',
    );

    expect(meta, isNotNull);
    expect(meta!.name, 'Attack on Titan');
    expect(meta.imdbId, 'tt2560140');
    expect(meta.genres, ['Action', 'Fantasy']);
    expect(meta.runtimeMinutes, 24);
    expect(meta.videos, hasLength(2));
    expect(meta.videos.first.id, 'kitsu:7442:1');
    expect(meta.videos.first.code, 'S01E01');
    expect(meta.seasons, [1]);
    expect(
      adapter.requestedUris.single,
      'https://anime-kitsu.strem.fun/meta/series/kitsu:7442.json',
    );

    final show = meta.toShow();
    expect(show.type, ShowType.show);
    expect(show.imdbId, 'tt2560140');
    expect(show.year, 2013);
  });

  test('sin "meta" la ficha es null y no un fallo', () async {
    final client = _client((_) async => _json('{"meta": null}'));

    expect(
      await client.fetchMeta(addon: _kitsu, type: 'series', id: 'kitsu:1'),
      isNull,
    );
  });

  test('una ficha incompleta se explica', () async {
    final client = _client((_) async => _json('{"meta": {"name": "X"}}'));

    await expectLater(
      client.fetchMeta(addon: _kitsu, type: 'series', id: 'kitsu:1'),
      throwsA(
        isA<StremioAddonException>().having(
          (e) => e.message,
          'message',
          contains('ficha incompleta'),
        ),
      ),
    );
  });
}

const _torrentioLike = InstalledAddon(
  url: 'https://addon.test',
  name: 'Addon',
  manifestId: 'test.addon',
);
