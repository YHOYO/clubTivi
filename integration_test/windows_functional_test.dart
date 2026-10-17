// Arnés de verificación funcional de clubTivi en Windows.
//
// Corre sobre la app real (mismo código de producción) contra los fixtures
// locales servidos por .dev/fixtures_server.py, así que no necesita cuenta de
// IPTV ni credenciales:
//
//   python .dev/generate_fixtures.py 8899
//   python .dev/fixtures_server.py 8899
//   flutter test integration_test/windows_functional_test.dart -d windows
//
// Verifica, extremo a extremo: parseo M3U por HTTP, almacenamiento en SQLite,
// EPG XMLTV + auto-mapping, la pantalla de canales, la reproducción real con
// media_kit (libmpv) y el failover de un Smart Channel.

import 'dart:io';

import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/models/channel.dart' as models;
import 'package:clubtivi/data/models/epg.dart' as epg_models;
import 'package:clubtivi/data/services/epg_auto_mapper.dart';
import 'package:clubtivi/data/services/epg_refresh_service.dart';
import 'package:clubtivi/features/channels/channels_screen.dart';
import 'package:clubtivi/features/player/player_screen.dart';
import 'package:clubtivi/features/player/player_service.dart';
import 'package:clubtivi/features/providers/provider_manager.dart';
import 'package:drift/drift.dart' show countAll;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Puerto donde corre `.dev/fixtures_server.py`.
const int kFixturePort = int.fromEnvironment('FIXTURE_PORT', defaultValue: 8899);

String fixtureUrl(String path) => 'http://127.0.0.1:$kFixturePort$path';

/// Espera activa hasta que [condition] se cumpla o venza [timeout].
Future<bool> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 30),
  Duration step = const Duration(milliseconds: 250),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return true;
    await Future<void>.delayed(step);
  }
  return condition();
}

/// Diagnóstico: vuelca las propiedades de mpv que explican por qué un stream no
/// arranca (o por qué el monitor de failover no lo ve como atascado).
Future<void> dumpMpv(PlayerService service, String tag) async {
  const keys = <String>[
    'mpv-version',
    'path',
    'file-loaded',
    'idle-active',
    'core-idle',
    'paused-for-cache',
    'duration',
    'time-pos',
    'pause',
    'aid',
    'demuxer-cache-duration',
    'cache-duration',
    'demuxer-readahead-secs',
    'cache',
    'cache-secs',
    'video-format',
    'audio-codec-name',
    'ao',
    'vo',
    'af',
    'eof-reached',
  ];
  for (final key in keys) {
    final value = await service.getMpvProperty(key);
    // ignore: avoid_print
    print('[verify] mpv[$tag] $key = ${value?.replaceAll('\n', ' ')}');
  }
}

/// Router mínimo con las rutas que usan las pantallas bajo prueba.
GoRouter testRouter(Widget home) => GoRouter(
      routes: <RouteBase>[
        GoRoute(path: '/', builder: (context, state) => home),
        for (final path in const <String>[
          '/player',
          '/settings',
          '/providers',
          '/shows',
          '/guide',
          '/epg-mapping',
        ])
          GoRoute(
            path: path,
            builder: (context, state) => const Scaffold(body: SizedBox.shrink()),
          ),
      ],
    );

/// Crea una base de datos en memoria y la carga con la playlist del fixture.
Future<db.AppDatabase> seededDatabase({
  bool withEpg = false,
}) async {
  final database = db.AppDatabase.forTesting(NativeDatabase.memory());
  final manager = ProviderManager(database);
  await manager.addM3uProvider(
    id: 'fixture-provider',
    name: 'Fixture provider',
    url: fixtureUrl('/playlist.m3u'),
  );

  if (withEpg) {
    await database.upsertEpgSource(db.EpgSourcesCompanion.insert(
      id: 'fixture-epg',
      name: 'Fixture EPG',
      url: fixtureUrl('/epg.xml'),
    ));
    await EpgRefreshService(database).refreshSource('fixture-epg');
  }
  return database;
}

