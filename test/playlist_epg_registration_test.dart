// La parrilla salía vacía porque nadie registraba la guía que la propia lista
// anuncia en su cabecera (#EXTM3U url-tvg="…"). Esta prueba levanta un servidor
// local con una lista y su guía y comprueba la cadena entera: lista → fuente
// EPG → programas guardados.
import 'dart:async';
import 'dart:io';

import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/features/providers/provider_manager.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const _guide = '''<?xml version="1.0" encoding="UTF-8"?>
<tv>
  <channel id="La1.TV"><display-name>La 1</display-name></channel>
  <programme start="%START%" stop="%STOP%" channel="La1.TV">
    <title>Telediario</title>
  </programme>
</tv>
''';

void main() {
  late HttpServer server;
  late db.AppDatabase database;
  late ProviderManager manager;

  String xmltvTime(DateTime t) {
    final u = t.toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${u.year}${two(u.month)}${two(u.day)}${two(u.hour)}'
        '${two(u.minute)}${two(u.second)} +0000';
  }

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final now = DateTime.now();
    final guide = _guide
        .replaceFirst('%START%', xmltvTime(now.subtract(const Duration(minutes: 10))))
        .replaceFirst('%STOP%', xmltvTime(now.add(const Duration(minutes: 50))));

    server.listen((request) async {
      switch (request.uri.path) {
        case '/list.m3u8':
          request.response.write('#EXTM3U url-tvg="http://127.0.0.1:'
              '${server.port}/guide.xml"\n'
              '#EXTINF:-1 tvg-id="La1.TV" group-title="Generalistas",La 1\n'
              'http://example.com/la1.m3u8\n'
              '#EXTINF:-1 tvg-id="La2.TV" group-title="Generalistas",La 2\n'
              'http://example.com/la2.m3u8\n');
        case '/no-guide.m3u8':
          request.response.write('#EXTM3U\n'
              '#EXTINF:-1,Otro\n'
              'http://example.com/otro.m3u8\n');
        case '/guide.xml':
          request.response
            ..headers.contentType = ContentType('application', 'xml')
            ..write(guide);
        default:
          request.response.statusCode = 404;
      }
      await request.response.close();
    });

    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    manager = ProviderManager(database);
  });

  tearDown(() async {
    await database.close();
    await server.close(force: true);
  });

  String url(String path) => 'http://127.0.0.1:${server.port}$path';

  Future<db.EpgSource?> sourceFor(String providerId) async {
    final sources = await database.getAllEpgSources();
    return sources.where((s) => s.id == '$providerId-playlist-epg').firstOrNull;
  }

  Future<int> programmeCount() async =>
      (await database.select(database.epgProgrammes).get()).length;

  test('adding a playlist registers the guide it announces', () async {
    await manager.addM3uProvider(id: 'p1', name: 'TDT', url: url('/list.m3u8'));

    final source = await sourceFor('p1');
    expect(source, isNotNull);
    expect(source!.url, url('/guide.xml'));
    expect(source.name, contains('TDT'));
    expect((await database.getChannelsForProvider('p1')).length, 2);

    // La descarga de la guía va en segundo plano: se espera a que aparezca.
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (await programmeCount() == 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(await programmeCount(), greaterThan(0));
  });

  test('a playlist without url-tvg registers no guide', () async {
    await manager.addM3uProvider(
        id: 'p2', name: 'Sin guía', url: url('/no-guide.m3u8'));

    expect(await sourceFor('p2'), isNull);
    expect(await database.getAllEpgSources(), isEmpty);
  });

  test('providers added earlier get their guide at startup, only once',
      () async {
    // Como quedó un proveedor añadido antes de que existiera el registro.
    await database.upsertProvider(db.ProvidersCompanion.insert(
      id: 'p3',
      name: 'TDT viejo',
      type: 'm3u',
      url: Value(url('/list.m3u8')),
    ));

    expect(await manager.registerPlaylistEpgSources(), 1);
    expect((await sourceFor('p3'))!.url, url('/guide.xml'));
    // Idempotente: no duplica ni repite la descarga en cada arranque.
    expect(await manager.registerPlaylistEpgSources(), 0);
  });

  test('a local playlist file also declares its guide', () async {
    final file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}clubtivi-epg-test.m3u8')
      ..writeAsStringSync('#EXTM3U url-tvg="${url('/guide.xml')}"\n'
          '#EXTINF:-1 tvg-id="La1.TV",La 1\n'
          'http://example.com/la1.m3u8\n');
    addTearDown(() => file.deleteSync());

    await manager.addM3uProvider(
        id: 'p4', name: 'Fichero', url: file.path);

    expect((await sourceFor('p4'))!.url, url('/guide.xml'));
  });
}
