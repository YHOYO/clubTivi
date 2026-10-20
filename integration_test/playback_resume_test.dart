// Punta a punta real del progreso: se abre un VOD con identidad, el motor
// reanuda donde se dejó, se sale de la pantalla (lo que escribe el grabador) y
// se vuelve a abrir en la misma posición.
//
//   flutter test integration_test/playback_resume_test.dart -d windows
//
// El «capítulo» es un WAV de cinco minutos servido por este mismo test en
// loopback: mpv avanza posición de verdad, así que el seek que se comprueba es
// un seek real, no una línea de log. La base es la de producción vista por
// `databaseProvider`, sustituida por una en memoria.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/datasources/local/playback_dao.dart';
import 'package:clubtivi/data/models/playback_request.dart';
import 'package:clubtivi/features/player/player_screen.dart';
import 'package:clubtivi/features/player/player_service.dart';
import 'package:clubtivi/features/providers/provider_manager.dart'
    show databaseProvider;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

const _episode = PlaybackRequest(
  kind: PlaybackKind.series,
  mediaKey: 'imdb:tt7654321',
  season: 1,
  episode: 1,
  title: 'Carrie S01E01',
  sourceId: 'torrentio:carrie:1',
);

/// Segundos del WAV: la duración que mpv reporta y con la que se mide el
/// porcentaje.
const _clipSeconds = 300;

/// WAV PCM 16 bits mono; sin imagen, pero con reloj de reproducción.
Uint8List _toneWav({int seconds = _clipSeconds}) {
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
  late String url;

  setUpAll(() async {
    HttpOverrides.global = null;
    final wav = _toneWav();
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
    url = 'http://127.0.0.1:${server.port}/episode.wav';
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

  /// Monta el reproductor real detrás de una pantalla con un botón, para poder
  /// salir y volver a entrar como hace el usuario.
  Future<(GoRouter, db.AppDatabase, PlayerService)> pumpPlayer(
    WidgetTester tester, {
    PlaybackRequest? playback,
  }) async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    addTearDown(container.dispose);
    addTearDown(database.close);

    final player = container.read(playerServiceProvider);
    final extra = <String, dynamic>{
      'streamUrl': url,
      'channelName': playback?.title ?? 'Canal',
      'playback': ?playback,
    };
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => context.push('/player', extra: extra),
                child: const Text('PLAY'),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/player',
          builder: (context, state) => PlayerScreen.fromExtra(state.extra),
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
    return (router, database, player);
  }

  testWidgets('abre, reanuda, sale y vuelve a reanudar en el mismo punto',
      (tester) async {
    final (router, database, player) = await pumpPlayer(
      tester,
      playback: _episode,
    );
    final dao = PlaybackDao(database);

    // Se dejó a los 60 s de un capítulo de 300 s: por encima del mínimo de 30 s
    // y lejos del 95 %.
    await dao.saveProgress(
      _episode,
      position: const Duration(seconds: 60),
      duration: const Duration(seconds: _clipSeconds),
      mediaTitle: 'Carrie',
    );

    await tester.tap(find.text('PLAY'));
    await tester.pump();

    await waitUntil(
      tester,
      () => player.player.state.position >= const Duration(seconds: 58),
      reason: 'el reproductor debía reanudar en el minuto 1',
    );

    // Sale de la pantalla: el grabador escribe lo último visto.
    router.pop();
    await tester.pumpAndSettle();

    // El guardado es asíncrono: se espera a que la fila pase de los 60 s que
    // había antes de abrir, que es la prueba de que se escribió al salir y no
    // se reinició a cero.
    var saved = await dao.progressFor(_episode.contentKey);
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline) &&
        (saved == null || saved.position <= const Duration(seconds: 60))) {
      await tester.pump(const Duration(milliseconds: 100));
      saved = await dao.progressFor(_episode.contentKey);
    }

    expect(saved, isNotNull);
    expect(
      saved!.position,
      greaterThan(const Duration(seconds: 60)),
      reason: 'salir no puede reiniciar el progreso a cero',
    );

    // Y al volver a abrir, otra vez en el mismo punto.
    await tester.tap(find.text('PLAY'));
    await tester.pump();
    await waitUntil(
      tester,
      () => player.player.state.position >= saved!.position,
      reason: 'la segunda apertura debía reanudar también',
    );
  });

  testWidgets('un canal sin identidad no escribe progreso', (tester) async {
    final (router, database, player) = await pumpPlayer(tester);

    await tester.tap(find.text('PLAY'));
    await tester.pump();
    await waitUntil(
      tester,
      () => player.player.state.position > Duration.zero,
      reason: 'el canal debía empezar a reproducir',
    );

    router.pop();
    await tester.pumpAndSettle();

    final rows = await database
        .customSelect('SELECT COUNT(*) AS c FROM playback_progress')
        .getSingle();
    expect(rows.read<int>('c'), 0);
    final titles = await database
        .customSelect('SELECT COUNT(*) AS c FROM media_titles')
        .getSingle();
    expect(titles.read<int>('c'), 0);
  });
}