models.Channel toModelChannel(db.Channel row) => models.Channel(
      id: row.id,
      providerId: row.providerId,
      name: row.name,
      tvgId: row.tvgId,
      tvgName: row.tvgName,
      tvgLogo: row.tvgLogo,
      groupTitle: row.groupTitle,
      channelNumber: row.channelNumber,
      streamUrl: row.streamUrl,
      streamType: row.streamType == 'vod'
          ? models.StreamType.vod
          : row.streamType == 'series'
              ? models.StreamType.series
              : models.StreamType.live,
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // Necesario antes de crear cualquier Player de media_kit.
    MediaKit.ensureInitialized();
  });

  setUp(() {
    // Preferencias limpias: si no, la pantalla de canales restaura el grupo de
    // la última sesión real de este equipo y la lista sale filtrada.
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('pipeline de datos con el fixture local', () {
    test('M3U: descarga, parsea y guarda los canales servidos por HTTP',
        () async {
      final database = await seededDatabase();
      addTearDown(database.close);

      final channels = await database.getAllChannels();
      expect(channels.length, 7,
          reason: 'el fixture declara 7 entradas (6 canales + 1 roto)');

      final names = channels.map((c) => c.name).toSet();
      expect(names, contains('CT Test News'));
      expect(names, contains('US| CT Test News 24'));

      final groups = channels.map((c) => c.groupTitle).toSet();
      expect(groups, containsAll(<String>['Noticias', 'Deportes', 'Peliculas', 'Radio']));

      final withTvgId = channels.where((c) => (c.tvgId ?? '').isNotEmpty);
      expect(withTvgId.length, 4,
          reason: 'solo 4 entradas del fixture declaran tvg-id');

      final dead = channels.firstWhere((c) => c.name == 'CT Dead Stream');
      expect(dead.streamUrl, contains(':9/'));
    });

    test('EPG: descarga el XMLTV del fixture y guarda programas', () async {
      final database = await seededDatabase(withEpg: true);
      addTearDown(database.close);

      final epgChannels = await database.getEpgChannelsForSource('fixture-epg');
      expect(epgChannels.length, 6);

      final programmes =
          await database.select(database.epgProgrammes).get();
      expect(programmes.length, 24,
          reason: '6 canales de guía x 4 programas por canal');

      final nowPlaying = await database
          .getNowPlaying(epgChannels.map((c) => c.id).toList());
      expect(nowPlaying, isNotEmpty,
          reason: 'el fixture incluye un programa en emisión ahora mismo');
    });

    test('EPG grande: refresca 180 000 programas con memoria acotada', () async {
      final dir = await Directory.systemTemp.createTemp('clubtivi-epg-');
      final file = File('${dir.path}${Platform.pathSeparator}epg.sqlite');
      final database = db.AppDatabase.forFile(file);
      addTearDown(() async {
        await database.close();
        await dir.delete(recursive: true);
      });

      await database.upsertEpgSource(db.EpgSourcesCompanion.insert(
        id: 'fixture-epg-large',
        name: 'Fixture EPG grande',
        url: fixtureUrl('/epg-large.xml.gz'),
      ));

      final rssBefore = ProcessInfo.currentRss;
      final stopwatch = Stopwatch()..start();
      await EpgRefreshService(database).refreshSource('fixture-epg-large');
      stopwatch.stop();
      final rssAfter = ProcessInfo.currentRss;

      final countQuery = database.selectOnly(database.epgProgrammes)
        ..addColumns([countAll()]);
      final stored = await countQuery
          .map((row) => row.read(countAll()) ?? 0)
          .getSingle();

      double mb(int bytes) => bytes / (1024 * 1024);
      // ignore: avoid_print
      print('[verify] epg grande → $stored programas en '
          '${stopwatch.elapsedMilliseconds} ms · rss '
          '${mb(rssBefore).toStringAsFixed(0)} → ${mb(rssAfter).toStringAsFixed(0)} MB '
          '(pico ${mb(rssAfter - rssBefore).toStringAsFixed(0)} MB)');

      expect(stored, 180000,
          reason: 'los 180 000 programas del feed caen dentro de la ventana');
      expect(mb(rssAfter - rssBefore), lessThan(300),
          reason: 'el feed debe procesarse por lotes, no entero en memoria');

      // La consulta ligera de la guía sigue funcionando sobre esos datos.
      final slots = await database.getProgrammeSlots(
        epgChannelId: 'fixture-epg-large_large.0.tv',
        start: DateTime.now().subtract(const Duration(days: 1)),
        end: DateTime.now().add(const Duration(days: 7)),
      );
      expect(slots, isNotEmpty,
          reason: 'la proyección de la guía debe devolver los programas');
      expect(slots.first.title, isNotEmpty);
      // El refresco completo de un feed grande tarda más que el timeout por
      // defecto (30 s) ahora que la base corre en su isolate, como en la app.
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('EPG auto-mapper: vincula canales del fixture con la guía', () async {
      final database = await seededDatabase(withEpg: true);
      addTearDown(database.close);

      final rows = await database.getAllChannels();
      final epgRows = await database.getEpgChannelsForSource('fixture-epg');

      final applied = <epg_models.EpgMapping>[];
      final stats = EpgAutoMapper().mapAll(
        channels: rows.map(toModelChannel).toList(),
        epgChannels: epgRows
            .map((row) => epg_models.EpgChannel(
                  id: row.channelId,
                  sourceId: row.sourceId,
                  displayNames: <String>[row.displayName],
                  iconUrl: row.iconUrl,
                ))
            .toList(),
        existingMappings: const <String, epg_models.EpgMapping>{},
        epgSourceId: 'fixture-epg',
        onMapping: applied.add,
      );

      // Evidencia para el informe de verificación.
      // ignore: avoid_print
      print('[verify] auto-mapper → mapped=${stats.mapped} '
          'suggested=${stats.suggested} unmapped=${stats.unmapped} '
          'de ${stats.totalChannels} canales');

      expect(stats.mapped, greaterThanOrEqualTo(4),
          reason: 'la guía del fixture cubre 5 de los 6 canales por nombre o tvg-id');
    });
  });

  group('interfaz y reproducción', () {
    testWidgets('UI: la pantalla de canales lista los canales del fixture',
        (tester) async {
      final database = await seededDatabase(withEpg: true);
      addTearDown(database.close);

      final container = ProviderContainer(
        overrides: <Override>[databaseProvider.overrideWithValue(database)],
      );
      addTearDown(() async {
        // Desmonta el arbol antes de tirar el contenedor: los temporizadores de
        // las pantallas (p. ej. el sondeo de info del reproductor) leen
        // providers y fallarian contra un contenedor ya liberado.
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
      });

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            debugShowCheckedModeBanner: false,
            routerConfig: testRouter(const ChannelsScreen()),
          ),
        ),
      );

      // La pantalla arranca en Favoritos y va cargando el resto en segundo
      // plano; cambia a "All (n)" como haría el usuario para ver todos los
      // canales del proveedor.
      await tester.pump(const Duration(seconds: 1));
      final allEntry = find.textContaining('All (');
      if (allEntry.evaluate().isNotEmpty) {
        await tester.tap(allEntry.first);
      }

      bool rendered() => find
          .textContaining('CT Test', findRichText: true)
          .evaluate()
          .isNotEmpty;
      for (var i = 0; i < 40 && !rendered(); i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }

      if (!rendered()) {
        final texts = find
            .byType(Text)
            .evaluate()
            .map((element) => (element.widget as Text).data ?? '')
            .where((text) => text.isNotEmpty)
            .take(40)
            .toList();
        // ignore: avoid_print
        print('[verify] UI visible: $texts');
      }

      expect(rendered(), isTrue,
          reason: 'los canales del fixture deben aparecer en la lista');
    });

    testWidgets('Player: reproduce un stream del fixture con video y audio',
        (tester) async {
      final database = await seededDatabase();
      addTearDown(database.close);

      final container = ProviderContainer(
        overrides: <Override>[databaseProvider.overrideWithValue(database)],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
      });

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            debugShowCheckedModeBanner: false,
            routerConfig: testRouter(
              const PlayerScreen(
                streamUrl: '',
                channelName: 'CT Test News',
              ),
            ),
          ),
        ),
      );

      // La URL se inyecta vía el router en la app real; aquí se pide
      // directamente al servicio el mismo stream del fixture.
      final service = container.read(playerServiceProvider);
      // Sin failover: este test mide la reproduccion del stream, no la
      // capacidad de saltar a otro canal del fixture.
      service.configureFailover(null, null);
      await service.play(fixtureUrl('/streams/stream_a.mp4'),
          channelId: 'ct.test.news', channelName: 'CT Test News');

      final state = service.player.state;

      // Diagnostico: ¿cuando conoce mpv la duracion del MP4 servido por HTTP?
      for (var i = 0; i < 6; i++) {
        // ignore: avoid_print
        print('[verify] player sample $i → playing=${state.playing} '
            'buffering=${state.buffering} position=${state.position} '
            'duration=${state.duration}');
        if (state.duration > Duration.zero) break;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      if (state.duration == Duration.zero) {
        await dumpMpv(service, 'player');
      }

      // Evidencia de reproducción real: mpv avanza el tiempo reproducido.
      var advanced = false;
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (!advanced && DateTime.now().isBefore(deadline)) {
        final pos =
            double.tryParse(await service.getMpvProperty('time-pos') ?? '');
        if (pos != null && pos > 0.5) advanced = true;
        if (!advanced) {
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }

      final videoFormat = await service.getMpvProperty('video-format') ?? '';
      final fps = await service.getMpvProperty('estimated-vf-fps') ?? '';
      // ignore: avoid_print
      print('[verify] player → advanced=$advanced video=$videoFormat fps=$fps '
          'state.playing=${state.playing} state.position=${state.position} '
          'state.duration=${state.duration} '
          'audioTracks=${state.tracks.audio.length}');

      expect(advanced, isTrue,
          reason: 'libmpv debe reproducir el MP4 del fixture (time-pos avanza)');
      expect(videoFormat, isNotEmpty,
          reason: 'el fixture incluye video H.264 que mpv debe decodificar');
      expect(state.tracks.audio, isNotEmpty,
          reason: 'el fixture incluye pista de audio AAC');
      expect(service.lastError, isNull,
          reason: 'un stream que reproduce no debe generar avisos de error');

      await tester.pump(const Duration(milliseconds: 300));
    });

    testWidgets(
        'Player: un canal inalcanzable avisa en vez de quedarse en Buffering',
        (tester) async {
      final service = PlayerService();
      addTearDown(service.dispose);
      // Sin failover: aquí se mide el aviso al usuario, no el salto de stream.
      service.configureFailover(null, null);

      final messages = <String>[];
      final sub = service.errors.listen(messages.add);
      addTearDown(sub.cancel);

      // Puerto cerrado: la conexión se rechaza y mpv/ffmpeg lo registran.
      await service.play('http://127.0.0.1:1/no-existe.m3u8',
          channelId: 'ct.dead', channelName: 'CT Dead Stream');

      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (messages.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      // ignore: avoid_print
      print('[verify] canal inalcanzable → avisos: $messages '
          '(lastError=${service.lastError})');

      expect(messages, isNotEmpty,
          reason: 'sin aviso, la UI se queda en Buffering para siempre');
      expect(messages.first.toLowerCase(),
          anyOf(contains('conectar'), contains('no responde'), contains('no se pudo abrir')));
    }, timeout: const Timeout(Duration(minutes: 2)));

    testWidgets(
        'Failover: un Smart Channel salta al alternativo cuando el primario se estanca',
        (tester) async {
      final service = PlayerService();
      addTearDown(service.dispose);

      String? failoverEvent;
      service.onFailover = (message) => failoverEvent = message;

      final primary = fixtureUrl('/stall/primary.m3u8');
      final alternative = fixtureUrl('/streams/stream_b.mp4');

      await service.play(
        primary,
        channelId: 'smart-channel-test',
        channelName: 'CT Test Sports',
        failoverGroupUrls: <String>[primary, alternative],
      );

      // Diagnostico: el monitor de failover se apoya en demuxer-cache-duration.
      for (var i = 0; i < 8; i++) {
        final cache = await service.getMpvProperty('demuxer-cache-duration');
        final playerState = service.player.state;
        // ignore: avoid_print
        print('[verify] stall sample $i → cache=$cache '
            'playing=${playerState.playing} '
            'buffering=${playerState.buffering} '
            'position=${playerState.position}');
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      await dumpMpv(service, 'stall');

      final switched = await waitFor(
        () => service.currentUrl == alternative,
        timeout: const Duration(seconds: 45),
      );

      // ignore: avoid_print
      print('[verify] failover → switched=$switched event=$failoverEvent '
          'currentUrl=${service.currentUrl}');

      expect(switched, isTrue,
          reason: 'el monitor de failover debe abandonar el stream colgado');
      expect(failoverEvent, isNotNull);
      expect(failoverEvent, contains('Switched'));

      final playsAfterSwitch = await waitFor(
        () => service.player.state.playing,
        timeout: const Duration(seconds: 30),
      );
      expect(playsAfterSwitch, isTrue,
          reason: 'el stream alternativo debe reproducirse tras el failover');
    });
  });
}
