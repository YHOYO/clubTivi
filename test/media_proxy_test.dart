// El proxy local es la última milla de las fuentes de addon: si no reenvía el
// Referer, no reescribe la lista HLS o no deja pasar Range, el stream no
// arranca. Se prueba contra servidores HTTP reales en loopback, no dobles.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clubtivi/features/player/media_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _Route = Future<void> Function(HttpRequest request);

void main() {
  late HttpServer origin;
  late Map<String, _Route> routes;
  late List<HttpRequest> seen;

  setUp(() async {
    routes = {};
    seen = [];
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((request) async {
      seen.add(request);
      final route = routes[request.uri.path];
      if (route == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      await route(request);
    });
  });

  tearDown(() async {
    await origin.close(force: true);
  });

  String originUrl(String path) => 'http://127.0.0.1:${origin.port}$path';

  test(
    'un origen que exige Referer falla directo y responde por el proxy',
    () async {
      routes['/movie.mp4'] = (request) => _serve(request, const [
        1,
        2,
        3,
        4,
      ], referer: 'https://source.example/');
      final target = originUrl('/movie.mp4');

      final direct = await _fetch(target);
      expect(
        direct.status,
        HttpStatus.forbidden,
        reason: 'sin el proxy el origen rechaza la petición',
      );

      final proxy = MediaProxy();
      final local = await proxy.start(
        target,
        headers: {
          'Referer': 'https://source.example/',
          'User-Agent': 'ClubTivi/0.4',
        },
      );
      expect(local, isNotNull);

      final proxied = await _fetch(local!);
      expect(proxied.status, HttpStatus.ok);
      expect(proxied.body, const [1, 2, 3, 4]);
      expect(seen, hasLength(2));
      expect(seen.last.headers.value('referer'), 'https://source.example/');
      expect(seen.last.headers.value('user-agent'), 'ClubTivi/0.4');

      await proxy.stop();
    },
  );

  test(
    'Range viaja de extremo a extremo: 206 con Content-Range del origen',
    () async {
      final payload = List<int>.generate(64, (i) => i);
      routes['/video.mp4'] = (request) =>
          _serve(request, payload, referer: 'https://source.example/');
      final proxy = MediaProxy();
      final local = await proxy.start(
        originUrl('/video.mp4'),
        headers: {'Referer': 'https://source.example/'},
      );

      final ranged = await _fetch(local!, headers: {'Range': 'bytes=10-19'});

      expect(ranged.status, HttpStatus.partialContent);
      expect(ranged.headers['content-range'], 'bytes 10-19/64');
      expect(ranged.headers['accept-ranges'], 'bytes');
      expect(ranged.headers['content-length'], '10');
      expect(ranged.body, payload.sublist(10, 20));
      expect(seen.single.headers.value('range'), 'bytes=10-19');

      await proxy.stop();
    },
  );

  test(
    'reescribe la lista HLS: claves, init map, segmentos y sub-playlists',
    () async {
      const segment = [11, 12, 13];
      // La clave es absoluta (y en otro camino): debe reescribirse igual que un
      // segmento relativo, que se resuelve contra la ruta de la lista.
      final master =
          '''
#EXTM3U
#EXT-X-VERSION:6
#EXT-X-KEY:METHOD=AES-128,URI="${originUrl('/k.bin')}"
#EXT-X-MAP:URI="init.mp4"
#EXTINF:4.0,
seg1.ts
#EXTINF:4.0,
/abs/seg2.ts
#EXT-X-STREAM-INF:BANDWIDTH=800000
chunks/index.m3u8
#EXT-X-ENDLIST
''';
      const media = '''
#EXTM3U
#EXTINF:4.0,
sub1.ts
#EXT-X-ENDLIST
''';
      routes['/hls/live.m3u8'] = (request) => _serve(
        request,
        utf8.encode(master),
        referer: 'https://source.example/',
        contentType: 'application/vnd.apple.mpegurl',
      );
      routes['/hls/chunks/index.m3u8'] = (request) => _serve(
        request,
        utf8.encode(media),
        referer: 'https://source.example/',
        contentType: 'application/vnd.apple.mpegurl',
      );
      for (final path in [
        '/hls/seg1.ts',
        '/abs/seg2.ts',
        '/hls/init.mp4',
        '/hls/chunks/sub1.ts',
      ]) {
        routes[path] = (request) =>
            _serve(request, segment, referer: 'https://source.example/');
      }
      routes['/k.bin'] = (request) =>
          _serve(request, const [9, 9], referer: 'https://source.example/');

      final proxy = MediaProxy();
      final local = await proxy.start(
        originUrl('/hls/live.m3u8'),
        headers: {'Referer': 'https://source.example/'},
      );
      final port = proxy.port!;
      final playlist = await _fetch(local!);

      expect(playlist.headers['content-type'], contains('mpegurl'));
      expect(playlist.text, isNot(contains('${origin.port}/k.bin')));
      expect(playlist.text, isNot(contains('chunks/index.m3u8')));
      expect(playlist.text, contains('URI="http://127.0.0.1:$port/p/'));

      final uris = playlist.text
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty && !line.startsWith('#'))
          .toList();
      expect(
        uris,
        hasLength(3),
        reason: 'seg1.ts, /abs/seg2.ts y el sub-playlist',
      );
      for (final uri in uris) {
        expect(uri, startsWith('http://127.0.0.1:$port/p/'));
      }
      // Los clientes HLS (el demuxer de ffmpeg) descartan URLs sin extensión
      // reconocible, así que la local conserva el nombre del destino.
      expect(uris[0], endsWith('/seg1.ts'));
      expect(uris[1], endsWith('/seg2.ts'));
      expect(uris[2], endsWith('/index.m3u8'));
      expect(local, endsWith('/live.m3u8'));

      // Segmento relativo: se resuelve contra la ruta de la lista.
      final first = await _fetch(uris[0]);
      expect(first.body, segment);
      expect(seen.last.uri.path, '/hls/seg1.ts');
      expect(seen.last.headers.value('referer'), 'https://source.example/');

      // Segmento absoluto: conserva su ruta original.
      final second = await _fetch(uris[1]);
      expect(second.body, segment);
      expect(seen.last.uri.path, '/abs/seg2.ts');

      // Sub-playlist: se reescribe otra vez con su propia base.
      final sub = await _fetch(uris[2]);
      final subUri = sub.text
          .split('\n')
          .map((line) => line.trim())
          .firstWhere((line) => line.isNotEmpty && !line.startsWith('#'));
      expect(subUri, startsWith('http://127.0.0.1:$port/p/'));
      final subSegment = await _fetch(subUri);
      expect(subSegment.body, segment);
      expect(seen.last.uri.path, '/hls/chunks/sub1.ts');

      // Tags con URI: la clave absoluta del `EXT-X-KEY` y el `EXT-X-MAP`
      // relativo pasan por el proxy con las mismas cabeceras.
      final tagUris = RegExp(
        r'URI="([^"]+)"',
      ).allMatches(playlist.text).map((match) => match.group(1)!).toList();
      expect(tagUris, hasLength(2));

      expect(tagUris[0], endsWith('/k.bin'));
      expect(tagUris[1], endsWith('/init.mp4'));

      final key = await _fetch(tagUris[0]);
      expect(key.body, const [9, 9]);
      expect(seen.last.uri.path, '/k.bin');
      expect(seen.last.headers.value('referer'), 'https://source.example/');

      final initMap = await _fetch(tagUris[1]);
      expect(initMap.body, segment);
      expect(seen.last.uri.path, '/hls/init.mp4');

      await proxy.stop();
    },
  );
  test('un origen que comprime igual se entrega descomprimido', () async {
    routes['/movie.mp4'] = (request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.set(HttpHeaders.contentEncodingHeader, 'gzip')
        ..headers.set(HttpHeaders.contentTypeHeader, 'video/mp4')
        ..add(gzip.encode(utf8.encode('0123456789')));
      await request.response.close();
    };
    routes['/live.m3u8'] = (request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.set(HttpHeaders.contentEncodingHeader, 'gzip')
        ..headers.set(
          HttpHeaders.contentTypeHeader,
          'application/vnd.apple.mpegurl',
        )
        ..add(gzip.encode(utf8.encode('#EXTM3U\nseg1.ts\n')));
      await request.response.close();
    };

    final proxy = MediaProxy();
    final video = await _fetch(
      (await proxy.start(
        originUrl('/movie.mp4'),
        headers: {'Referer': 'https://source.example/'},
      ))!,
    );
    expect(video.status, HttpStatus.ok);
    expect(video.text, '0123456789');
    final declared = int.tryParse(video.headers['content-length'] ?? '');
    if (declared != null) expect(declared, video.body.length);

    final playlist = await _fetch(
      (await proxy.start(
        originUrl('/live.m3u8'),
        headers: {'Referer': 'https://source.example/'},
      ))!,
    );
    final segment = playlist.text
        .split('\n')
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty && !line.startsWith('#'));
    expect(segment, startsWith('http://127.0.0.1:${proxy.port}/p/'));
    expect(segment, endsWith('/seg1.ts'));

    await proxy.stop();
  });

  test(
    'la URL local conserva el nombre del destino o lo omite si no lo hay',
    () async {
      final proxy = MediaProxy();
      final local = await proxy.start(
        originUrl('/movie.mp4'),
        headers: {'Referer': 'https://source.example/'},
      );

      String tokenOf(String target) =>
          base64Url.encode(utf8.encode(target)).replaceAll('=', '');

      expect(local, endsWith('/movie.mp4'));
      expect(
        proxy.urlFor(Uri.parse('https://cdn.example/live/stream?token=abc')),
        'http://127.0.0.1:${proxy.port}/p/${tokenOf('https://cdn.example/live/stream?token=abc')}',
        reason: 'sin extensión no se inventa sufijo',
      );
      expect(
        proxy.urlFor(Uri.parse('https://cdn.example/video/')),
        'http://127.0.0.1:${proxy.port}/p/${tokenOf('https://cdn.example/video/')}',
      );

      await proxy.stop();
    },
  );

  test('la parada libera el puerto y corta los clientes', () async {
    routes['/movie.mp4'] = (request) =>
        _serve(request, const [1], referer: 'https://source.example/');
    final proxy = MediaProxy();
    final local = await proxy.start(
      originUrl('/movie.mp4'),
      headers: {'Referer': 'https://source.example/'},
    );
    final port = proxy.port!;
    expect((await _fetch(local!)).status, HttpStatus.ok);

    await proxy.stop();

    expect(proxy.isRunning, isFalse);
    expect(proxy.port, isNull);
    final failure = await _fetchFailure(local);
    expect(
      failure,
      isA<SocketException>(),
      reason: 'el puerto $port ya no acepta conexiones',
    );
  });

  test('rutas y métodos inválidos no tumban el proxy', () async {
    routes['/movie.mp4'] = (request) =>
        _serve(request, const [7], referer: 'https://source.example/');
    final proxy = MediaProxy();
    final local = await proxy.start(
      originUrl('/movie.mp4'),
      headers: {'Referer': 'https://source.example/'},
    );
    final base = 'http://127.0.0.1:${proxy.port}';

    expect((await _fetch('$base/')).status, HttpStatus.notFound);
    expect((await _fetch('$base/p/no-es-base64!')).status, HttpStatus.notFound);
    expect(
      (await _fetch(
        '$base/p/${base64Url.encode(utf8.encode('ftp://x/y'))}',
      )).status,
      HttpStatus.notFound,
    );
    expect(
      (await _fetch(
        '$base/p/${base64Url.encode(utf8.encode(originUrl('/movie.mp4')))}',
        method: 'POST',
      )).status,
      HttpStatus.methodNotAllowed,
    );

    expect((await _fetch(local!)).body, const [7]);

    await proxy.stop();
  });

  test('dos arranques seguidos dejan vivo solo el último', () async {
    routes['/a.mp4'] = (request) =>
        _serve(request, const [1], referer: 'https://source.example/');
    routes['/b.mp4'] = (request) =>
        _serve(request, const [2, 3], referer: 'https://source.example/');

    final proxy = MediaProxy();
    final results = await Future.wait([
      proxy.start(
        originUrl('/a.mp4'),
        headers: {'Referer': 'https://source.example/'},
      ),
      proxy.start(
        originUrl('/b.mp4'),
        headers: {'Referer': 'https://source.example/'},
      ),
    ]);

    expect(await _fetchFailure(results.first!), isA<SocketException>());
    expect((await _fetch(results.last!)).body, const [2, 3]);

    await proxy.stop();
  });
}

