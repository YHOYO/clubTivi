// El cliente habla con un rqbit falso, pero con el mismo contrato HTTP que el
// real: magnet en el cuerpo de POST /torrents, id 0 válido, detalles/stats y
// streaming con Range.
import 'dart:convert';
import 'dart:io';

import 'package:clubtivi/data/services/p2p/rqbit_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeRqbit {
  final HttpServer server;
  String? lastAddBody;
  Map<String, String>? lastAddQuery;
  int adds = 0;
  final List<String> actions = [];
  String? lastListQuery;

  _FakeRqbit._(this.server) {
    server.listen(_handle);
  }

  static Future<_FakeRqbit> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _FakeRqbit._(server);
  }

  Uri get base => Uri.parse('http://127.0.0.1:${server.port}');

  Future<void> close() => server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    try {
      if (path == '/' && request.method == 'GET') {
        _json(request, {'apis': {'GET /': 'list all available APIs'}});
        return;
      }
      if (path == '/torrents' && request.method == 'POST') {
        adds++;
        lastAddBody = await utf8.decoder.bind(request).join();
        lastAddQuery = request.uri.queryParameters;
        _json(request, {
          'id': 0,
          'details': {
            'id': 0,
            'info_hash': '08ada5a7a6183aae1e09d831df6748d566095a10',
            'name': 'Sintel',
            'files': [
              {'name': 'Sintel.mp4', 'length': 1000, 'included': true},
            ],
          },
        });
        return;
      }
      if (path == '/torrents' && request.method == 'GET') {
        lastListQuery = request.uri.query;
        _json(request, {
          'torrents': [
            {
              'id': 0,
              'info_hash': '08ada5a7a6183aae1e09d831df6748d566095a10',
              'name': 'Sintel',
              'files': [
                {'name': 'Sintel.mp4', 'length': 1000, 'included': true},
              ],
              'stats': {
                'state': 'live',
                'progress_bytes': 250,
                'total_bytes': 1000,
              },
            },
          ],
        });
        return;
      }
      if (path.startsWith('/torrents/0/') && request.method == 'POST') {
        actions.add(path);
        _json(request, const <String, Object?>{});
        return;
      }
      if (path == '/torrents/0' && request.method == 'GET') {
        _json(request, {
          'id': 0,
          'info_hash': '08ada5a7a6183aae1e09d831df6748d566095a10',
          'name': 'Sintel',
          'files': [
            {'name': 'Sintel.mp4', 'length': 1000, 'included': true},
          ],
        });
        return;
      }
      if (path == '/torrents/0/stats/v1' && request.method == 'GET') {
        _json(request, {
          'state': 'live',
          'progress_bytes': 250,
          'total_bytes': 1000,
          'finished': false,
          'error': null,
        });
        return;
      }
      if (path == '/torrents/missing') {
        request.response.statusCode = 404;
        _json(request, {
          'status': 404,
          'error_kind': 'torrent_not_found',
          'human_readable': 'torrent not found missing',
        });
        return;
      }
      if (path == '/torrents/0/stream/0') {
        await _range(request);
        return;
      }
      request.response.statusCode = 404;
      _json(request, {'human_readable': 'not found'});
    } catch (error) {
      request.response.statusCode = 500;
      request.response.write('$error');
      await request.response.close();
    }
  }

  Future<void> _range(HttpRequest request) async {
    final data = List<int>.generate(1000, (index) => index % 251);
    final header = request.headers.value(HttpHeaders.rangeHeader);
    final match =
        header == null ? null : RegExp(r'bytes=(\d+)-(\d*)').firstMatch(header);
    if (match == null) {
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      request.response.headers.contentType = ContentType('video', 'mp4');
      request.response.contentLength = data.length;
      request.response.add(data);
      await request.response.close();
      return;
    }
    final start = int.parse(match.group(1)!);
    final end = match.group(2)!.isEmpty
        ? data.length - 1
        : int.parse(match.group(2)!);
    final chunk = data.sublist(start, end + 1);
    request.response.statusCode = HttpStatus.partialContent;
    request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    request.response.headers
        .set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/${data.length}');
    request.response.headers.contentType = ContentType('video', 'mp4');
    request.response.contentLength = chunk.length;
    request.response.add(chunk);
    await request.response.close();
  }

  void _json(HttpRequest request, Object value) {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(value));
    request.response.close();
  }
}

