// Un solo reproductor a la vez, con el motor real de Windows:
//
//   flutter test integration_test/playback_ownership_test.dart -d windows
//
// Reproduce un canal (WAV servido en localhost), abre un tráiler encima y
// comprueba que el motor del canal queda parado y que su posición ya no avanza.
// Después repite con un VOD: al salir del reproductor no queda audio detrás.
// Por último, con un vídeo sin audio, fuerza el reintento por ffmpeg y lo para
// en plena espera: el reintento viejo no puede reabrir nada. Y la ficha de
// Stremio se recorre de punta a punta: el canal queda mudo antes de elegir
// fuente y el reproductor real acaba con el VOD.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:clubtivi/app/router.dart';
import 'package:clubtivi/data/models/media_video.dart';
import 'package:clubtivi/data/models/stream_search_result.dart';
import 'package:clubtivi/data/models/stream_source.dart';
import 'package:clubtivi/data/models/stremio_addon.dart';
import 'package:clubtivi/data/repositories/shows_repository.dart';
import 'package:clubtivi/data/services/channel_probe_service.dart';
import 'package:clubtivi/data/services/trailer_stream_resolver.dart';
import 'package:clubtivi/features/player/player_screen.dart';
import 'package:clubtivi/features/player/player_service.dart';
import 'package:clubtivi/features/shows/shows_providers.dart';
import 'package:clubtivi/features/shows/stremio_meta_screen.dart';
import 'package:clubtivi/features/shows/trailer_player_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

const _video = MediaVideo(
  name: 'Trailer',
  key: 'testKey',
  kind: VideoKind.trailer,
);

/// Resolutor de mentira: el vídeo es el mismo WAV local, para probar la
/// propiedad de la reproducción y no la red de YouTube.
class _StubResolver implements TrailerStreamResolver {
  _StubResolver(this.url);

  final String url;

  @override
  Future<TrailerStream> resolve(String videoKey) async => TrailerStream(
    url: url,
    qualityLabel: 'test',
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
  );
}

/// WAV PCM 16 bits mono con un tono audible: sirve para saber si el motor
/// sigue reproduciendo aunque no haya imagen.
Uint8List _toneWav({int seconds = 60}) {
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
    final value = (32767 * 0.2 * math.sin(2 * math.pi * 440 * i / rate)).round();
    data.setInt16(44 + i * 2, value, Endian.little);
  }
  return data.buffer.asUint8List();
}

