// Punta a punta real (motor y renderizado de Windows) del tramo que el usuario
// reportaba roto: magnet listo en AllDebrid v4.1 → enlace desbloqueado → motor
// reproduciendo.
//
//   flutter test integration_test/alldebrid_playback_test.dart -d windows
//
// La API de AllDebrid se intercepta en el adaptador HTTP de Dio con las
// respuestas reales de v4.1 (`magnets` como array, enlaces en `files[].l`,
// flujo `delayed`), pero el resto es el código de producción: la ficha real, el
// selector real y el reproductor real con mpv. El enlace desbloqueado apunta al
// WAV que sirve este mismo test en localhost, así que la reproducción que se
// comprueba es real, no una línea de log.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:clubtivi/data/datasources/remote/debrid_client.dart';
import 'package:clubtivi/data/models/show.dart';
import 'package:clubtivi/data/models/stream_search_result.dart';
import 'package:clubtivi/data/models/stream_source.dart';
import 'package:clubtivi/data/repositories/shows_repository.dart';
import 'package:clubtivi/features/player/player_screen.dart';
import 'package:clubtivi/features/player/player_service.dart';
import 'package:clubtivi/features/shows/show_detail_screen.dart';
import 'package:clubtivi/features/shows/shows_providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

const _series = Show(
  traktId: 1,
  imdbId: 'tt7654321',
  title: 'Carrie',
  year: 2026,
  type: ShowType.show,
);

const _episode = Episode(
  season: 1,
  number: 1,
  title: 'FIRST PERIOD',
  runtime: 56,
);

const _torrent = StreamSource(
  id: 'torrentio:carrie:1:1',
  providerId: 'torrentio',
  providerName: 'Torrentio',
  kind: SourceKind.torrent,
  title: 'Carrie.S01E01.2026.WEB-DL.1080p.Dual-Lat',
  quality: '1080p',
  sizeBytes: 3 * 1024 * 1024 * 1024,
  seeds: 34,
  audioLanguages: {'es-419'},
  magnetUrl: 'magnet:?xt=urn:btih:AAABBBCCCDDDEEEFFF0001112223334445556667',
);

/// Respuestas de AllDebrid tal como las devuelve el API (v4.1 incluido el
/// array `magnets` y el árbol `files` con `l`).
class _AllDebridStub implements HttpClientAdapter {
  _AllDebridStub({
    required this.unlockedUrl,
    this.delayed = false,
    this.downloadedBytes = 3 * 1024 * 1024 * 1024,
  });

  final String unlockedUrl;
  final bool delayed;
  final int downloadedBytes;

  final List<String> calls = [];
  int _statusCalls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(options.path);
    switch (options.path) {
      case '/v4/magnet/upload':
        return _json({
          'status': 'success',
          'data': {
            'magnets': [
              {
                'magnet': 'magnet:?xt=urn:btih:AAABBBCCCDDDEEEFFF0001112223334445556667',
                'hash': 'AAABBBCCCDDDEEEFFF0001112223334445556667',
                'name': 'Carrie.S01E01.2026.WEB-DL.1080p.Dual-Lat',
                'size': 3 * 1024 * 1024 * 1024,
                'ready': true,
                'id': 424242,
              },
            ],
          },
        });
      case '/v4.1/magnet/status':
        _statusCalls++;
        return _json({
          'status': 'success',
          'data': {
            'magnets': [
              {
                'id': 424242,
                'filename': 'Carrie.S01E01.2026.WEB-DL.1080p.Dual-Lat',
                'size': 3 * 1024 * 1024 * 1024,
                'status': 'Ready',
                'statusCode': 4,
                'downloaded': downloadedBytes,
                'seeders': 34,
                'files': [
                  {
                    'n': 'Sample',
                    's': 1024 * 1024,
                    'l': 'https://alldebrid.com/f/sample',
                  },
                  {
                    'n': 'Carrie.S01E01.2026.WEB-DL.1080p.Dual-Lat.mkv',
                    's': 3 * 1024 * 1024 * 1024,
                    'l': 'https://alldebrid.com/f/carrie-s01e01',
                  },
                  {
                    'n': 'Subs',
                    'e': [
                      {
                        'n': 'Carrie.S01E01.es.srt',
                        's': 4096,
                        'l': 'https://alldebrid.com/f/carrie-subs',
                      },
                    ],
                  },
                ],
              },
            ],
          },
        });
      case '/v4/link/unlock':
        if (delayed) {
          return _json({
            'status': 'success',
            'data': {'filename': 'episode.wav', 'delayed': 2457},
          });
        }
        return _json({
          'status': 'success',
          'data': {
            'link': unlockedUrl,
            'filename': 'Carrie.S01E01.2026.WEB-DL.1080p.Dual-Lat.mkv',
            'filesize': 3 * 1024 * 1024 * 1024,
          },
        });
      case '/v4/link/delayed':
        return _json({
          'status': 'success',
          'data': {
            'status': 2,
            'link': unlockedUrl,
            'filename': 'episode.wav',
          },
        });
    }
    return _json({
      'status': 'error',
      'error': {'code': '404', 'message': "Endpoint doesn't exist"},
    });
  }

  int get statusCalls => _statusCalls;

  ResponseBody _json(Map<String, dynamic> body) => ResponseBody.fromString(
        jsonEncode(body),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}

