// El cliente es la puerta de entrada de los addons: debe validar el manifest
// antes de aceptar una URL y convertir cualquier caída en un motivo legible,
// sin lanzar cosas raras hacia arriba.
import 'dart:io';
import 'dart:typed_data';

import 'package:clubtivi/data/datasources/remote/stremio_addon_client.dart';
import 'package:clubtivi/data/models/stremio_addon.dart';
import 'package:clubtivi/data/models/stream_source.dart';
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
  return StremioAddonClient(dio: Dio()..httpClientAdapter = adapter ?? _FakeAdapter(handler));
}

const _torrentio = InstalledAddon(
  url: 'https://torrentio.strem.fun',
  name: 'Torrentio',
  manifestId: 'com.stremio.torrentio.addon',
);

void main() {
  test('lee y valida el manifest real de Torrentio', () async {
    final adapter = _FakeAdapter(
      (_) async => _json(_fixture('torrentio_manifest.json')),
    );
    final client = _client((_) async => _json(''), adapter);

    final manifest = await client.fetchManifest('torrentio.strem.fun');

    expect(manifest.id, 'com.stremio.torrentio.addon');
    expect(manifest.name, 'Torrentio');
    expect(manifest.version, isNotEmpty);
    expect(manifest.types, contains('movie'));
    expect(manifest.types, contains('series'));
    expect(manifest.resources, contains('stream'),
        reason: 'el manifest real lista resources como objetos con name');
    expect(manifest.catalogs, isEmpty,
        reason: 'Torrentio real no declara catálogos');
    expect(manifest.supportsStreams, isTrue);
    expect(
      adapter.requestedUris.single,
      'https://torrentio.strem.fun/manifest.json',
      reason: 'se añade https:// y /manifest.json',
    );
  });

  test('lee catalogs y resources declarados como strings', () async {
    final client = _client((_) async => _json(_fixture('helloworld_manifest.json')));

    final manifest = await client.fetchManifest('https://addon.test');

    expect(manifest.id, 'org.stremio.helloworld');
    expect(manifest.resources, containsAll(<String>['catalog', 'stream']));
    expect(manifest.catalogs, hasLength(2));
    expect(manifest.catalogs.first.type, 'movie');
    expect(manifest.catalogs.first.id, 'helloworldmovies');
    expect(manifest.catalogs.last.name, isNull);
    expect(manifest.idPrefixes, ['tt']);
  });

  test('una URL que no es http(s) se rechaza antes de pedir nada', () async {
    final adapter = _FakeAdapter((_) async => _json('{}'));
    final client = _client((_) async => _json('{}'), adapter);

    await expectLater(
      client.fetchManifest('ftp://torrentio.strem.fun'),
      throwsA(
        isA<StremioAddonException>().having(
          (e) => e.message,
          'message',
          contains('no parece válida'),
        ),
      ),
    );
    expect(adapter.requestedUris, isEmpty);
  });

  test('un JSON que no es manifest explica qué falta', () async {
    final client = _client((_) async => _json('{"foo": "bar"}'));

    await expectLater(
      client.fetchManifest('https://ejemplo.test'),
      throwsA(
        isA<StremioAddonException>().having(
          (e) => e.message,
          'message',
          contains('"id"'),
        ),
      ),
    );
  });

  test('un addon que no ofrece streams se rechaza con su nombre', () async {
    final client = _client((_) async => _json(_fixture('opensubtitles_manifest.json')));

    await expectLater(
      client.fetchManifest('https://opensubtitles-v3.strem.io'),
      throwsA(
        isA<StremioAddonException>().having(
          (e) => e.message,
          'message',
          allOf(contains('OpenSubtitles v3'), contains('no ofrece streams')),
        ),
      ),
    );
  });

  test('un manifest sin types se rechaza', () async {
    final client = _client(
      (_) async => _json('{"id": "x", "name": "X", "version": "1", "resources": ["stream"]}'),
    );

    await expectLater(
      client.fetchManifest('https://ejemplo.test'),
      throwsA(
        isA<StremioAddonException>().having(
          (e) => e.message,
          'message',
          contains('types'),
        ),
      ),
    );
  });

  test('un HTTP 500 se reporta como tal', () async {
    // Cuerpo JSON válido con estado 500: es lo que devuelve un addon caído.
    final client = _client((_) async => _json('{"error": "boom"}', 500));

    await expectLater(
      client.fetchManifest('https://ejemplo.test'),
      throwsA(
        isA<StremioAddonException>().having(
          (e) => e.message,
          'message',
          contains('HTTP 500'),
        ),
      ),
    );
  });

  test('un timeout se reporta como lentitud, no como fallo genérico', () async {
    final client = _client(
      (options) async => throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionTimeout,
        message: 'timeout',
      ),
    );

    await expectLater(
      client.fetchManifest('https://ejemplo.test'),
      throwsA(
        isA<StremioAddonException>().having(
          (e) => e.message,
          'message',
          contains('tardó demasiado'),
        ),
      ),
    );
  });

  test('un addon inalcanzable se explica sin excepción de red', () async {
    final client = _client(
      (options) async => throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        message: 'no route',
      ),
    );

    await expectLater(
      client.fetchStreams(addon: _torrentio, type: 'movie', id: 'tt1254207'),
      throwsA(
        isA<StremioAddonException>().having(
          (e) => e.message,
          'message',
          contains('No se pudo conectar'),
        ),
      ),
    );
  });

  test('una respuesta ilegible no escapa como excepción de Dio', () async {
    final client = _client((_) async => _json('esto no es json'));

    await expectLater(
      client.fetchManifest('https://ejemplo.test'),
      throwsA(isA<StremioAddonException>()),
    );
  });

  test('traduce el payload real de Torrentio a StreamSource', () async {
    final adapter = _FakeAdapter(
      (_) async => _json(_fixture('torrentio_streams.json')),
    );
    final client = _client((_) async => _json(''), adapter);

    final sources = await client.fetchStreams(
      addon: _torrentio,
      type: 'movie',
      id: 'tt1254207',
    );

    expect(sources, hasLength(6));
    expect(sources.every((s) => s.kind == SourceKind.torrent), isTrue);
    expect(sources.every((s) => s.providerName == 'Torrentio'), isTrue);
    expect(sources.first.infoHash, 'f181e166e440b355ce73cc8b988f47ad7e8ea6ab');
    expect(
      adapter.requestedUris.single,
      'https://torrentio.strem.fun/stream/movie/tt1254207.json',
    );
  });

  test('un addon de url directa produce fuentes reproducibles', () async {
    final client = _client((_) async => _json(_fixture('direct_url_proxy_headers.json')));

    final sources = await client.fetchStreams(
      addon: _torrentio,
      type: 'movie',
      id: 'tt1254207',
    );

    expect(sources, hasLength(2));
    expect(sources.every((s) => s.isDirect), isTrue);
    expect(sources.first.headers, contains('Referer'));
  });

  test('streams: null devuelve lista vacía en vez de fallar', () async {
    final client = _client((_) async => _json('{"streams": null}'));

    expect(
      await client.fetchStreams(addon: _torrentio, type: 'movie', id: 'tt1'),
      isEmpty,
    );
  });

  test('una lista con basura deja solo lo que se puede leer', () async {
    final client = _client(
      (_) async => _json(
        '{"streams": ["nope", 42, null, {"name": "sin enlace"}, '
        '{"url": "https://example.com/movie.mp4", "name": "ok"}]}',
      ),
    );

    final sources = await client.fetchStreams(
      addon: _torrentio,
      type: 'movie',
      id: 'tt1',
    );

    expect(sources, hasLength(1));
    expect(sources.single.url, 'https://example.com/movie.mp4');
  });

  test('si "streams" no es lista se explica el motivo', () async {
    final client = _client((_) async => _json('{"streams": {"a": 1}}'));

    await expectLater(
      client.fetchStreams(addon: _torrentio, type: 'movie', id: 'tt1'),
      throwsA(
        isA<StremioAddonException>().having(
          (e) => e.message,
          'message',
          contains('forma inesperada'),
        ),
      ),
    );
  });

  test('una respuesta que no es objeto JSON se explica', () async {
    final client = _client((_) async => _json('[1, 2, 3]'));

    await expectLater(
      client.fetchStreams(addon: _torrentio, type: 'movie', id: 'tt1'),
      throwsA(
        isA<StremioAddonException>().having(
          (e) => e.message,
          'message',
          contains('no es JSON de streams'),
        ),
      ),
    );
  });
}
