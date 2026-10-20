// Subir de la 6 a la 7 sólo añade las tablas de VOD. Lo que ya funcionaba
// —canales, EPG, favoritos de canales, proveedores— tiene que quedar idéntico
// y las tablas nuevas tienen que existir vacías.
import 'dart:io';

import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const _newTables = [
  'media_titles',
  'playback_progress',
  'playback_sources',
  'media_favorites',
  'series_state',
];

void main() {
  test('una base v6 sube a v7 sin perder canales, EPG ni favoritos', () async {
    final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'clubtivi-v7-${DateTime.now().microsecondsSinceEpoch}.db',
    );
    addTearDown(() {
      for (final suffix in ['', '-wal', '-shm']) {
        final f = File('${file.path}$suffix');
        if (f.existsSync()) f.deleteSync();
      }
    });

    // Una base con los datos de un usuario: proveedor Xtream, dos canales, una
    // guía con su programa y una lista de favoritos.
    final created = db.AppDatabase.forTesting(NativeDatabase(file));
    await created.upsertProvider(
      db.ProvidersCompanion.insert(
        id: 'p1',
        name: 'Provider',
        type: 'xtream',
        username: const Value('user'),
        password: const Value('secret'),
      ),
    );
    await created.upsertChannels([
      db.ChannelsCompanion.insert(
        id: 'c1',
        providerId: 'p1',
        name: 'La 1',
        groupTitle: const Value('General'),
        channelNumber: const Value(1),
        streamUrl: 'http://example.com/la1.m3u8',
        httpHeaders: const Value('{"Referer":"https://cdn.test/"}'),
      ),
      db.ChannelsCompanion.insert(
        id: 'c2',
        providerId: 'p1',
        name: 'La 2',
        groupTitle: const Value('General'),
        streamUrl: 'http://example.com/la2.m3u8',
        hidden: const Value(true),
      ),
    ]);
    await created.upsertEpgSource(
      db.EpgSourcesCompanion.insert(
        id: 'epg1',
        name: 'Guía',
        url: 'http://example.com/epg.xml',
      ),
    );
    await created.upsertEpgChannels([
      db.EpgChannelsCompanion.insert(
        id: 'epg1-bbc1',
        sourceId: 'epg1',
        channelId: 'BBC1',
        displayName: 'BBC One',
      ),
    ]);
    await created.insertProgrammes([
      db.EpgProgrammesCompanion.insert(
        epgChannelId: 'epg1-bbc1',
        sourceId: 'epg1',
        title: 'News',
        start: DateTime(2026, 10, 20, 20),
        stop: DateTime(2026, 10, 20, 21),
        description: const Value('Telediario'),
      ),
    ]);
    final list = await created.createFavoriteList('Sports');
    await created.addChannelToList(list.id, 'c1');
    await created.addChannelToList(list.id, 'c2');

    // Lo que una instalación en la 6 tenía: las cinco tablas de VOD no existían.
    for (final table in _newTables.reversed) {
      await created.customStatement('DROP TABLE $table');
    }
    await created.customStatement('PRAGMA user_version = 6');
    await created.close();

    final reopened = db.AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(reopened.close);

    final version =
        await reopened.customSelect('PRAGMA user_version').getSingle();
    expect(
      version.read<int>('user_version'),
      7,
      reason: 'la migración tiene que dejar la base al día',
    );

    // Canales: mismos valores, incluidos los que se añadieron en la 6.
    final channels = await reopened.getAllChannels();
    expect(channels, hasLength(2));
    final la1 = channels.firstWhere((c) => c.id == 'c1');
    expect(la1.name, 'La 1');
    expect(la1.groupTitle, 'General');
    expect(la1.channelNumber, 1);
    expect(la1.streamUrl, 'http://example.com/la1.m3u8');
    expect(la1.httpHeaders, '{"Referer":"https://cdn.test/"}');
    expect(la1.favorite, isFalse);
    final la2 = channels.firstWhere((c) => c.id == 'c2');
    expect(la2.hidden, isTrue, reason: 'una fila oculta sigue oculta');

    // EPG: el programa sigue donde estaba, con sus campos de la 4.
    final programmes = await reopened.getProgrammes(
      epgChannelId: 'epg1-bbc1',
      start: DateTime(2026, 10, 20),
      end: DateTime(2026, 10, 21),
    );
    expect(programmes, hasLength(1));
    expect(programmes.single.title, 'News');
    expect(programmes.single.description, 'Telediario');

    // Favoritos de canales: la lista y sus dos miembros.
    final favorites = await reopened.getChannelsInList(list.id);
    expect(favorites.map((c) => c.id), unorderedEquals(['c1', 'c2']));

    // Proveedor: las credenciales Xtream siguen donde estaban.
    final providers = await reopened.getAllProviders();
    expect(providers.single.username, 'user');
    expect(providers.single.password, 'secret');

    // Y las cinco tablas nuevas existen, vacías.
    for (final table in _newTables) {
      final count = await reopened
          .customSelect('SELECT COUNT(*) AS c FROM $table')
          .getSingle();
      expect(
        count.read<int>('c'),
        0,
        reason: '$table debe existir y estar vacía tras migrar',
      );
    }
  });
}