/// MP4 sin pista de audio: dispara el reintento por ffmpeg que la app usa
/// cuando mpv no encuentra audio. Vacío si no hay ffmpeg en el sistema.
Future<Uint8List> _videoWithoutAudio() async {
  final dir = await Directory.systemTemp.createTemp('clubtivi_integration');
  try {
    final file = File('${dir.path}/video_only.mp4');
    final result = await Process.run('ffmpeg', [
      '-hide_banner',
      '-loglevel', 'error',
      '-y',
      '-f', 'lavfi',
      '-i', 'color=c=black:s=160x120:d=20',
      '-c:v', 'libx264',
      '-pix_fmt', 'yuv420p',
      '-preset', 'ultrafast',
      file.path,
    ]);
    if (result.exitCode != 0) return Uint8List(0);
    return await file.readAsBytes();
  } on ProcessException {
    return Uint8List(0);
  } finally {
    await dir.delete(recursive: true);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  late HttpServer server;
  late String streamUrl;
  late String movieStreamUrl;
  late String protectedStreamUrl;
  late String silentVideoUrl;
  late Uint8List wav;
  late Uint8List silentVideo;

  setUpAll(() async {
    HttpOverrides.global = null;
    wav = _toneWav();
    silentVideo = await _videoWithoutAudio();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      // Igual que un CDN que rechaza el hotlink: sin el Referer del addon
      // contesta 403 con HTML, nunca sirve el vídeo.
      if (request.uri.path == '/protected.wav' &&
          request.headers.value('referer') != 'https://cdn.test/') {
        request.response
          ..statusCode = HttpStatus.forbidden
          ..headers.contentType = ContentType.html
          ..write('<html><body>403 Forbidden</body></html>');
        await request.response.close();
        return;
      }
      final isVideo = request.uri.path.endsWith('.mp4');
      final body = isVideo ? silentVideo : wav;
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
      request.response.headers.contentType =
          isVideo ? ContentType('video', 'mp4') : ContentType('audio', 'wav');
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
    streamUrl = 'http://127.0.0.1:${server.port}/live.wav';
    movieStreamUrl = 'http://127.0.0.1:${server.port}/movie.wav';
    protectedStreamUrl = 'http://127.0.0.1:${server.port}/protected.wav';
    silentVideoUrl = 'http://127.0.0.1:${server.port}/video-only.mp4';
  });

  tearDownAll(() => server.close(force: true));

  /// Avanza frames de verdad hasta que [condition] se cumple.
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

  testWidgets('el tráiler para el canal en vivo y el VOD no queda sonando', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        trailerStreamResolverProvider.overrideWithValue(
          _StubResolver(streamUrl),
        ),
      ],
    );
    addTearDown(container.dispose);
    final live = container.read(playerServiceProvider);

    // 1. Canal en vivo sonando.
    await live.play(streamUrl, channelId: 'live-1', channelName: 'Canal');
    await waitUntil(
      tester,
      () => live.player.state.position >= const Duration(seconds: 1),
      reason: 'el canal de prueba no llegó a reproducirse',
    );

    // 2. El tráiler abre su propio motor: el del canal debe quedar parado.
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: TrailerPlayerScreen(video: _video, title: 'Prueba'),
        ),
      ),
    );
    await waitUntil(
      tester,
      () => find.byType(Video).evaluate().isNotEmpty,
      reason: 'el tráiler no abrió su reproductor',
    );
    final trailerPlayer = tester.widget<Video>(find.byType(Video).first)
        .controller
        .player;
    await waitUntil(
      tester,
      () => trailerPlayer.state.position >= const Duration(seconds: 1),
      reason: 'el tráiler no llegó a avanzar',
    );

    expect(live.currentUrl, isNull, reason: 'el canal debe soltarse');
    expect(live.player.state.playing, isFalse);
    final frozen = live.player.state.position;
    await tester.pump(const Duration(seconds: 1));
    expect(
      (live.player.state.position - frozen).inMilliseconds.abs(),
      lessThan(100),
      reason: 'el motor del canal no debe seguir avanzando',
    );

    // 3. Al cerrar el tráiler tampoco vuelve el canal.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(live.currentUrl, isNull);
    expect(live.player.state.playing, isFalse);

    // 4. VOD: al salir del reproductor, no queda audio detrás.
    await live.play(streamUrl, channelName: 'Película');
    await waitUntil(
      tester,
      () => live.player.state.position >= const Duration(seconds: 1),
      reason: 'el VOD de prueba no llegó a reproducirse',
    );
    expect(live.currentUrl, streamUrl);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: PlayerScreen(streamUrl: streamUrl, channelName: 'Película'),
        ),
      ),
    );
    await waitUntil(
      tester,
      () => find.byType(Video).evaluate().isNotEmpty,
      reason: 'el reproductor de VOD no abrió',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(live.currentUrl, isNull, reason: 'el VOD debe pararse al salir');
    expect(live.player.state.playing, isFalse);
  });

  testWidgets('un 403 de CDN en VOD no se guarda como bloqueo de red',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: PlayerScreen(
            streamUrl: protectedStreamUrl,
            channelName: 'Sin referer',
          ),
        ),
      ),
    );

    final store = container.read(channelHealthStoreProvider);
    await waitUntil(
      tester,
      () => store.resultForUrl(protectedStreamUrl) != null,
      timeout: const Duration(seconds: 15),
      reason: 'el sondeo previo no terminó',
    );
    final verdict = store.resultForUrl(protectedStreamUrl)!;
    expect(verdict.status, ProbeStatus.forbidden);
    expect(verdict.verdict, ProbeVerdict.serverSide,
        reason: 'un CDN que rechaza el hotlink no es el ISP');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('el router real entrega las cabeceras al reproductor',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final appRouter = createRouter();
    addTearDown(appRouter.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: appRouter),
      ),
    );
    await tester.pump();

    appRouter.go('/player', extra: {
      'streamUrl': protectedStreamUrl,
      'channelName': 'Protegido',
      'httpHeaders': {'Referer': 'https://cdn.test/'},
    });
    await tester.pump();
    await waitUntil(
      tester,
      () => find.byType(PlayerScreen).evaluate().isNotEmpty,
      reason: 'el router no abrió el reproductor',
    );

    final screen = tester.widget<PlayerScreen>(find.byType(PlayerScreen));
    expect(screen.httpHeaders, {'Referer': 'https://cdn.test/'});
    expect(screen.streamUrl, protectedStreamUrl);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('un VOD que exige Referer reproduce con sus cabeceras',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final live = container.read(playerServiceProvider);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: PlayerScreen(
            streamUrl: protectedStreamUrl,
            channelName: 'Protegido',
            httpHeaders: const {'Referer': 'https://cdn.test/'},
          ),
        ),
      ),
    );

    await waitUntil(
      tester,
      () => live.player.state.position >= const Duration(seconds: 1),
      reason: 'el VOD con Referer no llegó a reproducirse',
    );
    expect(live.lastError, isNull);
    expect(
      find.textContaining('Blocked by the network'),
      findsNothing,
      reason: 'un 403 de CDN no puede reportarse como bloqueo del ISP',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(live.currentUrl, isNull);
  });

  testWidgets(
      'la ficha de Stremio llega al reproductor y deja mudo el canal',
      (tester) async {
    const meta = StremioMeta(
      id: 'tt1234567',
      type: 'movie',
      name: 'Stremio Movie',
      imdbId: 'tt1234567',
    );
    final source = StreamSource(
      id: 'addon:movie',
      providerId: 'addon',
      providerName: 'Addon',
      kind: SourceKind.addon,
      title: 'Direct source',
      url: movieStreamUrl,
    );
    final container = ProviderContainer(
      overrides: [
        stremioMetaProvider.overrideWith((ref, params) async => meta),
        addonStreamsProvider.overrideWith(
          (ref, params) async => StreamSearchResult(sources: [source]),
        ),
        showsRepositoryProvider.overrideWith((ref) async => ShowsRepository()),
      ],
    );
    addTearDown(container.dispose);
    final live = container.read(playerServiceProvider);

    // 1. El canal en vivo está sonando antes de entrar en la ficha.
    await live.play(streamUrl, channelId: 'live-1', channelName: 'Canal');
    await waitUntil(
      tester,
      () => live.player.state.position >= const Duration(seconds: 1),
      reason: 'el canal de prueba no llegó a reproducirse',
    );

    final router = GoRouter(
      initialLocation: '/stremio',
      routes: [
        GoRoute(
          path: '/stremio',
          builder: (context, state) => const StremioMetaScreen(
            initialMeta: meta,
            addonUrl: 'https://addon.test/manifest.json',
          ),
        ),
        GoRoute(
          path: '/player',
          builder: (context, state) {
            final extra = state.extra as Map<String, dynamic>;
            return PlayerScreen(
              streamUrl: extra['streamUrl'] as String? ?? '',
              channelName: extra['channelName'] as String? ?? '',
              channelLogo: extra['channelLogo'] as String?,
            );
          },
        ),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    await tester.pump();

    // 2. Play de Stremio: antes de resolver fuentes, el canal ya se calla.
    await tester.tap(find.text('Play'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await waitUntil(
      tester,
      () => find.text('Select Stream').evaluate().isNotEmpty,
      reason: 'el selector de fuentes no se abrió',
    );
    expect(
      live.currentUrl,
      isNull,
      reason: 'el canal no puede seguir sonando mientras se eligen fuentes',
    );
    expect(live.player.state.playing, isFalse);
    final frozen = live.player.state.position;
    await tester.pump(const Duration(seconds: 1));
    expect(
      (live.player.state.position - frozen).inMilliseconds.abs(),
      lessThan(100),
      reason: 'el motor del canal no debe seguir avanzando',
    );

    // 3. La fuente directa llega al reproductor real y toma el motor.
    await tester.tap(find.text('Direct source'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await waitUntil(
      tester,
      () => find.byType(PlayerScreen).evaluate().isNotEmpty,
      reason: 'el reproductor no se abrió',
    );
    await waitUntil(
      tester,
      () => live.currentUrl == movieStreamUrl,
      reason: 'el VOD no tomó el motor compartido',
    );
    await waitUntil(
      tester,
      () => live.player.state.position >= const Duration(seconds: 1),
      reason: 'el VOD no llegó a reproducirse',
    );

    expect(live.player.state.playlist.medias.first.uri, movieStreamUrl);
    expect(
      live.currentChannelId,
      isNull,
      reason: 'el canal ya no debe estar en el motor',
    );
    expect(live.currentUrl, isNot(streamUrl));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('recargar reabre el mismo canal sin salir del reproductor', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final live = container.read(playerServiceProvider);
    var visits = 0;
    live.onChannelVisited = (id) {
      if (id == 'live-1') visits++;
    };

    await live.play(
      streamUrl,
      channelId: 'live-1',
      epgChannelId: 'epg-1',
      tvgId: 'tvg-1',
      channelName: 'Canal',
      originalName: 'Original',
    );
    await waitUntil(
      tester,
      () => live.player.state.position >= const Duration(seconds: 1),
      reason: 'el canal de prueba no llegó a reproducirse',
    );
    await live.pause();
    await waitUntil(
      tester,
      () => !live.player.state.playing,
      reason: 'el canal no se pausó',
    );
    final pausedAt = live.player.state.position;
    await live.setVolume(35);

    await live.reload();

    expect(
      live.player.state.position,
      lessThan(pausedAt),
      reason: 'la recarga debe volver al directo, no seguir congelada',
    );
    await waitUntil(
      tester,
      () => live.player.state.playing &&
          live.player.state.position >= const Duration(milliseconds: 300),
      reason: 'la recarga no reanudó la reproducción',
    );
    expect(live.currentUrl, streamUrl);
    expect(live.currentChannelId, 'live-1');
    expect(visits, 2, reason: 'la recarga debe contar como una apertura');
    expect(
      live.player.state.volume,
      closeTo(35, 1),
      reason: 'recargar no debe subir el volumen a 100',
    );

    await live.stop();
  });

  testWidgets('parar y reabrir el mismo flujo no revive el reintento viejo', (
    tester,
  ) async {
    if (silentVideo.isEmpty) {
      markTestSkipped('ffmpeg no disponible: no se puede generar el vídeo');
      return;
    }
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final live = container.read(playerServiceProvider);

    // Sin superficie de vídeo mpv no avanza un flujo que sólo tiene imagen.
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: Video(controller: live.videoController)),
      ),
    );

    await live.play(silentVideoUrl, channelName: 'Sin audio');
    final playedAt = DateTime.now();
    await waitUntil(
      tester,
      () => live.player.state.position >= const Duration(milliseconds: 300),
      reason: 'el vídeo sin audio no llegó a reproducirse',
    );

    // A los 3 s el chequeo de audio arranca ffmpeg (~1 s). Se para y se
    // reabre el mismo flujo en plena espera: el reintento viejo ya no manda.
    await waitUntil(
      tester,
      () => DateTime.now().difference(playedAt) > const Duration(seconds: 3),
      reason: 'no llegó el chequeo de audio',
    );
    await Future.wait([
      live.stop(),
      live.play(silentVideoUrl, channelName: 'Sin audio'),
    ]);
    final replayedAt = DateTime.now();

    await waitUntil(
      tester,
      () => live.player.state.position < const Duration(milliseconds: 150),
      reason: 'el reproductor no reinició el flujo',
    );
    await waitUntil(
      tester,
      () => live.player.state.position >= const Duration(milliseconds: 300),
      reason: 'la reproducción nueva no arrancó',
    );
    // El proxy viejo tarda ~1 s en arrancar; si abriera, sustituiría el flujo
    // directo antes de que el reintento de la reproducción nueva llegue a los 3 s.
    await waitUntil(
      tester,
      () =>
          DateTime.now().difference(replayedAt) >
          const Duration(milliseconds: 1500),
      reason: 'no pasó la ventana del reintento viejo',
    );
    expect(live.currentUrl, silentVideoUrl);
    expect(
      live.player.state.playlist.medias.first.uri,
      silentVideoUrl,
      reason: 'un reintento obsoleto no debe sustituir el flujo directo',
    );

    await live.stop();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
