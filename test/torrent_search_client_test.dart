// El mapeo de Torrentio es la puerta de entrada de las fuentes de hoy: debe
// producir StreamSource con idiomas, tamaño y calidad ya interpretados.
import 'dart:typed_data';

import 'package:clubtivi/data/datasources/remote/torrent_search_client.dart';
import 'package:clubtivi/data/models/language_preferences.dart';
import 'package:clubtivi/data/models/stream_source.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.body);

  final String body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('convierte la respuesta de Torrentio en StreamSource', () async {
    const json = '''
{
  "streams": [
    {
      "name": "Torrentio\\n1080p",
      "title": "Movie.2024.1080p.WEB-DL.Latino.\\n👤 120 💾 4.2 GB",
      "infoHash": "ABCDEF0123456789ABCDEF0123456789ABCDEF01",
      "fileIdx": 3
    },
    {
      "name": "Torrentio\\n4K",
      "title": "Movie.2024.2160p.UHD.BluRay.Castellano.\\n👤 8 💾 20 GB",
      "url": "magnet:?xt=urn:btih:1111111111111111111111111111111111111111&dn=Movie"
    },
    {
      "name": "Torrentio\\n720p",
      "title": "Sin hash, se descarta",
      "url": "https://example.com/not-a-torrent"
    }
  ]
}
''';

    final dio = Dio()..httpClientAdapter = _FakeAdapter(json);
    final client = TorrentSearchClient(dio: dio);

    final sources = await client.searchMovie('tt1234567');

    expect(sources, hasLength(2));

    final first = sources.first;
    expect(first.kind, SourceKind.torrent);
    expect(first.providerId, 'torrentio');
    expect(first.providerName, 'torrent');
    expect(first.locator, StreamLocator.magnet);
    expect(first.infoHash, 'ABCDEF0123456789ABCDEF0123456789ABCDEF01');
    expect(first.fileIdx, 3);
    expect(first.title, contains('Movie.2024.1080p.WEB-DL.Latino'));
    expect(first.quality, '1080p');
    expect(first.seeds, 120);
    expect(first.sizeBytes, closeTo(4.2 * 1024 * 1024 * 1024, 1));
    expect(first.audioLanguages, {kLanguageSpanishLatin});
    expect(first.magnetUrl, contains('ABCDEF0123456789ABCDEF0123456789ABCDEF01'));
    expect(first.isAvailable, isTrue);

    final second = sources.last;
    expect(second.infoHash, '1111111111111111111111111111111111111111');
    expect(second.audioLanguages, {kLanguageSpanish});
    expect(second.quality, '4K');
    expect(second.seeds, 8);
  });

  test('si Torrentio falla devuelve una lista vacía, no una excepción',
      () async {
    final dio = Dio()..httpClientAdapter = _FakeAdapter('not json');
    final client = TorrentSearchClient(dio: dio);

    expect(await client.searchMovie('tt1234567'), isEmpty);
  });
}
