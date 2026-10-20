// El DAO de VOD guarda por clave de contenido, no por URL: un enlace de debrid
// caduca. Estas pruebas fijan la idempotencia, el orden de «continuar viendo» y
// que el release recordado sirva para volver a resolverlo.
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/datasources/local/playback_dao.dart';
import 'package:clubtivi/data/models/playback_request.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const _movie = PlaybackRequest(
  kind: PlaybackKind.movie,
  mediaKey: 'imdb:tt1234567',
  title: 'Dune',
  sourceId: 'torrentio:abc:0',
);

const _episode1 = PlaybackRequest(
  kind: PlaybackKind.series,
  mediaKey: 'imdb:tt7654321',
  season: 1,
  episode: 1,
  title: 'Carrie S01E01',
  sourceId: 'torrentio:abc:0',
);

const _episode2 = PlaybackRequest(
  kind: PlaybackKind.series,
  mediaKey: 'imdb:tt7654321',
  season: 1,
  episode: 2,
  title: 'Carrie S01E02',
  sourceId: 'torrentio:abc:1',
);

const _episode3 = PlaybackRequest(
  kind: PlaybackKind.series,
  mediaKey: 'imdb:tt7654321',
  season: 1,
  episode: 3,
  title: 'Carrie S01E03',
  sourceId: 'torrentio:abc:2',
);

void main() {
  late db.AppDatabase database;
  late PlaybackDao dao;

  setUp(() {
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    dao = PlaybackDao(database);
  });

  tearDown(() => database.close());

  Future<int> count(String table) async {
    final row = await database
        .customSelect('SELECT COUNT(*) AS c FROM $table')
        .getSingle();
    return row.read<int>('c');
  }

  test('guarda el progreso de un capítulo y lo devuelve entero', () async {
    await dao.saveProgress(
      _episode2,
      position: const Duration(minutes: 12),
      duration: const Duration(minutes: 45),
      mediaTitle: 'Carrie',
    );

    final progress = await dao.progressFor(_episode2.contentKey);
    expect(progress, isNotNull);
    expect(progress!.mediaKey, 'imdb:tt7654321');
    expect(progress.season, 1);
    expect(progress.episode, 2);
    expect(progress.position, const Duration(minutes: 12));
    expect(progress.duration, const Duration(minutes: 45));
    expect(progress.completed, isFalse);
  });

  test('progressFor de algo que nunca se abrió es null', () async {
    expect(await dao.progressFor('imdb:tt0000000:s1e1'), isNull);
  });

  test('guardar dos veces la misma clave no duplica filas', () async {
    final first = DateTime(2026, 10, 20, 20);
    await dao.saveProgress(
      _episode2,
      position: const Duration(minutes: 5),
      duration: const Duration(minutes: 45),
      mediaTitle: 'Carrie',
      at: first,
    );
    await dao.saveProgress(
      _episode2,
      position: const Duration(minutes: 9),
      duration: const Duration(minutes: 45),
      mediaTitle: 'Carrie',
      at: first.add(const Duration(minutes: 1)),
    );

    expect(await count('playback_progress'), 1);
    expect(
      await count('media_titles'),
      1,
      reason: 'dos guardados del mismo episodio no duplican el título',
    );
    final progress = await dao.progressFor(_episode2.contentKey);
    expect(progress!.position, const Duration(minutes: 9));
  });

  test('recentlyWatched va de lo último a lo primero y respeta el límite',
      () async {
    final start = DateTime(2026, 10, 20, 20);
    for (final (index, episode) in [_episode1, _episode2, _episode3].indexed) {
      await dao.saveProgress(
        episode,
        position: Duration(minutes: 1 + index),
        duration: const Duration(minutes: 45),
        mediaTitle: 'Carrie',
        at: start.add(Duration(minutes: index)),
      );
    }

    final top = await dao.recentlyWatched(limit: 2);
    expect(top.map((row) => row.progress.episode), [3, 2]);
    expect(top.first.media.title, 'Carrie');
    expect(top.first.media.kind, 'series');
    expect(
      await count('media_titles'),
      1,
      reason: 'tres capítulos comparten un único título',
    );

    final all = await dao.recentlyWatched();
    expect(all.map((row) => row.progress.episode), [3, 2, 1]);
  });

  test('lo terminado sale de «continuar viendo» salvo que se pida', () async {
    final start = DateTime(2026, 10, 20, 20);
    await dao.saveProgress(
      _movie,
      position: const Duration(hours: 2),
      duration: const Duration(hours: 2),
      completed: true,
      at: start,
    );
    await dao.saveProgress(
      _episode2,
      position: const Duration(minutes: 10),
      duration: const Duration(minutes: 45),
      mediaTitle: 'Carrie',
      at: start.add(const Duration(minutes: 1)),
    );

    final continuing = await dao.recentlyWatched();
    expect(continuing, hasLength(1));
    expect(
      continuing.single.media.title,
      'Carrie',
      reason: 'la película terminada no se sigue viendo',
    );

    final includingFinished = await dao.recentlyWatched(includeCompleted: true);
    expect(includingFinished, hasLength(2));
    expect(
      includingFinished.map((row) => row.progress.completed),
      [false, true],
    );
  });

  test('recordSource guarda el release sin URL', () async {
    await dao.recordSource(
      _episode2,
      providerId: 'torrentio',
      infoHash: 'ABCDEF0123456789ABCDEF0123456789ABCDEF01',
      fileIdx: 3,
      quality: '1080p',
      sizeBytes: 1470000000,
    );

    final source = await dao.sourceFor(_episode2.mediaKey, _episode2.sourceId);
    expect(source, isNotNull);
    expect(source!.sourceId, 'torrentio:abc:1');
    expect(source.providerId, 'torrentio');
    expect(source.infoHash, 'ABCDEF0123456789ABCDEF0123456789ABCDEF01');
    expect(source.fileIdx, 3);
    expect(source.quality, '1080p');
    expect(source.sizeBytes, 1470000000);
    expect(source.failCount, 0);

    final columns = await database
        .customSelect('PRAGMA table_info(playback_sources)')
        .get();
    final names = columns.map((row) => row.read<String>('name')).toList();
    expect(
      names.where((name) => name.contains('url')),
      isEmpty,
      reason: 'la URL resuelta caduca: se guarda cómo volver a resolverla',
    );
  });

  test('volver a elegir el release no duplica la fila y perdona los fallos',
      () async {
    await dao.recordSource(
      _episode2,
      providerId: 'torrentio',
      infoHash: 'ABCDEF',
      fileIdx: 3,
    );
    await database.customUpdate('UPDATE playback_sources SET fail_count = 2');

    await dao.recordSource(
      _episode2,
      providerId: 'torrentio',
      infoHash: 'ABCDEF',
      fileIdx: 4,
    );

    expect(await count('playback_sources'), 1);
    final source = await dao.sourceFor(_episode2.mediaKey, _episode2.sourceId);
    expect(source!.fileIdx, 4);
    expect(
      source.failCount,
      0,
      reason: 'elegirlo otra vez significa que acaba de funcionar',
    );
  });
}
