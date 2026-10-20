// AllDebrid es el único servicio que el usuario tiene activo, así que su flujo
// magnet→URL tiene que estar cubierto sin red: aquí se reemplaza el adaptador
// HTTP de Dio por respuestas con la forma real del API v4.1.
//
// El fallo original: `/v4/magnet/status` está obsoleto y contesta
// `{"status":"error"}`; el cliente leía `data.magnets` como objeto (v4.1
// devuelve un array), así que cada sondeo acababa con estado vacío y el UI
// pintaba un 50 % fijo hasta rendirse a los 90 s.
import 'dart:convert';
import 'dart:typed_data';

import 'package:clubtivi/data/datasources/remote/debrid_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Adaptador de Dio que sirve respuestas preparadas y guarda las peticiones.
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.responses);

  /// Ruta → cola de cuerpos JSON. La última entrada se repite.
  final Map<String, List<Map<String, dynamic>>> responses;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final queue = responses[options.path];
    if (queue == null || queue.isEmpty) {
      return ResponseBody.fromString(
        jsonEncode({
          'status': 'error',
          'error': {'code': '404', 'message': "Endpoint doesn't exist"},
        }),
        404,
        headers: _jsonHeaders,
      );
    }
    final body = queue.length == 1 ? queue.first : queue.removeAt(0);
    return ResponseBody.fromString(jsonEncode(body), 200,
        headers: _jsonHeaders);
  }

  static const _jsonHeaders = {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  };

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _success(Map<String, dynamic> data) => {
      'status': 'success',
      'data': data,
    };

Map<String, dynamic> _magnetStatus({
  required int statusCode,
  required String status,
  int size = 4 * 1024 * 1024 * 1024,
  int downloaded = 0,
  List<Map<String, dynamic>> files = const [],
}) =>
    _success({
      'magnets': [
        {
          'id': 123456,
          'filename': 'Carrie.S01E01.1080p.WEB-DL.Dual-Lat.mkv',
          'size': size,
          'status': status,
          'statusCode': statusCode,
          'downloaded': downloaded,
          'links': <dynamic>[],
          if (files.isNotEmpty) 'files': files,
        },
      ],
    });

const _readyFiles = [
  {
    'n': 'Sample',
    's': 1024,
    'l': 'https://alldebrid.com/f/sample',
  },
  {
    'n': 'Carrie.S01E01.1080p.WEB-DL.Dual-Lat.mkv',
    's': 3800000000,
    'l': 'https://alldebrid.com/f/episode',
  },
  {
    'n': 'Subs',
    'e': [
      {
        'n': 'Carrie.S01E01.es.srt',
        's': 4096,
        'l': 'https://alldebrid.com/f/subs',
      },
    ],
  },
];

AllDebridService _service(_StubAdapter adapter, {Duration? timeout}) {
  final dio = Dio()..httpClientAdapter = adapter;
  return AllDebridService(
    apiToken: 'test-token',
    dio: dio,
    pollInterval: Duration.zero,
    resolveTimeout: timeout ?? const Duration(seconds: 30),
  );
}

