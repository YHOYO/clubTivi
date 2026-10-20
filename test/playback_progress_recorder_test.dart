// El grabador es el único dueño de cuándo se escribe: como mucho cada 10 s y
// siempre que el tiempo se perdería (pausa, salida, segundo plano).
import 'dart:async';

import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/datasources/local/playback_dao.dart';
import 'package:clubtivi/data/models/playback_request.dart';
import 'package:clubtivi/features/player/playback_progress_recorder.dart';
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';

const _episode = PlaybackRequest(
  kind: PlaybackKind.series,
  mediaKey: 'imdb:tt7654321',
  season: 1,
  episode: 2,
  title: 'Carrie S01E02',
  sourceId: 'torrentio:abc:1',
);

/// Reloj de mentira: el intervalo de 10 s no se espera de verdad.
class _Clock {
  DateTime now = DateTime(2026, 10, 20, 20);

  void advance(Duration delta) => now = now.add(delta);
}

void main() {
  late db.AppDatabase database;
  late PlaybackDao dao;
  late StreamController<Duration> positions;
  late StreamController<Duration> durations;
  late StreamController<bool> playing;
  late _Clock clock;
  late PlaybackProgressRecorder recorder;

  setUp(() {
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    dao = PlaybackDao(database);
    positions = StreamController<Duration>.broadcast();
    durations = StreamController<Duration>.broadcast();
    playing = StreamController<bool>.broadcast();
    clock = _Clock();
  });

  tearDown(() async {
    await recorder.dispose();
    await positions.close();
    await durations.close();
    await playing.close();
    await database.close();
  });

  void build({String? mediaTitle}) {
    recorder = PlaybackProgressRecorder(
      dao: dao,
      request: _episode,
      positions: positions.stream,
      durations: durations.stream,
      playing: playing.stream,
      mediaTitle: mediaTitle,
      now: () => clock.now,
    )..start();
  }

  Future<Duration?> savedPosition() async {
    final row = await dao.progressFor(_episode.contentKey);
    return row?.position;
  }

  test('no escribe más de una vez cada diez segundos', () async {
    build();
    durations.add(const Duration(minutes: 45));

    positions.add(const Duration(minutes: 1));
    await pumpEventQueue();
    expect(await savedPosition(), isNull, reason: 'al abrir no toca guardar');

    clock.advance(const Duration(seconds: 5));
    positions.add(const Duration(minutes: 1, seconds: 5));
    await pumpEventQueue();
    expect(await savedPosition(), isNull, reason: 'aún no pasaron 10 s');

    clock.advance(const Duration(seconds: 5));
    positions.add(const Duration(minutes: 1, seconds: 10));
    await pumpEventQueue();
    expect(await savedPosition(), const Duration(minutes: 1, seconds: 10));

    clock.advance(const Duration(seconds: 2));
    positions.add(const Duration(minutes: 1, seconds: 12));
    await pumpEventQueue();
    expect(
      await savedPosition(),
      const Duration(minutes: 1, seconds: 10),
      reason: 'se queda con la última escritura, no con cada tick',
    );
  });

  test('pausar escribe en el acto', () async {
    build();
    durations.add(const Duration(minutes: 45));
    playing.add(true);
    positions.add(const Duration(minutes: 12));
    await pumpEventQueue();
    expect(await savedPosition(), isNull);

    playing.add(false);
    await pumpEventQueue();

    expect(await savedPosition(), const Duration(minutes: 12));
  });

  test('salir de la pantalla escribe lo último visto', () async {
    build();
    durations.add(const Duration(minutes: 45));
    playing.add(true);
    positions.add(const Duration(minutes: 7));
    await pumpEventQueue();

    await recorder.dispose();

    expect(await savedPosition(), const Duration(minutes: 7));
  });

  test('pasar a segundo plano escribe', () async {
    build();
    durations.add(const Duration(minutes: 45));
    playing.add(true);
    positions.add(const Duration(minutes: 3));
    await pumpEventQueue();

    await recorder.handleLifecycle(AppLifecycleState.paused);

    expect(await savedPosition(), const Duration(minutes: 3));
  });

  test('volver al primer plano no escribe', () async {
    build();
    durations.add(const Duration(minutes: 45));
    positions.add(const Duration(minutes: 3));
    await pumpEventQueue();

    await recorder.handleLifecycle(AppLifecycleState.resumed);

    expect(await savedPosition(), isNull);
  });

  test('sin duración no inventa un porcentaje', () async {
    build();
    positions.add(const Duration(minutes: 12));
    await pumpEventQueue();

    await recorder.flush();

    expect(await savedPosition(), isNull);
  });

  test('al 96 % guarda el capítulo como terminado', () async {
    build();
    durations.add(const Duration(minutes: 45));
    playing.add(true);
    positions.add(const Duration(minutes: 43, seconds: 30));
    await pumpEventQueue();

    await recorder.flush();

    final row = await dao.progressFor(_episode.contentKey);
    expect(row!.completed, isTrue);
  });

  test('el título se guarda sin el código de episodio', () async {
    build(mediaTitle: 'Carrie');
    durations.add(const Duration(minutes: 45));
    playing.add(true);
    positions.add(const Duration(minutes: 20));
    await pumpEventQueue();

    await recorder.flush();

    final recent = await dao.recentlyWatched();
    expect(recent.single.media.title, 'Carrie');
  });
}