/// Sirve [payload]; sin el Referer exigido responde 403, y si la petición trae
/// `Range` responde 206 con el trozo pedido.
Future<void> _serve(
  HttpRequest request,
  List<int> payload, {
  required String referer,
  String contentType = 'video/mp4',
}) async {
  if (request.headers.value('referer') != referer) {
    request.response.statusCode = HttpStatus.forbidden;
    await request.response.close();
    return;
  }

  var body = payload;
  final range = request.headers.value(HttpHeaders.rangeHeader);
  final match = range == null
      ? null
      : RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
  if (match != null) {
    final start = int.parse(match.group(1)!);
    final end = match.group(2)!.isEmpty
        ? payload.length - 1
        : int.parse(match.group(2)!);
    body = payload.sublist(start, end + 1);
    request.response
      ..statusCode = HttpStatus.partialContent
      ..headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${payload.length}',
      )
      ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
  }

  request.response
    ..headers.set(HttpHeaders.contentTypeHeader, contentType)
    ..headers.contentLength = body.length
    ..add(body);
  await request.response.close();
}

class _Fetched {
  final int status;
  final Map<String, String> headers;
  final List<int> body;

  const _Fetched(this.status, this.headers, this.body);

  String get text => utf8.decode(body);
}

Future<_Fetched> _fetch(
  String url, {
  Map<String, String> headers = const {},
  String method = 'GET',
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, Uri.parse(url));
    headers.forEach(request.headers.set);
    final response = await request.close();
    final builder = BytesBuilder(copy: false);
    await response.forEach(builder.add);
    final received = <String, String>{};
    response.headers.forEach(
      (name, values) => received[name.toLowerCase()] = values.join(', '),
    );
    return _Fetched(response.statusCode, received, builder.takeBytes());
  } finally {
    client.close(force: true);
  }
}

/// Error que produce pedir una URL cuyo puerto ya no escucha.
Future<Object> _fetchFailure(String url) async {
  try {
    await _fetch(url);
  } catch (error) {
    return error;
  }
  fail('se esperaba un fallo de conexión para $url');
}