/// WAV PCM 16 bits mono: el motor avanza posición aunque no haya imagen.
Uint8List _toneWav({int seconds = 30}) {
  const rate = 44100;
  const channels = 1;
  const bits = 16;
  final samples = rate * seconds;
  final data = ByteData(44 + samples * 2);

  void ascii(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      data.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + samples * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, channels, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * channels * bits ~/ 8, Endian.little);
  data.setUint16(32, channels * bits ~/ 8, Endian.little);
  data.setUint16(34, bits, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, samples * 2, Endian.little);

  for (var i = 0; i < samples; i++) {
    final value =
        (32767 * 0.2 * math.sin(2 * math.pi * 440 * i / rate)).round();
    data.setInt16(44 + i * 2, value, Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  late HttpServer server;
  late Uint8List wav;
  late String unlockedUrl;
  late String delayedUrl;

  setUpAll(() async {
    HttpOverrides.global = null;
    wav = _toneWav();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = wav;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      var start = 0;
      var end = body.length - 1;
      var partial = false;
      if (range != null && range.startsWith('bytes=')) {
        final parts = range.substring(6).split('-');
        start = int.tryParse(parts.first) ?? 0;
        if (parts.length > 1 && parts[1].isNotEmpty) {
          end = int.tryParse(parts[1]) ?? end;
        }
        if (start < 0) start = 0;
        if (end >= body.length) end = body.length - 1;
        partial = true;
      }
      request.response.headers.set('Accept-Ranges', 'bytes');
      request.response.headers.contentType = ContentType('audio', 'wav');
      request.response.headers.contentLength = end - start + 1;
      if (partial) {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          'Content-Range',
          'bytes $start-$end/${body.length}',
        );
      }
      if (request.method != 'HEAD') {
        request.response.add(body.sublist(start, end + 1));
      }
      await request.response.close();
    });
    unlockedUrl = 'http://127.0.0.1:${server.port}/episode.wav';
    delayedUrl = 'http://127.0.0.1:${server.port}/delayed.wav';
  });

  tearDownAll(() => server.close(force: true));

  Future<void> waitUntil(
    WidgetTester tester,
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 30),
    String reason = 'la condición no se cumplió',
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (condition()) return;
    }
    fail(reason);
  }

  /// Monta la ficha real con el repositorio real y la API de AllDebrid
  /// interceptada. Devuelve el contenedor para leer el reproductor compartido.
  Future<(ProviderContainer, PlayerService)> pumpShowDetail(
    WidgetTester tester,
    AllDebridService service, {
    StreamSource source = _torrent,
  }) async {
    final container = ProviderContainer(
      overrides: [
        showDetailProvider.overrideWith(
          (ref, params) async => ShowDetail(
            show: _series,
            seasons: const [Season(number: 1, episodeCount: 1)],
          ),
        ),
        episodesProvider.overrideWith((ref, params) async => [_episode]),
        resolveStreamProvider.overrideWith(
          (ref, params) async => StreamSearchResult(sources: [source]),
        ),
        showsRepositoryProvider.overrideWith(
          (ref) async => ShowsRepository(debridServices: [service]),
        ),
      ],
    );
    addTearDown(container.dispose);
    final player = container.read(playerServiceProvider);

    final router = GoRouter(
      initialLocation: '/shows/1',
      routes: [
        GoRoute(
          path: '/shows/:id',
          builder: (context, state) =>
              ShowDetailScreen(traktId: 1, initialShow: _series),
        ),
        GoRoute(
          path: '/player',
          builder: (context, state) {
            final extra = state.extra as Map<String, dynamic>;
            return PlayerScreen(
              streamUrl: extra['streamUrl'] as String? ?? '',
              channelName: extra['channelName'] as String? ?? '',
              channelLogo: extra['channelLogo'] as String?,
              httpHeaders: Map<String, String>.from(
                extra['httpHeaders'] as Map? ?? const <String, String>{},
              ),
            );
          },
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    return (container, player);
  }

  /// Pulsa el episodio, elige la única fuente y deja el selector cerrado.
  Future<void> pickTorrent(
    WidgetTester tester, {
    StreamSource source = _torrent,
  }) async {
    await tester.scrollUntilVisible(
      find.textContaining('FIRST PERIOD'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('FIRST PERIOD'));
    await tester.pump();

    // El estado pendiente de la fila se cubre en el widget test con una
    // búsqueda controlada (aquí el provider ya tiene la lista preparada).
    await waitUntil(
      tester,
      () => find.text('Select Stream').evaluate().isNotEmpty,
      reason: 'el selector de fuentes no se abrió',
    );
    await tester.tap(find.text(source.displayName));
    await tester.pump();
  }

  // Con una cuenta real: el servicio de verdad llama a AllDebrid, desbloquea
  // un enlace firmado y mpv lo reproduce. Se salta si no hay credenciales.
  //
  //   set ALLDEBRID_APIKEY=...
  //   set ALLDEBRID_TEST_MAGNET=magnet:?xt=urn:btih:...
  //   flutter test integration_test/alldebrid_playback_test.dart -d windows
  final liveKey = (Platform.environment['ALLDEBRID_APIKEY'] ?? '').trim();
  final liveMagnet =
      (Platform.environment['ALLDEBRID_TEST_MAGNET'] ?? '').trim();
  final liveSource = StreamSource(
    id: 'live:alldebrid',
    providerId: 'torrentio',
    providerName: 'Torrentio',
    kind: SourceKind.torrent,
    title: 'Carrie.S01E01.2026.WEB-DL.1080p-Dual-Lat',
    quality: '1080p',
    magnetUrl: liveMagnet.isEmpty ? null : liveMagnet,
  );

  testWidgets(
    'cuenta real: AllDebrid desbloquea el enlace y mpv lo reproduce',
    (tester) async {
      final service = AllDebridService(
        apiToken: liveKey,
        resolveTimeout: const Duration(minutes: 3),
      );

      final (_, player) = await pumpShowDetail(
        tester,
        service,
        source: liveSource,
      );
      await pickTorrent(tester, source: liveSource);

      await waitUntil(
        tester,
        () => player.currentUrl != null,
        timeout: const Duration(minutes: 3),
        reason: 'AllDebrid no resolvió el magnet real',
      );
      expect(player.currentUrl, contains('debrid'),
          reason: 'la URL debe ser la desbloqueada por AllDebrid');
      await waitUntil(
        tester,
        () => player.player.state.position >= const Duration(seconds: 2),
        timeout: const Duration(seconds: 90),
        reason: 'mpv no reprodujo el enlace real de AllDebrid',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
    skip: liveKey.isEmpty || liveMagnet.isEmpty,
  );

  testWidgets('magnet listo → enlace desbloqueado → mpv reproduce', (
    tester,
  ) async {
    final stub = _AllDebridStub(unlockedUrl: unlockedUrl);
    final dio = Dio()..httpClientAdapter = stub;
    final service = AllDebridService(
      apiToken: 'integration-token',
      dio: dio,
      pollInterval: const Duration(milliseconds: 50),
      resolveTimeout: const Duration(seconds: 15),
    );

    final (_, player) = await pumpShowDetail(tester, service);
    await pickTorrent(tester);

    await waitUntil(
      tester,
      () => find.byType(PlayerScreen).evaluate().isNotEmpty,
      reason: 'el reproductor real no se abrió',
    );

    final screen = tester.widget<PlayerScreen>(find.byType(PlayerScreen));
    expect(screen.streamUrl, unlockedUrl,
        reason: 'el reproductor debe recibir el enlace desbloqueado');
    expect(screen.streamUrl, isNotEmpty);
    expect(screen.httpHeaders, isEmpty,
        reason: 'un enlace debrid no arrastra cabeceras del addon');

    await waitUntil(
      tester,
      () => player.currentUrl == unlockedUrl,
      reason: 'el motor no tomó el enlace desbloqueado',
    );
    await waitUntil(
      tester,
      () => player.player.state.position >= const Duration(seconds: 1),
      reason: 'el enlace desbloqueado no llegó a reproducirse',
    );
    expect(player.player.state.playing, isTrue);
    expect(player.player.state.playlist.medias.first.uri, unlockedUrl);

    expect(stub.calls, contains('/v4/magnet/upload'));
    expect(stub.calls, contains('/v4.1/magnet/status'));
    expect(stub.calls, isNot(contains('/v4/magnet/status')));
    expect(stub.calls, contains('/v4/link/unlock'));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('enlace diferido del unlock también acaba reproduciendo', (
    tester,
  ) async {
    final stub = _AllDebridStub(unlockedUrl: delayedUrl, delayed: true);
    final dio = Dio()..httpClientAdapter = stub;
    final service = AllDebridService(
      apiToken: 'integration-token',
      dio: dio,
      pollInterval: const Duration(milliseconds: 50),
      resolveTimeout: const Duration(seconds: 15),
    );

    final (_, player) = await pumpShowDetail(tester, service);
    await pickTorrent(tester);

    await waitUntil(
      tester,
      () => player.currentUrl == delayedUrl,
      reason: 'el flujo delayed no entregó el enlace al motor',
    );
    await waitUntil(
      tester,
      () => player.player.state.position >= const Duration(seconds: 1),
      reason: 'el enlace diferido no llegó a reproducirse',
    );
    expect(stub.calls, contains('/v4/link/delayed'));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('mientras espera enseña el progreso real y lo retira al abrir', (
    tester,
  ) async {
    final stub = _AllDebridStub(unlockedUrl: unlockedUrl);
    final dio = Dio()..httpClientAdapter = _SlowReadyAdapter(stub);
    final service = AllDebridService(
      apiToken: 'integration-token',
      dio: dio,
      pollInterval: const Duration(milliseconds: 200),
      resolveTimeout: const Duration(seconds: 20),
    );

    final (_, player) = await pumpShowDetail(tester, service);
    await pickTorrent(tester);

    await waitUntil(
      tester,
      () => find.textContaining('Downloading (25%)').evaluate().isNotEmpty,
      timeout: const Duration(seconds: 10),
      reason: 'el progreso real del magnet no llegó a la pantalla',
    );
    expect(
      find.textContaining('(50%)'),
      findsNothing,
      reason: 'el 50 % fijo era el síntoma original',
    );

    await waitUntil(
      tester,
      () => player.player.state.position >= const Duration(seconds: 1),
      timeout: const Duration(seconds: 20),
      reason: 'el magnet que tardó en estar listo no llegó a reproducirse',
    );
    expect(player.currentUrl, unlockedUrl);
    expect(
      find.byType(SnackBar),
      findsNothing,
      reason: 'el aviso de espera no debe quedar encima del vídeo',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('un magnet no cacheado se explica y no navega', (tester) async {
    final stub = _AllDebridStub(
      unlockedUrl: unlockedUrl,
      downloadedBytes: 1024 * 1024 * 1024,
    );
    // Un servicio que nunca llega a «Ready»: el magnet sigue descargando.
    final dio = Dio()
      ..httpClientAdapter = _NeverReadyAdapter(stub);
    final service = AllDebridService(
      apiToken: 'integration-token',
      dio: dio,
      pollInterval: const Duration(milliseconds: 100),
      resolveTimeout: const Duration(seconds: 2),
    );

    final (_, player) = await pumpShowDetail(tester, service);
    await pickTorrent(tester);

    await waitUntil(
      tester,
      () => find.textContaining('sigue preparando').evaluate().isNotEmpty,
      timeout: const Duration(seconds: 20),
      reason: 'la espera debe terminar con una explicación visible',
    );
    expect(find.textContaining('25%'), findsWidgets,
        reason: 'el aviso lleva el progreso real, no un 50 fijo');
    expect(find.byType(PlayerScreen), findsNothing);
    expect(player.currentUrl, isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}

/// Igual que el stub real, pero tarda dos sondeos en estar listo: así se ve
/// el progreso real en pantalla antes de que arranque el vídeo.
class _SlowReadyAdapter implements HttpClientAdapter {
  _SlowReadyAdapter(this.delegate);

  final _AllDebridStub delegate;
  int _statusCalls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path == '/v4.1/magnet/status' && _statusCalls++ < 2) {
      delegate.calls.add(options.path);
      return ResponseBody.fromString(
        jsonEncode({
          'status': 'success',
          'data': {
            'magnets': [
              {
                'id': 424242,
                'filename': 'Carrie.S01E01.2026.WEB-DL.1080p.Dual-Lat',
                'size': 4 * 1024 * 1024 * 1024,
                'status': 'Downloading',
                'statusCode': 1,
                'downloaded': 1024 * 1024 * 1024,
              },
            ],
          },
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    return delegate.fetch(options, requestStream, cancelFuture);
  }

  @override
  void close({bool force = false}) => delegate.close(force: force);
}

/// Igual que el stub real, pero el magnet siempre está descargando.
class _NeverReadyAdapter implements HttpClientAdapter {
  _NeverReadyAdapter(this.delegate);

  final _AllDebridStub delegate;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path == '/v4.1/magnet/status') {
      delegate.calls.add(options.path);
      return ResponseBody.fromString(
        jsonEncode({
          'status': 'success',
          'data': {
            'magnets': [
              {
                'id': 424242,
                'filename': 'Carrie.S01E01.2026.WEB-DL.1080p.Dual-Lat',
                'size': 4 * 1024 * 1024 * 1024,
                'status': 'Downloading',
                'statusCode': 1,
                'downloaded': 1024 * 1024 * 1024,
              },
            ],
          },
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    return delegate.fetch(options, requestStream, cancelFuture);
  }

  @override
  void close({bool force = false}) => delegate.close(force: force);
}
