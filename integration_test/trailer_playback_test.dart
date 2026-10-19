// Ejercicio real (motor y renderizado de Windows) de la reproducción de
// vídeos dentro de la app:
//
//   flutter test integration_test/trailer_playback_test.dart -d windows
//
// Necesita red: el primer caso resuelve y reproduce un tráiler de YouTube con
// el mismo motor (mpv) que usa el reproductor de canales, y comprueba que el
// vídeo avanza de verdad. El segundo caso no toca la red: fija un resolutor que
// falla y comprueba que la pantalla lo explica y ofrece YouTube en vez de
// quedarse en negro.
import 'dart:io';

import 'package:clubtivi/data/models/media_video.dart';
import 'package:clubtivi/data/services/trailer_stream_resolver.dart';
import 'package:clubtivi/features/shows/trailer_player_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

const _video = MediaVideo(
  name: 'Trailer',
  key: 'TcMBFSGVi1c',
  kind: VideoKind.trailer,
  official: true,
);

/// Resolutor que siempre falla, para el camino de degradación.
class _FailingResolver implements TrailerStreamResolver {
  @override
  Future<TrailerStream> resolve(String videoKey) async {
    throw const TrailerUnavailable('No hay conexión con YouTube.');
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  setUpAll(() {
    // flutter_test deja todos los HttpClient devolviendo 400 y sin tocar la
    // red; este ejercicio sí quiere red de verdad, así que se devuelve el
    // comportamiento normal del sistema.
    HttpOverrides.global = null;
  });

  /// Avanza el reloj del test hasta que [condition] se cumple o se agota.
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
    // Lo que hubiera en pantalla explica mejor que un «timeout» a secas.
    final visible = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data);
    fail('$reason. En pantalla: ${visible.join(' | ')}');
  }

  testWidgets('el tráiler se reproduce dentro de la app', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: TrailerPlayerScreen(video: _video, title: 'Prueba'),
        ),
      ),
    );

    await waitUntil(
      tester,
      () => find.byType(Video).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 30),
      reason: 'el vídeo no llegó a abrirse en el reproductor de la app',
    );

    final widget = tester.widget<Video>(find.byType(Video).first);
    final player = widget.controller.player;

    await waitUntil(
      tester,
      () => player.state.position >= const Duration(seconds: 1),
      timeout: const Duration(seconds: 30),
      reason: 'mpv abrió el vídeo pero no llegó a reproducir nada',
    );

    expect(player.state.duration, greaterThan(Duration.zero));
    expect(
      player.state.position,
      greaterThanOrEqualTo(const Duration(seconds: 1)),
      reason: 'el vídeo debe avanzar, no sólo cargar',
    );
    expect(
      player.state.playlist.medias.first.uri,
      contains('googlevideo.com'),
      reason: 'el reproductor debe estar abriendo el flujo resuelto de YouTube',
    );
    expect(
      find.text('Ver en YouTube'),
      findsNothing,
      reason: 'no debe degradarse cuando el vídeo se ve dentro',
    );
  });

  testWidgets(
    'sin poder resolver, ofrece YouTube en vez de quedarse en negro',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            trailerStreamResolverProvider.overrideWithValue(_FailingResolver()),
          ],
          child: const MaterialApp(
            home: TrailerPlayerScreen(video: _video, title: 'Prueba'),
          ),
        ),
      );

      await waitUntil(
        tester,
        () => find.text('Ver en YouTube').evaluate().isNotEmpty,
        reason: 'la pantalla no ofreció la salida al navegador',
      );

      expect(find.text('No hay conexión con YouTube.'), findsOneWidget);
      expect(find.text('Reintentar'), findsOneWidget);
    },
  );
}
