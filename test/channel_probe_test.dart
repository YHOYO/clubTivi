// La detección de canales que sirven y canales que no: se comprueba contra un
// servidor HTTP real (en loopback) para medir exactamente lo que ve la app:
// códigos de estado, respuestas que no son listas y servidores que no contestan.
import 'dart:io';

import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/channel_probe_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late ChannelProbeService probe;
  final receivedHeaders = <String, Map<String, String>>{};

  /// Servidor que se ahoga con varias peticiones a la vez (ver
  /// `/choked.m3u8`): el test lo suelta desde `onRetryStart`, que es
  /// exactamente lo que representa «la segunda pasada, de uno en uno».
  var choked = true;

  setUp(() async {
    receivedHeaders.clear();
    choked = true;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      receivedHeaders[request.uri.path] = {
        for (final name in ['referer', 'user-agent', 'range'])
          if (request.headers.value(name) != null)
            name: request.headers.value(name)!,
      };
      final path = request.uri.path;
      if (path == '/ok.m3u8') {
        request.response
          ..statusCode = 200
          ..write('#EXTM3U\n#EXTINF:-1,Canal\nhttp://example.com/s.m3u8\n');
      } else if (path == '/forbidden.m3u8') {
        request.response.statusCode = 403;
      } else if (path == '/gone.m3u8') {
        request.response.statusCode = 404;
      } else if (path == '/blocked.m3u8') {
        // Página de bloqueo de un filtro de red: 403 con HTML.
        request.response
          ..statusCode = 403
          ..write('<!DOCTYPE html>\n<html lang="es"><head><title>POLÍTICA DE '
              'SEGURIDAD INFORMACIÓN</title></head><body>Bloqueado</body>'
              '</html>');
      } else if (path == '/hotlink.mp4') {
        // CDN que rechaza el hotlink: 403 con HTML, sin ser una página del ISP.
        request.response
          ..statusCode = 403
          ..write('<html><body>403 Forbidden</body></html>');
      } else if (path == '/protected.mp4') {
        // Sólo sirve si el cliente manda el Referer que el addon publica.
        if (request.headers.value('referer') != 'https://cdn.test/') {
          request.response
            ..statusCode = 403
            ..write('<html><body>403 Forbidden</body></html>');
        } else {
          request.response
            ..statusCode = 206
            ..add(List<int>.filled(4096, 0x00));
        }
      } else if (path == '/login.m3u8') {
        request.response
          ..statusCode = 200
          ..write('<html><body>Please sign in</body></html>');
      } else if (path == '/empty.m3u8') {
        request.response.statusCode = 200;
      } else if (path == '/slow.m3u8') {
        // Nunca contesta a tiempo: es el caso del canal que deja «Buffering»
        // durante veinte segundos sin decir por qué.
        await Future<void>.delayed(const Duration(seconds: 20));
        request.response.statusCode = 200;
      } else if (path == '/choked.m3u8') {
        // Mientras el servidor está «ahogado» (varias peticiones a la vez) no
        // contesta a tiempo; cuando se le pide un canal solo, contesta al
        // momento.
        if (choked) {
          await Future<void>.delayed(const Duration(seconds: 3));
        }
        request.response.write('#EXTM3U\n#EXTINF:-1,Canal\n');
      } else if (path == '/ok.ts') {
        request.response
          ..statusCode = 200
          ..add(List<int>.filled(4096, 0x47));
      } else {
        request.response.statusCode = 500;
      }
      await request.response.close();
    });
    probe = ChannelProbeService();
  });

  tearDown(() async {
    await server.close(force: true);
  });

  String url(String path) => 'http://127.0.0.1:${server.port}$path';

  db.Channel channel(String path, {String? headers, String? id}) => db.Channel(
        id: id ?? 'ch-$path',
        providerId: 'p1',
        name: path,
        streamUrl: url(path),
        streamType: 'live',
        favorite: false,
        hidden: false,
        sortOrder: 0,
        httpHeaders: headers,
      );

  group('ChannelProbeService', () {
    test('a channel that answers with a playlist is OK', () async {
      final result = await probe.probeUrl(url('/ok.m3u8'));
      expect(result.status, ProbeStatus.ok);
      expect(result.isOk, isTrue);
      expect(result.httpStatus, 200);
      expect(result.label, 'OK');
    });

    test('403 is reported as blocked, not as a generic failure', () async {
      final result = await probe.probeUrl(url('/forbidden.m3u8'));
      expect(result.status, ProbeStatus.forbidden);
      expect(result.httpStatus, 403);
      expect(result.advice, contains('refuses the connection'));
    });

    test('404 is reported as a channel that is gone', () async {
      final result = await probe.probeUrl(url('/gone.m3u8'));
      expect(result.status, ProbeStatus.notFound);
      expect(result.httpStatus, 404);
    });

    test('200 with a login page is not treated as a working stream', () async {
      final result = await probe.probeUrl(url('/login.m3u8'));
      expect(result.status, ProbeStatus.notAPlaylist);
      expect(result.advice, contains('web page'));
    });

    test('an empty 200 body is not a working stream either', () async {
      final result = await probe.probeUrl(url('/empty.m3u8'));
      expect(result.status, ProbeStatus.unreachable);
    });

    test('a server that never answers times out instead of hanging', () async {
      final stopwatch = Stopwatch()..start();
      final result = await probe.probeUrl(
        url('/slow.m3u8'),
        timeout: const Duration(milliseconds: 700),
      );
      stopwatch.stop();
      expect(result.status, ProbeStatus.timeout);
      expect(stopwatch.elapsedMilliseconds, lessThan(5000));
    });

    test('a connection that cannot be made counts as an error', () async {
      // Puerto cerrado: DNS/connect falla antes que cualquier respuesta.
      final result = await probe.probeUrl('http://127.0.0.1:1/dead.m3u8');
      expect(result.status, ProbeStatus.error);
      expect(result.detail, isNotNull);
    });

    test('a raw TS stream is OK without being an m3u8', () async {
      final result = await probe.probeUrl(url('/ok.ts'));
      expect(result.status, ProbeStatus.ok);
    });

    test('the headers the playlist demands are sent to the server', () async {
      await probe.probeChannel(
        channel(
          '/ok.m3u8',
          headers: '{"Referer":"http://provider.example/","User-Agent":"Mozilla/5.0"}',
        ),
      );
      final headers = receivedHeaders['/ok.m3u8'];
      expect(headers?['referer'], 'http://provider.example/');
      expect(headers?['user-agent'], 'Mozilla/5.0');
    });

    test('without playlist headers a default user agent is used', () async {
      await probe.probeChannel(channel('/ok.m3u8'));
      expect(receivedHeaders['/ok.m3u8']?['user-agent'], isNotNull);
    });

    test('a scan reports every channel once, with running progress', () async {
      final channels = [
        channel('/ok.m3u8'),
        channel('/forbidden.m3u8'),
        channel('/gone.m3u8'),
        channel('/login.m3u8'),
        channel('/ok.ts'),
        channel('/slow.m3u8'),
      ];
      final seen = <String, ProbeResult>{};
      final progress = <int>[];

      await probe.scan(
        channels,
        concurrency: 3,
        timeout: const Duration(milliseconds: 700),
        retryTimeouts: false,
        onResult: (channel, result, done, total) {
          seen[channel.id] = result;
          progress.add(done);
          expect(total, channels.length);
        },
      );

      expect(seen, hasLength(channels.length));
      expect(seen['ch-/ok.m3u8']!.isOk, isTrue);
      expect(seen['ch-/ok.ts']!.isOk, isTrue);
      expect(seen['ch-/forbidden.m3u8']!.status, ProbeStatus.forbidden);
      expect(seen['ch-/slow.m3u8']!.status, ProbeStatus.timeout);
      // El progreso avanza de uno en uno hasta el total, sin repetir.
      expect(progress, List<int>.generate(channels.length, (i) => i + 1));
    });

    test('a server that only chokes in parallel is retried alone and marked slow',
        () async {
      // Seis peticiones a la vez: ninguna contesta a tiempo.
      final chokedChannels =
          List.generate(6, (i) => channel('/choked.m3u8', id: 'choked-$i'));
      final finalVerdicts = <String, ProbeResult>{};
      final firstPass = <String, ProbeResult>{};
      final order = <String>[];
      var retryPending = 0;
      var retryReports = 0;

      await probe.scan(
        chokedChannels,
        concurrency: 6,
        timeout: const Duration(milliseconds: 700),
        retryTimeout: const Duration(seconds: 10),
        onRetryStart: (pending) {
          retryPending = pending;
          choked = false; // el servidor sólo se ahogaba con carga
        },
        onRetryResult: (_, _, _, _) => retryReports++,
        onResult: (channel, result, done, total) {
          order.add(channel.id);
          finalVerdicts[channel.id] = result;
          // putIfAbsent: la primera noticia de cada canal es la de la 1ª pasada.
          firstPass.putIfAbsent(channel.id, () => result);
        },
      );

      // Primera pasada: los seis sin respuesta.
      expect(firstPass.values.map((r) => r.status).toSet(),
          {ProbeStatus.timeout});
      // Segunda pasada: de uno en uno sí contestan — ahogo, no canal muerto.
      expect(retryPending, 6);
      expect(retryReports, 6);
      expect(
          finalVerdicts.values.map((r) => r.status).toSet(), {ProbeStatus.slow});
      expect(finalVerdicts.values.every((r) => r.works), isTrue);
      expect(finalVerdicts.values.every((r) => !r.isOk), isTrue);
      expect(finalVerdicts['choked-0']!.label, contains('Slow'));
      expect(finalVerdicts['choked-0']!.advice, contains('only request'));
    });

    test('channels that never answer stay dead after the second pass',
        () async {
      final dead = List.generate(3, (i) => channel('/slow.m3u8', id: 'dead-$i'));
      final verdicts = <String, ProbeResult>{};
      var retryReports = 0;

      await probe.scan(
        dead,
        concurrency: 3,
        timeout: const Duration(milliseconds: 400),
        retryTimeout: const Duration(milliseconds: 600),
        onRetryResult: (_, _, _, _) => retryReports++,
        onResult: (channel, result, _, _) => verdicts[channel.id] = result,
      );

      expect(retryReports, 3);
      expect(verdicts.values.map((r) => r.status).toSet(),
          {ProbeStatus.timeout});
      expect(verdicts.values.every((r) => !r.works), isTrue);
    });

    test('a 404 does not go through the second pass', () async {
      var retries = 0;
      final verdicts = <String, ProbeResult>{};

      await probe.scan(
        [channel('/gone.m3u8'), channel('/ok.m3u8')],
        concurrency: 2,
        onRetryStart: (_) => retries++,
        onResult: (channel, result, _, _) => verdicts[channel.id] = result,
      );

      expect(retries, 0);
      expect(verdicts['ch-/gone.m3u8']!.status, ProbeStatus.notFound);
      expect(verdicts['ch-/ok.m3u8']!.status, ProbeStatus.ok);
    });

    test('a 403 does go through the second pass (rate limits look like that)',
        () async {
      final verdicts = <String, ProbeResult>{};
      var pending = 0;

      await probe.scan(
        [channel('/forbidden.m3u8')],
        retryTimeout: const Duration(milliseconds: 800),
        onRetryStart: (p) => pending = p,
        onResult: (channel, result, _, _) => verdicts[channel.id] = result,
      );

      expect(pending, 1);
      // Sigue sin servir, pero ahora con la respuesta de la segunda pasada.
      expect(verdicts['ch-/forbidden.m3u8']!.status, ProbeStatus.forbidden);
      expect(verdicts['ch-/forbidden.m3u8']!.works, isFalse);
    });

    test('the second pass is capped so a huge list stays bounded', () async {
      final dead = List.generate(5, (i) => channel('/slow.m3u8', id: 'dead-$i'));
      var pending = 0;
      var retried = 0;

      await probe.scan(
        dead,
        concurrency: 5,
        timeout: const Duration(milliseconds: 300),
        retryTimeout: const Duration(milliseconds: 400),
        maxRetries: 2,
        onRetryStart: (p) => pending = p,
        onRetryResult: (_, _, _, _) => retried++,
        onResult: (_, _, _, _) {},
      );

      expect(pending, 2);
      expect(retried, 2);
    });

    test('the second pass can be turned off', () async {
      var retried = 0;
      await probe.scan(
        [channel('/slow.m3u8')],
        timeout: const Duration(milliseconds: 300),
        retryTimeouts: false,
        onRetryStart: (_) => retried++,
        onResult: (_, _, _, _) {},
      );
      expect(retried, 0);
    });

    test('cancelling a scan stops reporting results', () async {
      final channels =
          List.generate(20, (i) => channel('/slow.m3u8', id: 'slow-$i'));
      var cancelled = false;
      var reported = 0;

      await probe.scan(
        channels,
        concurrency: 2,
        timeout: const Duration(milliseconds: 400),
        retryTimeouts: false,
        isCancelled: () => cancelled,
        onResult: (_, _, _, _) {
          reported++;
          cancelled = true; // como el botón STOP del diálogo
        },
      );

      expect(reported, lessThan(channels.length));
    });
  });

  group('network-level failures are told apart', () {
    DioException dioError(Object error,
            {Response<dynamic>? response, String message = 'unknown'}) =>
        DioException(
          requestOptions: RequestOptions(path: 'https://example.com/x.m3u8'),
          type: response == null
              ? DioExceptionType.connectionError
              : DioExceptionType.badResponse,
          response: response,
          error: error,
          message: message,
        );

    test('a certificate that cannot be verified is its own verdict', () {
      // Es lo que devuelve Dart cuando un antivirus/proxy intercepta HTTPS: un
      // fallo en milisegundos que no dice nada del canal.
      final result = ChannelProbeService.classifyError(
        dioError('HandshakeException: Handshake error in client (OS Error: '
            'CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate)'),
        latencyMs: 219,
      );

      expect(result.status, ProbeStatus.tls);
      expect(result.label, 'Certificate not verified');
      expect(result.advice, contains('antivirus'));
      expect(result.verdict, ProbeVerdict.blocked);
      // Y explica el motivo de verdad, no un «unknown».
      expect(result.detail, contains('CERTIFICATE_VERIFY_FAILED'));
    });

    test('a blocking page served with 403 is not «the channel refused»', () async {
      final result = await probe.probeUrl(url('/blocked.m3u8'));
      expect(result.status, ProbeStatus.blocked);
      expect(result.httpStatus, 403);
      expect(result.advice, contains('filtered'));
      expect(result.verdict, ProbeVerdict.blocked);
    });

    test('a plain 403 keeps meaning the server refused', () async {
      final result = await probe.probeUrl(url('/forbidden.m3u8'));
      expect(result.status, ProbeStatus.forbidden);
      expect(result.verdict, ProbeVerdict.serverSide);
    });

    test('en VOD un 403 HTML es rechazo del CDN, no bloqueo del ISP', () async {
      final result = await probe.probeUrl(
        url('/hotlink.mp4'),
        detectBlockPage: false,
      );
      expect(result.status, ProbeStatus.forbidden);
      expect(result.httpStatus, 403);
      expect(result.verdict, ProbeVerdict.serverSide,
          reason: 'no puede culpar a la red de un hotlink rechazado');
      expect(result.advice, isNot(contains('filtered')));
      expect(result.advice, contains('refuses the connection'));
    });

    test('las cabeceras del addon se envían al sondear un VOD', () async {
      final result = await probe.probeUrl(
        url('/protected.mp4'),
        headers: const {'Referer': 'https://cdn.test/'},
      );
      expect(result.status, ProbeStatus.ok);
      expect(receivedHeaders['/protected.mp4']?['referer'], 'https://cdn.test/');
    });
  });

  group('ProbeResult serialisation', () {
    test('survives a round trip through JSON', () {
      const original = ProbeResult(
        status: ProbeStatus.forbidden,
        httpStatus: 403,
        latencyMs: 120,
        detail: 'blocked',
      );
      final restored = ProbeResult.fromJson(original.toJson());
      expect(restored.status, original.status);
      expect(restored.httpStatus, 403);
      expect(restored.latencyMs, 120);
      expect(restored.detail, 'blocked');
      expect(restored.isOk, isFalse);
    });
  });
}
