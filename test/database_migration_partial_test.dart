// Una instalación puede quedar con la columna http_headers pero user_version
// todavía en 5 (builds intermedias). La migración a 6 intentaba añadirla otra
// vez, SQLite respondía "duplicate column name" y la app se quedaba para
// siempre en «Loading providers…». Debe ser idempotente.
import 'dart:io';

import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('abre una base en la version 5 que ya tiene http_headers', () async {
    final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'clubtivi-migration-${DateTime.now().microsecondsSinceEpoch}.db',
    );
    addTearDown(() {
      for (final suffix in ['', '-wal', '-shm']) {
        final f = File('${file.path}$suffix');
        if (f.existsSync()) f.deleteSync();
      }
    });

    // Una base al día (versión 6) con un canal.
    final created = db.AppDatabase.forTesting(NativeDatabase(file));
    await created.upsertProvider(
      db.ProvidersCompanion.insert(id: 'p1', name: 'Provider', type: 'm3u'),
    );
    await created.upsertChannels([
      db.ChannelsCompanion.insert(
        id: 'c1',
        providerId: 'p1',
        name: 'Canal',
        streamUrl: 'http://example.com/c.m3u8',
      ),
    ]);
    // Se deja como la dejaron las builds intermedias: columna presente, pero
    // la versión todavía en 5.
    await created.customStatement('PRAGMA user_version = 5');
    await created.close();

    // La app actual la abre: la migración no reventa y los datos siguen ahí.
    final reopened = db.AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(reopened.close);
    final channels = await reopened.getAllChannels();
    expect(channels, hasLength(1));
    expect(channels.single.id, 'c1');

    final version = await reopened
        .customSelect('PRAGMA user_version')
        .getSingle();
    // La versión actual del esquema: 7 desde que el VOD estrenó sus tablas.
    expect(version.read<int>('user_version'), 7,
        reason: 'la migración debe completarse y dejar la base al día');
  });
}