void main() {
  late _FakeRqbit fake;
  late RqbitClient client;

  setUp(() async {
    fake = await _FakeRqbit.start();
    client = RqbitClient(baseUri: fake.base);
  });

  tearDown(() async {
    await fake.close();
  });

  test('ping acepta la respuesta de la API', () async {
    await expectLater(client.ping(), completes);
  });

  test('añadir manda el magnet tal cual y las opciones en la query', () async {
    const magnet = 'magnet:?xt=urn:btih:ABC'
        '&dn=Sintel&tr=udp%3A%2F%2Ftracker.example%3A1337%2Fannounce';

    final added = await client.addTorrent(
      magnet,
      outputFolder: r'C:\Media',
      onlyFiles: const [0, 2],
    );

    expect(fake.adds, 1);
    expect(fake.lastAddBody, magnet);
    expect(fake.lastAddQuery!['output_folder'], r'C:\Media');
    expect(fake.lastAddQuery!['only_files'], '0,2');
    expect(added.id, 0);
    expect(added.details!.files.single.name, 'Sintel.mp4');
  });

  test('detalles y stats se parsean con el contrato real', () async {
    final details = await client.torrent('0');
    final stats = await client.stats('0');

    expect(details.id, 0);
    expect(details.infoHash, '08ada5a7a6183aae1e09d831df6748d566095a10');
    expect(details.files.single.length, 1000);
    expect(stats.state, 'live');
    expect(stats.progress, closeTo(0.25, 0.0001));
  });

  test('la lista de torrents llega con stats y pide with_stats', () async {
    final torrents = await client.listTorrents();

    expect(fake.lastListQuery, 'with_stats=true');
    expect(torrents, hasLength(1));
    final torrent = torrents.single;
    expect(torrent.id, 0);
    expect(torrent.name, 'Sintel');
    expect(torrent.stats!.state, 'live');
    expect(torrent.stats!.progress, closeTo(0.25, 0.0001));
  });

  test('forget y delete llaman a sus endpoints de acción', () async {
    await client.forgetTorrent('0');
    await client.deleteTorrent('0');

    expect(fake.actions, ['/torrents/0/forget', '/torrents/0/delete']);
  });

  test('overwrite viaja en la query al añadir', () async {
    await client.addTorrent('magnet:?xt=urn:btih:ABC', overwrite: true);

    expect(fake.lastAddQuery!['overwrite'], 'true');
  });

  test('un 404 de rqbit llega con su mensaje humano', () async {
    await expectLater(
      client.torrent('missing'),
      throwsA(
        isA<RqbitHttpException>()
            .having((e) => e.statusCode, 'statusCode', 404)
            .having((e) => e.isNotFound, 'isNotFound', isTrue)
            .having((e) => e.message, 'message', 'torrent not found missing'),
      ),
    );
  });

  test('la URL de streaming usa el id sin redondear y respeta Range', () async {
    final url = client.streamUrl('0', 0);

    expect(url.path, '/torrents/0/stream/0');

    final http = HttpClient();
    final request = await http.getUrl(url);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=10-19');
    final response = await request.close();
    final body = await response.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
    http.close();

    expect(response.statusCode, 206);
    expect(response.headers.value(HttpHeaders.contentRangeHeader), 'bytes 10-19/1000');
    expect(body, hasLength(10));
    expect(body.first, 10);
  });

  test('sin servidor escuchando el error es de conexión, no de protocolo', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    await server.close(force: true);

    final offline = RqbitClient(baseUri: Uri.parse('http://127.0.0.1:$port'));

    await expectLater(
      offline.ping(),
      throwsA(isA<RqbitConnectionException>()),
    );
  });
}