void main() {
  test('sube el magnet, sondea v4.1 y devuelve el enlace desbloqueado', () async {
    final adapter = _StubAdapter({
      '/v4/magnet/upload': [
        _success({
          'magnets': [
            {'magnet': 'magnet:?xt=urn:btih:abc', 'id': 123456, 'ready': false},
          ],
        }),
      ],
      '/v4.1/magnet/status': [
        _magnetStatus(
          statusCode: 1,
          status: 'Downloading',
          downloaded: 3 * 1024 * 1024 * 1024,
        ),
        _magnetStatus(statusCode: 4, status: 'Ready', files: _readyFiles),
      ],
      '/v4/link/unlock': [
        _success({
          'link': 'https://p1.alldebrid.com/dl/1234/episode.mkv',
          'filename': 'Carrie.S01E01.1080p.WEB-DL.Dual-Lat.mkv',
          'filesize': 3800000000,
        }),
      ],
    });

    final progress = <int>[];
    final resolved = await _service(adapter).resolveFromMagnet(
      'magnet:?xt=urn:btih:abc',
      onProgress: (status, percent) {
        expect(status, isNotEmpty, reason: 'sin estado el aviso salía «(50 %)»');
        progress.add(percent);
      },
    );

    expect(resolved!.url, 'https://p1.alldebrid.com/dl/1234/episode.mkv');
    expect(progress, [75], reason: 'progreso real: 3 GB de 4 GB');

    final paths = adapter.requests.map((r) => r.path).toList();
    expect(paths, isNot(contains('/v4/magnet/status')),
        reason: 'el endpoint obsoleto nunca debe consultarse');
    expect(paths.where((p) => p == '/v4.1/magnet/status'), hasLength(2));

    final upload = adapter.requests.first;
    expect(upload.queryParameters['magnets[]'], ['magnet:?xt=urn:btih:abc']);
    expect(upload.queryParameters['apikey'], 'test-token');

    final unlock = adapter.requests.last;
    expect(unlock.method, 'POST');
    final fields = (unlock.data as FormData).fields;
    expect(
      fields.firstWhere((f) => f.key == 'link').value,
      'https://alldebrid.com/f/episode',
      reason: 'se desbloquea el vídeo más grande, no el sample',
    );
  });

  test('un error de magnet se explica en vez de esperar para siempre', () async {
    final adapter = _StubAdapter({
      '/v4/magnet/upload': [
        _success({
          'magnets': [
            {'id': 99, 'ready': false},
          ],
        }),
      ],
      '/v4.1/magnet/status': [
        _magnetStatus(statusCode: 15, status: 'Error'),
      ],
    });

    await expectLater(
      _service(adapter).resolveFromMagnet('magnet:?xt=urn:btih:abc'),
      throwsA(
        isA<AllDebridException>().having(
          (e) => e.message,
          'message',
          contains('peers'),
        ),
      ),
    );
  });

  test('un magnet no cacheado agota la espera con su progreso real', () async {
    final adapter = _StubAdapter({
      '/v4/magnet/upload': [
        _success({
          'magnets': [
            {'id': 7, 'ready': false},
          ],
        }),
      ],
      '/v4.1/magnet/status': [
        _magnetStatus(
          statusCode: 1,
          status: 'Downloading',
          downloaded: 1024 * 1024 * 1024,
        ),
      ],
    });

    final service = _service(
      adapter,
      timeout: const Duration(milliseconds: 200),
    );

    await expectLater(
      service.resolveFromMagnet('magnet:?xt=urn:btih:abc'),
      throwsA(
        isA<AllDebridException>().having(
          (e) => e.message,
          'message',
          allOf(contains('25%'), contains('downloading')),
        ),
      ),
    );
  });

  test('una API key inválida se propaga con su código', () async {
    final adapter = _StubAdapter({
      '/v4/magnet/upload': [
        {
          'status': 'error',
          'error': {'code': 'AUTH_BAD_APIKEY', 'message': 'Invalid apikey'},
        },
      ],
    });

    await expectLater(
      _service(adapter).resolveFromMagnet('magnet:?xt=urn:btih:abc'),
      throwsA(isA<AllDebridException>()
          .having((e) => e.code, 'code', 'AUTH_BAD_APIKEY')),
    );
    expect(await _service(adapter).verifyToken(), isFalse);
  });

  test('acepta la forma antigua con `links` y saltos en el árbol', () async {
    final adapter = _StubAdapter({
      '/v4/magnet/upload': [
        _success({
          'magnets': [
            {'id': 1, 'ready': true},
          ],
        }),
      ],
      '/v4.1/magnet/status': [
        _success({
          'magnets': [
            {
              'id': 1,
              'status': 'Ready',
              'statusCode': 4,
              'links': [
                {
                  'link': 'https://alldebrid.com/f/old',
                  'filename': 'Carrie.S01E01.mkv',
                  'size': 2000000000,
                },
              ],
            },
          ],
        }),
      ],
      '/v4/link/unlock': [
        _success({'link': 'https://p1.alldebrid.com/dl/9/old.mkv'}),
      ],
    });

    final resolved =
        await _service(adapter).resolveFromMagnet('magnet:?xt=urn:btih:abc');
    expect(resolved!.url, 'https://p1.alldebrid.com/dl/9/old.mkv');
  });

  test('sigue el flujo de enlace diferido cuando no hay URL directa', () async {
    final adapter = _StubAdapter({
      '/v4/magnet/upload': [
        _success({
          'magnets': [
            {'id': 5, 'ready': true},
          ],
        }),
      ],
      '/v4.1/magnet/status': [
        _magnetStatus(statusCode: 4, status: 'Ready', files: _readyFiles),
      ],
      '/v4/link/unlock': [
        _success({'delayed': 2457}),
      ],
      '/v4/link/delayed': [
        _success({'status': 1, 'time_left': 2}),
        _success({'status': 2, 'link': 'https://p1.alldebrid.com/dl/5/x.mkv'}),
      ],
    });

    final resolved =
        await _service(adapter).resolveFromMagnet('magnet:?xt=urn:btih:abc');
    expect(resolved!.url, 'https://p1.alldebrid.com/dl/5/x.mkv');
  });

  test('la disponibilidad instantánea ya no golpea un endpoint retirado', () async {
    final adapter = _StubAdapter({});
    final available =
        await _service(adapter).checkInstantAvailability(['abc', 'def']);

    expect(available, isEmpty);
    expect(adapter.requests, isEmpty,
        reason: '/magnet/instant contesta 404 desde 2024');
  });
}
