// Prueba de extremo a extremo de la comprobación de canales **sin modal**.
//
// Se sirve una lista propia por loopback para que los veredictos sean
// deterministas: `/good/*` contesta una lista HLS válida (con retardo, para que
// el escaneo esté en vuelo mientras el test navega) y `/dead/*` contesta 404.
//
//   flutter test integration_test/scan_in_layout_test.dart -d windows --timeout 600s
//
// Comprueba, como lo haría un usuario: que al pulsar CHECK no aparece ningún
// diálogo, que se puede cambiar de categoría y reproducir un canal mientras el
// escaneo corre, que los veredictos quedan en la lista (punto de color y filtro
// de «sólo los que responden») y que un canal muerto lo sigue estando al
// reproducirlo.

import 'dart:convert';
import 'dart:io';

import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/channel_history_service.dart';
import 'package:clubtivi/data/services/channel_probe_service.dart';
import 'package:clubtivi/features/channels/channel_health_panel.dart';
import 'package:clubtivi/features/channels/channel_scan_host.dart';
import 'package:clubtivi/features/channels/channels_screen.dart';
import 'package:clubtivi/features/player/player_service.dart';
import 'package:clubtivi/features/providers/provider_manager.dart';
import 'package:clubtivi/features/providers/providers_screen.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Cuánto tarda el servidor bueno en contestar: mantiene el escaneo en vuelo lo
/// suficiente para navegar y empezar a ver algo mientras corre.
const _goodDelay = Duration(seconds: 4);

/// Lo que tarda el proveedor lento: deja el escaneo en vuelo el tiempo justo
/// para pedir otro ámbito o pararlo a mitad.
const _slowDelay = Duration(seconds: 6);

/// Un PNG de un píxel: la lista declara sus logos y el servidor los sirve, así
/// ninguna prueba sale a internet a buscarlos (y no se cuelga si GitHub tarda).
const _onePixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

/// Servidor de pruebas: listas buenas, canales muertos y un vídeo reproducible.
class _StreamServer {
  HttpServer? _server;
  final _openSockets = <Socket>[];

  String get base => 'http://127.0.0.1:${_server!.port}';

  Future<void> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((request) async {
      final path = request.uri.path;
      try {
        if (path == '/playlist.m3u') {
          request.response
            ..headers.contentType = ContentType('audio', 'x-mpegurl')
            ..write(_playlist)
            ..close();
        } else if (path == '/slowplaylist.m3u') {
          request.response
            ..headers.contentType = ContentType('audio', 'x-mpegurl')
            ..write(_slowPlaylist)
            ..close();
        } else if (path == '/empty.m3u') {
          request.response
            ..headers.contentType = ContentType('audio', 'x-mpegurl')
            ..write('#EXTM3U\n')
            ..close();
        } else if (path.startsWith('/slow/')) {
          await Future<void>.delayed(_slowDelay);
          request.response
            ..headers.contentType =
                ContentType('application', 'vnd.apple.mpegurl')
            ..write('#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n'
                '#EXTINF:6.0,\nseg.ts\n')
            ..close();
        } else if (path.startsWith('/fast/')) {
          request.response
            ..headers.contentType =
                ContentType('application', 'vnd.apple.mpegurl')
            ..write('#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n'
                '#EXTINF:6.0,\nseg.ts\n')
            ..close();
        } else if (path == '/logo.png') {
          request.response
            ..headers.contentType = ContentType('image', 'png')
            ..add(base64Decode(_onePixelPng))
            ..close();
        } else if (path.startsWith('/good/')) {
          await Future<void>.delayed(_goodDelay);
          request.response
            ..headers.contentType =
                ContentType('application', 'vnd.apple.mpegurl')
            ..write('#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n'
                '#EXTINF:6.0,\nseg.ts\n')
            ..close();
        } else if (path.startsWith('/dead/')) {
          request.response.statusCode = HttpStatus.notFound;
          request.response.write('not here');
          await request.response.close();
        } else if (path == '/video.mp4') {
          final file = File('.dev/fixtures/streams/stream_a.mp4');
          if (!file.existsSync()) {
            request.response.statusCode = HttpStatus.notFound;
            await request.response.close();
            return;
          }
          request.response.headers.contentType = ContentType('video', 'mp4');
          await request.response.addStream(file.openRead());
          await request.response.close();
        } else {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        }
      } catch (_) {
        // El test puede cerrar el servidor con peticiones en vuelo.
      }
    });
  }

  String get _playlist => '''
#EXTM3U
#EXTINF:-1 tvg-id="news1" tvg-logo="$base/logo.png" group-title="News",News One
$base/good/1.m3u8
#EXTINF:-1 tvg-id="news2" tvg-logo="$base/logo.png" group-title="News",News Two
$base/good/2.m3u8
#EXTINF:-1 tvg-id="news3" tvg-logo="$base/logo.png" group-title="News",News Three
$base/good/3.m3u8
#EXTINF:-1 tvg-logo="$base/logo.png" group-title="News",News Playable
$base/video.mp4
#EXTINF:-1 tvg-id="film1" tvg-logo="$base/logo.png" group-title="Films",Film One
$base/dead/1.m3u8
#EXTINF:-1 tvg-id="film2" tvg-logo="$base/logo.png" group-title="Films",Film Two
$base/dead/2.m3u8
''';

  /// Proveedor que tarda en contestar y un canal rápido en medio: con él, un
  /// escaneo se queda en vuelo mientras el usuario pide otra cosa o lo para.
  String get _slowPlaylist => '''
#EXTM3U
#EXTINF:-1 tvg-id="slow1" tvg-logo="$base/logo.png" group-title="Slow",Slow One
$base/slow/1.m3u8
#EXTINF:-1 tvg-id="slow2" tvg-logo="$base/logo.png" group-title="Slow",Slow Two
$base/slow/2.m3u8
#EXTINF:-1 tvg-id="fast1" tvg-logo="$base/logo.png" group-title="Quick",Quick One
$base/fast/1.m3u8
''';

  Future<void> stop() async {
    for (final socket in _openSockets) {
      socket.destroy();
    }
    await _server?.close(force: true);
  }
}

/// Sonda que apunta qué canales se le piden medir y mide igual que la de
/// verdad: la pregunta del CHECK de una categoría es *qué* se comprueba, y eso
/// no se puede leer de los veredictos, que se guardan y sobreviven a la prueba.
class _RecordingProbe extends ChannelProbeService {
  final scanned = <List<db.Channel>>[];

  @override
  Future<void> scan(
    List<db.Channel> channels, {
    int concurrency = 6,
    Duration timeout = const Duration(seconds: 8),
    bool retryTimeouts = true,
    Duration retryTimeout = const Duration(seconds: 15),
    int maxRetries = ChannelProbeService.defaultMaxRetries,
    bool adaptConcurrency = true,
    required void Function(
      db.Channel channel,
      ProbeResult result,
      int done,
      int total,
    )
    onResult,
    void Function(int pending)? onRetryStart,
    void Function(db.Channel channel, ProbeResult result, int done, int total)?
    onRetryResult,
    void Function(int limit, int maxLimit)? onConcurrencyChanged,
    bool Function()? isCancelled,
  }) {
    scanned.add(List<db.Channel>.of(channels));
    return super.scan(
      channels,
      concurrency: concurrency,
      timeout: timeout,
      retryTimeouts: retryTimeouts,
      retryTimeout: retryTimeout,
      maxRetries: maxRetries,
      adaptConcurrency: adaptConcurrency,
      onResult: onResult,
      onRetryStart: onRetryStart,
      onRetryResult: onRetryResult,
      onConcurrencyChanged: onConcurrencyChanged,
      isCancelled: isCancelled,
    );
  }
}

GoRouter testRouter(Widget home, {bool withProviders = false}) => GoRouter(
      routes: <RouteBase>[
        GoRoute(path: '/', builder: (context, state) => home),
        if (withProviders)
          GoRoute(
            path: '/providers',
            builder: (context, state) => const ProvidersScreen(),
          ),
        for (final path in <String>[
          '/player',
          '/settings',
          if (!withProviders) '/providers',
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

/// Espera activa **bombeando frames**: sin el pump, el árbol de widgets no se
/// reconstruye y una condición sobre lo pintado nunca cambia.
Future<bool> waitFor(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 60),
  Duration step = const Duration(milliseconds: 200),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return true;
    await tester.pump(step);
    await Future<void>.delayed(step);
  }
  return condition();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(MediaKit.ensureInitialized);

  late _StreamServer server;

  setUpAll(() async {
    server = _StreamServer();
    await server.start();
  });

  setUp(() {
    // Las preferencias viven en memoria: lo que el historial o el último canal
    // de una corrida anterior dejó apuntado no puede decidir esta prueba. La
    // prueba del historial escribe y lee dentro de sí misma.
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDownAll(() => server.stop());

  /// [extras] añade un proveedor que tarda en contestar y otro sin ningún
  /// canal: los dos casos que la pantalla tiene que saber contar.
  Future<db.AppDatabase> seededDatabase({bool extras = false}) async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    await ProviderManager(database).addM3uProvider(
      id: 'scan-provider',
      name: 'Scan fixtures',
      url: '${server.base}/playlist.m3u',
    );
    if (extras) {
      await ProviderManager(database).addM3uProvider(
        id: 'slow-provider',
        name: 'Slow fixtures',
        url: '${server.base}/slowplaylist.m3u',
      );
      await ProviderManager(database).addM3uProvider(
        id: 'empty-provider',
        name: 'Empty playlist',
        url: '${server.base}/empty.m3u',
      );
    }
    // Una guía recién refrescada: así la pantalla no se pone a descargar y
    // parsear 180.000 programas por internet en mitad de la prueba.
    await database.upsertEpgSource(db.EpgSourcesCompanion.insert(
      id: 'scan-epg',
      name: 'Scan EPG',
      url: '${server.base}/epg.xml',
      lastRefresh: Value(DateTime.now()),
    ));
    return database;
  }

  /// Nombre del canal que se toca en cada categoría: el primero de una lista
  /// recién filtrada ya queda seleccionado, y tocar el seleccionado no vuelve a
  /// abrir el stream.
  Future<void> openCategory(WidgetTester tester, String name) async {
    if (find.text(name).evaluate().isEmpty) {
      // Las categorías del proveedor viven dentro de una sección plegada: se
      // despliega como haría el usuario.
      final section = find.textContaining('Groups (');
      if (section.evaluate().isNotEmpty) {
        await tester.tap(section.first);
        await tester.pump(const Duration(milliseconds: 700));
      }
    }
    if (find.text(name).evaluate().isEmpty) {
      // Y si queda fuera de la vista, se baja hasta ella.
      final scrollables = find.byType(Scrollable);
      for (var i = 0;
          i < scrollables.evaluate().length &&
              find.text(name).evaluate().isEmpty;
          i++) {
        try {
          await tester.scrollUntilVisible(find.text(name), 140,
              scrollable: scrollables.at(i), maxScrolls: 40);
        } catch (_) {
          // No está en esta lista; se prueba con la siguiente.
        }
      }
    }
    expect(find.text(name), findsWidgets,
        reason: 'la categoría $name está en la barra lateral');
    await tester.tap(find.text(name).first);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(seconds: 1));
  }

  Future<ProviderContainer> pumpScreen(
    WidgetTester tester,
    db.AppDatabase database, {
    bool withProviders = false,
    List<Override> extraOverrides = const <Override>[],
  }) async {
    // Ventana de escritorio normal: es el tamaño en el que se usa la app.
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container = ProviderContainer(
      overrides: <Override>[
        databaseProvider.overrideWithValue(database),
        ...extraOverrides,
      ],
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
          routerConfig:
              testRouter(const ChannelsScreen(), withProviders: withProviders),
        ),
      ),
    );

    // La pantalla arranca en Favoritos y carga el resto en segundo plano.
    await tester.pump(const Duration(seconds: 1));
    final all = find.textContaining('All (');
    if (all.evaluate().isNotEmpty) await tester.tap(all.first);
    await waitFor(
      tester,
      () => find.textContaining('News One').evaluate().isNotEmpty,
      timeout: const Duration(seconds: 60),
    );
    // Si la lista no llegó a cargar, comprobar después no comprueba nada: se
    // avisa aquí, que es donde está la causa, y no cien líneas más abajo.
    expect(find.textContaining('News One').evaluate(), isNotEmpty,
        reason: 'la pantalla terminó de cargar los canales');
    await tester.pump(const Duration(milliseconds: 500));
    return container;
  }

  Finder checkButton() => find.byTooltip(
      'Check which channels play (the list stays usable)');

  /// Va a Proveedores como va la app: empujando la ruta (la cabecera hace lo
  /// mismo con Ajustes y el shell navega igual).
  Future<void> openProviders(WidgetTester tester) async {
    GoRouter.of(tester.element(find.byType(ChannelsScreen))).push('/providers');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
  }

  /// El CHECK de la tarjeta de un proveedor concreto, no el de otra tarjeta.
  Finder providerCheck(String name) => find.descendant(
        of: find.ancestor(of: find.text(name), matching: find.byType(Card)),
        matching: find.text('CHECK'),
      );

  /// Toca la fila de un canal **en la lista**, no la etiqueta del mismo nombre
  /// que el panel de arriba: el nombre aparece en los dos sitios y sólo la fila
  /// cambia de canal al tocarla.
  Future<void> tapChannelRow(WidgetTester tester, String name) async {
    final matches = find.textContaining(name).evaluate().toList();
    expect(matches, isNotEmpty, reason: 'la fila de $name está en la lista');
    final rects = matches
        .map((element) => tester.getRect(find.byWidget(element.widget)))
        .toList()
      ..sort((a, b) => a.top.compareTo(b.top));
    // La coincidencia más baja es la fila; a su derecha está la zona de
    // programas, que es la que recibe el toque.
    final row = rects.last;
    await tester.tapAt(Offset(row.right + 150, row.center.dy));
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('el escaneo corre en el layout: sin modal, navegando y viendo algo',
      (tester) async {
    final database = await seededDatabase();
    addTearDown(database.close);
    final container = await pumpScreen(tester, database);
    final playerService = container.read(playerServiceProvider);

    // Un usuario pulsa CHECK.
    expect(checkButton(), findsOneWidget, reason: 'el botón CHECK está en la barra');
    await tester.tap(checkButton());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    // Lo que NO debe pasar: ningún diálogo tapando la pantalla.
    expect(find.byType(AlertDialog), findsNothing,
        reason: 'la comprobación no puede abrir un modal en la pantalla de canales');
    expect(find.byType(ChannelHealthStrip), findsOneWidget,
        reason: 'la tira aparece acoplada encima de la lista');
    expect(find.text('STOP'), findsOneWidget, reason: 'el escaneo está en marcha');

    // Cambiar de categoría mientras corre.
    await openCategory(tester, 'Films');
    expect(find.textContaining('Film One'), findsWidgets,
        reason: 'la lista cambió a la categoría pedida durante el escaneo');
    expect(find.byType(ChannelHealthStrip), findsOneWidget);
    expect(find.text('STOP'), findsOneWidget,
        reason: 'seguir navegando no cancela la comprobación');

    // La lista sigue siendo desplazable con la tira abierta.
    await tester.drag(
        find.textContaining('Film One').first, const Offset(0, -120));
    await tester.pump(const Duration(milliseconds: 300));

    // Y se puede poner un canal mientras el escaneo sigue.
    await openCategory(tester, 'News');
    for (final name in const ['News Playable', 'News Two', 'News Three']) {
      if (find.textContaining(name).evaluate().isNotEmpty) {
        await tapChannelRow(tester, name);
        break;
      }
    }
    final playing = await waitFor(
      tester,
      () =>
          playerService.player.state.playing ||
          playerService.player.state.buffering ||
          playerService.player.state.tracks.video.isNotEmpty,
      timeout: const Duration(seconds: 40),
      step: const Duration(milliseconds: 500),
    );
    // ignore: avoid_print
    print('[verify] reproduciendo durante el escaneo: $playing '
        '(escaneo en marcha: ${find.text('STOP').evaluate().isNotEmpty})');
    expect(playing, isTrue,
        reason: 'poner un canal no debe depender de que el escaneo haya '
            'terminado');

    // El escaneo termina por su cuenta, sin que nadie cierre nada.
    final finished = await waitFor(
      tester,
      () => find.text('STOP').evaluate().isEmpty,
      timeout: const Duration(seconds: 120),
    );
    expect(finished, isTrue, reason: 'la comprobación llega al final');

    // Y los veredictos quedan guardados y visibles en la lista.
    final store = container.read(channelHealthStoreProvider);
    final good = store.resultForUrl('${server.base}/good/1.m3u8');
    final dead = store.resultForUrl('${server.base}/dead/1.m3u8');
    expect(good?.status, ProbeStatus.ok,
        reason: 'el canal que contesta una lista HLS válida queda como OK');
    expect(dead?.status, ProbeStatus.notFound,
        reason: 'el canal que contesta 404 queda como muerto');
    // ignore: avoid_print
    print('[verify] veredictos guardados: good=${good?.label} dead=${dead?.label}');

    // El punto de color de cada fila sale del veredicto guardado. El canal
    // muerto vive en Films, que es la categoría que se abre ahora.
    await openCategory(tester, 'Films');
    expect(find.textContaining('Film One'), findsWidgets);
    expect(find.byTooltip('Last check: Gone (404)\nThe channel is no longer '
        'published at this address.'), findsWidgets,
        reason: 'la fila del canal muerto dice por qué no va');

    // «Sólo los que responden» esconde lo medido como muerto.
    final switchFinder = find.byType(Switch).first;
    await tester.tap(switchFinder);
    await tester.pump(const Duration(milliseconds: 800));
    // La categoría entera se queda sin canales y la pantalla lo dice: Films son
    // justo los dos que no responden. (El nombre sigue apareciendo en la lista
    // de fallos del panel, que es donde el usuario ve a quién ha perdido.)
    expect(find.text('No channels match your filter'), findsWidgets,
        reason: 'con el filtro puesto, lo que no responde desaparece de la lista');
    expect(
        find.byWidgetPredicate((widget) =>
            widget is Tooltip &&
            widget.message != null &&
            widget.message!.startsWith('Last check: Gone (404)')),
        findsNothing,
        reason: 'ya no queda ninguna fila pintando el veredicto del canal muerto');

    // Se deja el interruptor como estaba: es una preferencia guardada del
    // usuario y las demás pruebas no tienen por qué heredarla.
    await tester.tap(find.byType(Switch).first);
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.textContaining('Film One'), findsWidgets,
        reason: 'al apagarlo vuelven los canales que no responden');
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('un canal medido como muerto sigue avisando al reproducirlo',
      (tester) async {
    final database = await seededDatabase();
    addTearDown(database.close);
    final container = await pumpScreen(tester, database);
    final playerService = container.read(playerServiceProvider);

    await tester.tap(checkButton());
    await tester.pump();
    final finished = await waitFor(
      tester,
      () => find.text('STOP').evaluate().isEmpty,
      timeout: const Duration(seconds: 120),
    );
    expect(finished, isTrue);

    final errors = <String>[];
    final sub = playerService.errors.listen(errors.add);
    addTearDown(sub.cancel);

    await openCategory(tester, 'Films');
    // El primero de la categoría ya viene seleccionado, así que se abre el
    // segundo: tocar el seleccionado no vuelve a abrir el stream.
    await tapChannelRow(tester, 'Film Two');

    final warned = await waitFor(
      tester,
      () => errors.isNotEmpty,
      timeout: const Duration(seconds: 90),
    );
    // ignore: avoid_print
    print('[verify] aviso al reproducir un canal muerto: '
        '${errors.isEmpty ? '(ninguno)' : errors.first}');
    expect(warned, isTrue,
        reason: 'un canal que el escaneo dio por muerto debe decirlo al abrirlo, '
            'no quedarse en negro');

    // El aviso que ve el usuario no es el log crudo del reproductor: lleva el
    // veredicto que ya había guardado el chequeo de salud.
    await tester.pump(const Duration(milliseconds: 400));
    final warning = find
        .descendant(of: find.byType(SnackBar), matching: find.byType(Text))
        .evaluate()
        .map((element) => (element.widget as Text).data ?? '')
        .join(' ');
    // ignore: avoid_print
    print('[verify] aviso en pantalla: $warning');
    expect(warning, contains('Gone (404)'),
        reason: 'el aviso dice lo que el chequeo ya sabía del canal');
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('en ventana estrecha el panel se adapta en vez de desbordar',
      (tester) async {
    final database = await seededDatabase();
    addTearDown(database.close);
    await pumpScreen(tester, database);

    await tester.tap(checkButton());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(ChannelHealthStrip), findsOneWidget);
    // ignore: avoid_print
    print('[verify] 1400x900 → tira: '
        '${tester.getRect(find.byType(ChannelHealthStrip))} '
        'lista: ${tester.getRect(find.byType(ListView).last)}');

    // Se encoge la ventana **con el escaneo en marcha**: un desbordamiento de
    // layout hace fallar el test por sí solo, así que llegar al final ya prueba
    // que la tira se adapta (deja de pintar recuentos y barra).
    tester.view.physicalSize = const Size(900, 700);
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byType(ChannelHealthStrip), findsOneWidget,
        reason: 'la tira sigue ahí en ventana estrecha');
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('STOP'), findsOneWidget,
        reason: 'se puede parar también en ventana estrecha');

    final finished = await waitFor(
      tester,
      () => find.text('STOP').evaluate().isEmpty,
      timeout: const Duration(seconds: 120),
    );
    expect(finished, isTrue);
    // ignore: avoid_print
    print('[verify] tira: ${tester.getRect(find.byType(ChannelHealthStrip))} '
        'guía: ${tester.getRect(find.byType(ListView).last)} '
        'ventana: ${tester.view.physicalSize}');
    expect(find.textContaining('News One'), findsWidgets,
        reason: 'la lista sigue mostrando canales tras encoger la ventana');
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets(
      'la tira deja elegir ámbito y comprueba todo el proveedor, sin tapar nada',
      (tester) async {
    final database = await seededDatabase();
    addTearDown(database.close);
    final container = await pumpScreen(tester, database);
    final store = container.read(channelHealthStoreProvider);
    // Los veredictos que hayan dejado otras corridas para estas mismas URLs no
    // cuentan: lo que prueba esta prueba es lo que mide ella.
    await store.load();
    store.clear();

    // Un usuario abre una categoría y pulsa CHECK: primero se mira lo que ve.
    await openCategory(tester, 'News');
    await tester.tap(checkButton());
    await tester.pump();
    final first = await waitFor(
      tester,
      () => find.text('STOP').evaluate().isEmpty,
      timeout: const Duration(seconds: 120),
    );
    expect(first, isTrue, reason: 'la primera comprobación llega al final');
    expect(store.resultForUrl('${server.base}/dead/1.m3u8'), isNull,
        reason: 'la primera pasada sólo miró los canales de la categoría abierta');

    // La tira ofrece el otro ámbito: lo que antes sólo sabía hacer el diálogo
    // de la tarjeta del proveedor.
    final everyChannel = find.textContaining('Every loaded channel (');
    expect(everyChannel, findsOneWidget,
        reason: 'la tira deja elegir ámbito cuando hay más de uno');
    await tester.ensureVisible(everyChannel);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(everyChannel);
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byType(AlertDialog), findsNothing,
        reason: 'elegir ámbito no abre ningún modal');
    expect(find.textContaining('Checking all channels'), findsWidgets,
        reason: 'la tira dice con qué ámbito está comprobando');

    final second = await waitFor(
      tester,
      () =>
          find.text('STOP').evaluate().isEmpty &&
          store.resultForUrl('${server.base}/dead/1.m3u8') != null &&
          store.resultForUrl('${server.base}/dead/2.m3u8') != null,
      timeout: const Duration(seconds: 180),
    );
    expect(second, isTrue,
        reason: '«todos los canales» comprueba también los que no estaban en la '
            'categoría abierta');

    // Y los veredictos se ven por fila y por categoría, sin ningún modal.
    await openCategory(tester, 'Films');
    expect(find.textContaining('Film One'), findsWidgets);
    expect(
        find.byTooltip('Last check: Gone (404)\nThe channel is no longer '
            'published at this address.'),
        findsWidgets,
        reason: 'la fila del canal medido en la segunda pasada dice por qué no va');
    expect(
        find.byWidgetPredicate((widget) =>
            widget is Tooltip &&
            widget.message != null &&
            widget.message!.startsWith('Last check: 0 of 2 answer')),
        findsWidgets,
        reason: 'la categoría Films, comprobada sólo por el ámbito completo, '
            'muestra su recuento en la barra lateral');
    expect(find.byType(AlertDialog), findsNothing,
        reason: 'todo el camino se recorre en el layout');
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets(
      'el CHECK de un proveedor comprueba sus canales en la tira, sin diálogo',
      (tester) async {
    final database = await seededDatabase();
    addTearDown(database.close);
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

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
          routerConfig: GoRouter(
            initialLocation: '/providers',
            routes: <RouteBase>[
              GoRoute(
                path: '/providers',
                builder: (_, __) => const ProvidersScreen(),
              ),
              GoRoute(path: '/', builder: (_, __) => const ChannelsScreen()),
            ],
          ),
        ),
      ),
    );

    // El usuario entra en la pantalla de proveedores y pulsa CHECK.
    final check = find.text('CHECK');
    final listed = await waitFor(
      tester,
      () => check.evaluate().isNotEmpty,
      timeout: const Duration(seconds: 60),
    );
    expect(listed, isTrue, reason: 'la tarjeta del proveedor está en la lista');
    await tester.tap(check.first);
    await tester.pump(const Duration(milliseconds: 800));

    expect(find.byType(AlertDialog), findsNothing,
        reason: 'el CHECK del proveedor no abre ningún modal');

    final store = container.read(channelHealthStoreProvider);
    final done = await waitFor(
      tester,
      () =>
          store.resultForUrl('${server.base}/dead/1.m3u8') != null &&
          store.resultForUrl('${server.base}/good/1.m3u8') != null,
      timeout: const Duration(seconds: 180),
    );
    // ignore: avoid_print
    print('[verify] CHECK de proveedor: tira en marcha='
        '${find.byType(ChannelHealthStrip).evaluate().isNotEmpty} '
        'veredictos=${done} '
        'título=${find.textContaining('Scan fixtures').evaluate().isNotEmpty}');
    expect(done, isTrue,
        reason: 'la comprobación pedida por el proveedor mide todos sus canales, '
            'los de la categoría abierta y los que no');
    expect(find.byType(AlertDialog), findsNothing,
        reason: 'ni un modal en todo el camino');
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets(
      'un proveedor pedido con otra comprobación en marcha manda: se mide lo que pidió',
      (tester) async {
    final database = await seededDatabase(extras: true);
    addTearDown(database.close);
    final container = await pumpScreen(tester, database, withProviders: true);
    final store = container.read(channelHealthStoreProvider);
    await store.load();
    store.clear();

    // Un usuario comprueba la categoría que tarda: el escaneo se queda en vuelo.
    await openCategory(tester, 'Slow');
    await tester.tap(checkButton());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('STOP'), findsOneWidget,
        reason: 'la comprobación de Slow está corriendo');

    // Y con ella en marcha, se va a Proveedores y pide el CHECK del proveedor.
    await openProviders(tester);
    final cardCheck = providerCheck('Slow fixtures');
    expect(cardCheck, findsOneWidget,
        reason: 'la tarjeta del proveedor tiene su CHECK');
    await tester.tap(cardCheck);
    await tester.pump(const Duration(milliseconds: 800));

    // La petición más nueva manda: la tira nombra lo que está midiendo…
    expect(find.textContaining('Checking Slow fixtures'), findsOneWidget,
        reason: 'la tira dice qué proveedor se está comprobando');
    expect(find.text('STOP'), findsOneWidget,
        reason: 'el proveedor entero se está comprobando ahora');

    // …y lo mide de verdad: el canal que sólo existe en el ámbito del proveedor
    // acaba con veredicto, en vez de quedarse sin comprobar.
    final measured = await waitFor(
      tester,
      () => store.resultForUrl('${server.base}/fast/1.m3u8') != null,
      timeout: const Duration(seconds: 120),
    );
    final done = await waitFor(
      tester,
      () => find.textContaining('3 / 3 checked').evaluate().isNotEmpty,
      timeout: const Duration(seconds: 120),
    );
    // ignore: avoid_print
    print('[verify] petición a mitad: medido=$measured terminado=$done '
        'corriendo=${find.text('STOP').evaluate().isNotEmpty}');
    expect(measured, isTrue,
        reason: 'lo pedido con otra comprobación en marcha no se pierde');
    expect(done, isTrue,
        reason: 'sólo corre una comprobación y termina con lo último pedido');
    expect(find.text('STOP'), findsNothing);
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets(
      'STOP a mitad deja lo medido, no deja nada corriendo y se puede reanudar',
      (tester) async {
    final database = await seededDatabase(extras: true);
    addTearDown(database.close);
    final container = await pumpScreen(tester, database);
    final store = container.read(channelHealthStoreProvider);
    final controller = container.read(channelScanControllerProvider);
    await store.load();
    store.clear();

    // Comprueba todo lo cargado: los muertos contestan al instante y los que
    // tardan siguen en vuelo, así que hay veredictos llegando mientras corre.
    await tester.tap(checkButton());
    await tester.pump();
    final arrived = await waitFor(
      tester,
      () => find.text('Not working').evaluate().isNotEmpty,
      timeout: const Duration(seconds: 60),
    );
    expect(arrived, isTrue, reason: 'ya hay veredictos en pantalla');
    expect(find.text('STOP'), findsOneWidget, reason: 'y el escaneo sigue');

    await tester.tap(find.text('STOP'));
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('STOP'), findsNothing, reason: 'parar para el escaneo');
    expect(controller.running, isFalse,
        reason: 'no queda ninguna comprobación corriendo');
    expect(find.text('CHECK AGAIN'), findsOneWidget,
        reason: 'se puede volver a comprobar sin más');
    expect(store.resultForUrl('${server.base}/dead/1.m3u8'), isNotNull,
        reason: 'lo medido antes de parar no se tira');

    // Y reanudar termina el trabajo: los que tardan también acaban medidos.
    await tester.tap(find.text('CHECK AGAIN'));
    await tester.pump(const Duration(milliseconds: 600));
    final finished = await waitFor(
      tester,
      () =>
          find.text('STOP').evaluate().isEmpty &&
          store.resultForUrl('${server.base}/good/1.m3u8') != null &&
          store.resultForUrl('${server.base}/slow/1.m3u8') != null,
      timeout: const Duration(seconds: 180),
    );
    // ignore: avoid_print
    print('[verify] STOP a mitad: medidos=${controller.doneCount}'
        '/${controller.total} reanudado=$finished');
    expect(finished, isTrue,
        reason: 'la comprobación reanudada llega al final');
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets(
      'salir de la pantalla con el escaneo en marcha no lo deja huérfano',
      (tester) async {
    final database = await seededDatabase(extras: true);
    addTearDown(database.close);
    final container = await pumpScreen(tester, database, withProviders: true);
    final store = container.read(channelHealthStoreProvider);
    await store.load();
    store.clear();

    await tester.tap(checkButton());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('STOP'), findsOneWidget,
        reason: 'la comprobación está en marcha');

    // Se va a otra pantalla como se va en la app (el shell navega igual) y
    // vuelve con la comprobación a cuestas.
    final context = tester.element(find.byType(ChannelsScreen));
    GoRouter.of(context).go('/providers');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(ChannelsScreen), findsNothing,
        reason: 'la pantalla de canales se fue con su escaneo dentro');
    expect(container.read(channelScanControllerProvider).running, isTrue,
        reason: 'la comprobación no se muere porque se vaya la pantalla');

    GoRouter.of(tester.element(find.byType(ProvidersScreen))).go('/');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(ChannelsScreen), findsOneWidget);
    expect(find.text('STOP'), findsOneWidget,
        reason: 'al volver, la comprobación sigue donde estaba');

    // Y si el usuario cierra la tira sin querer, el botón CHECK la devuelve sin
    // reiniciar nada: una comprobación en marcha nunca queda invisible.
    final before = container.read(channelScanControllerProvider).doneCount;
    await tester.tap(find.byTooltip('Close the check panel'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ChannelHealthStrip), findsNothing,
        reason: 'la tira se cierra');
    await tester.tap(find.byIcon(Icons.network_check));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ChannelHealthStrip), findsOneWidget,
        reason: 'el botón CHECK devuelve la tira');
    expect(find.text('STOP'), findsOneWidget,
        reason: 'y sigue siendo la misma comprobación, no una nueva');
    expect(container.read(channelScanControllerProvider).doneCount,
        greaterThanOrEqualTo(before),
        reason: 'asomarla otra vez no reinicia el recuento');

    // Y termina: navegar ni la deja huérfana ni la reinicia a medias.
    final finished = await waitFor(
      tester,
      () =>
          find.text('STOP').evaluate().isEmpty &&
          store.resultForUrl('${server.base}/dead/1.m3u8') != null &&
          store.resultForUrl('${server.base}/slow/1.m3u8') != null,
      timeout: const Duration(seconds: 180),
    );
    // ignore: avoid_print
    print('[verify] ida y vuelta: seguía corriendo='
        '${container.read(channelScanControllerProvider).running} '
        'terminó=$finished');
    expect(finished, isTrue,
        reason: 'vuelve a terminar la comprobación que ya iba en marcha');
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('el CHECK de un proveedor sin canales lo dice y no arranca nada',
      (tester) async {
    final database = await seededDatabase(extras: true);
    addTearDown(database.close);
    final container = await pumpScreen(tester, database, withProviders: true);
    final controller = container.read(channelScanControllerProvider);

    await openProviders(tester);
    final cardCheck = providerCheck('Empty playlist');
    expect(cardCheck, findsOneWidget,
        reason: 'el proveedor sin canales también tiene tarjeta');
    await tester.tap(cardCheck);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    // ignore: avoid_print
    print('[verify] proveedor sin canales: '
        'aviso=${find.textContaining('no channels loaded yet').evaluate().isNotEmpty} '
        'corriendo=${controller.running}');
    expect(find.text('Empty playlist has no channels loaded yet'), findsOneWidget,
        reason: 'la tarjeta dice que no hay canales que comprobar');
    expect(find.byType(ProvidersScreen), findsOneWidget,
        reason: 'no se navega a ninguna parte');
    expect(controller.running, isFalse,
        reason: 'no se arranca una comprobación sin canales');
    expect(find.byType(ChannelHealthStrip), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets(
      'en ventana estrecha las casillas de ámbito siguen ahí y relanzan la comprobación',
      (tester) async {
    final database = await seededDatabase(extras: true);
    addTearDown(database.close);
    final container = await pumpScreen(tester, database);
    final store = container.read(channelHealthStoreProvider);
    await store.load();
    store.clear();

    await openCategory(tester, 'News');
    await tester.tap(checkButton());
    await tester.pump();
    final first = await waitFor(
      tester,
      () => find.text('STOP').evaluate().isEmpty,
      timeout: const Duration(seconds: 120),
    );
    expect(first, isTrue, reason: 'la primera comprobación llega al final');

    // La ventana se encoge y el usuario quiere comprobar todo lo cargado.
    tester.view.physicalSize = const Size(900, 700);
    await tester.pump(const Duration(milliseconds: 600));
    final every = find.textContaining('Every loaded channel (');
    expect(every, findsOneWidget,
        reason: 'en ventana estrecha también se puede elegir ámbito');
    await tester.ensureVisible(every);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(every);
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('STOP'), findsOneWidget,
        reason: 'elegir ámbito en ventana estrecha relanza la comprobación');
    final second = await waitFor(
      tester,
      () =>
          find.text('STOP').evaluate().isEmpty &&
          store.resultForUrl('${server.base}/dead/1.m3u8') != null &&
          store.resultForUrl('${server.base}/slow/1.m3u8') != null,
      timeout: const Duration(seconds: 180),
    );
    // ignore: avoid_print
    print('[verify] ventana estrecha: tira='
        '${tester.getRect(find.byType(ChannelHealthStrip))} '
        'ventana=${tester.view.physicalSize} terminó=$second');
    expect(second, isTrue,
        reason: 'y mide todo lo cargado, no sólo la categoría abierta');
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets(
      'el CHECK de una categoría mide sólo esa categoría y apaga los demás',
      (tester) async {
    final database = await seededDatabase();
    addTearDown(database.close);
    final probe = _RecordingProbe();
    await pumpScreen(
      tester,
      database,
      extraOverrides: <Override>[
        channelProbeProvider.overrideWithValue(probe),
      ],
    );

    // Sin ratón encima, el único CHECK de la pantalla es el de la barra
    // superior: los de categoría asoman al acercarse a su fila.
    expect(find.byIcon(Icons.network_check_outlined), findsOneWidget,
        reason: 'los CHECK de categoría están escondidos hasta que se pasa '
            'el ratón por su fila');

    // Las categorías del proveedor viven dentro de una sección plegada.
    await tester.tap(find.textContaining('Groups (').first);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('News'), findsWidgets,
        reason: 'la categoría News está en la barra lateral');

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('News').first));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byIcon(Icons.network_check_outlined), findsNWidgets(2),
        reason: 'el CHECK de la categoría aparece al pasar el ratón por su fila');

    // Se pulsa el de «News»: se comprueba esa categoría y ninguna más.
    await tester.tap(find.byTooltip('Check the channels of News'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ChannelHealthStrip), findsOneWidget);
    expect(find.textContaining('Checking News'), findsWidgets,
        reason: 'el panel dice qué categoría se está midiendo');

    // Mientras corre, los demás nodos quedan apagados.
    await mouse.moveTo(tester.getCenter(find.text('Films').first));
    await tester.pump(const Duration(milliseconds: 200));
    expect(
        find.byTooltip('A check is already running — Films waits its turn'),
        findsWidgets,
        reason: 'los demás CHECK se deshabilitan mientras corre la comprobación');

    final finished = await waitFor(
      tester,
      () => find.text('STOP').evaluate().isEmpty,
      timeout: const Duration(seconds: 120),
    );
    expect(finished, isTrue,
        reason: 'la comprobación de la categoría llega al final');

    // Lo que se midió es la pregunta de esta prueba: la categoría pulsada y
    // ninguna otra. Se mira en la sonda y no en los veredictos, que se guardan
    // entre pasadas y entre pruebas.
    expect(probe.scanned, hasLength(1),
        reason: 'una sola pasada, la de la categoría pulsada');
    final measured = probe.scanned.single;
    expect(measured, isNotEmpty);
    expect(measured.every((channel) => channel.groupTitle == 'News'), isTrue,
        reason: 'sólo canales de News: '
            '${measured.map((c) => '${c.name} (${c.groupTitle})').join(', ')}');
    expect(measured.map((c) => c.streamUrl),
        contains('${server.base}/good/1.m3u8'),
        reason: 'y están todos los de la categoría');
    expect(
        measured.where((c) => c.streamUrl.contains('/dead/')), isEmpty,
        reason: 'los canales de las otras categorías no se tocan');
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('la estrella de una fila añade el canal a la lista de Favoritos',
      (tester) async {
    final database = await seededDatabase();
    addTearDown(database.close);
    final container = await pumpScreen(tester, database);
    final playerService = container.read(playerServiceProvider);

    expect(find.byTooltip('Add to Favorites'), findsWidgets,
        reason: 'cada fila de canal tiene su estrella');

    await tester.tap(find.byTooltip('Add to Favorites').first);
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byTooltip('Remove from Favorites'), findsWidgets,
        reason: 'la estrella se queda rellena');
    expect(playerService.currentChannelId, isNull,
        reason: 'tocar la estrella no abre el canal');

    final favorites = await database
        .getChannelsInList(db.AppDatabase.defaultFavoritesListId);
    expect(favorites, hasLength(1),
        reason: 'el canal queda en la lista fija de favoritos');
    expect(find.textContaining('Favorites (1)'), findsWidgets,
        reason: 'la barra lateral cuenta el favorito nuevo');

    // Y quitarlo también se puede desde la misma estrella.
    await tester.tap(find.byTooltip('Remove from Favorites').first);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byTooltip('Add to Favorites'), findsWidgets);
    expect(await database.getChannelsInList(db.AppDatabase.defaultFavoritesListId),
        isEmpty);
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('al volver a la app se carga solo el último canal visitado',
      (tester) async {
    final database = await seededDatabase();
    addTearDown(database.close);

    // Primera sesión: el usuario abre un canal de «News».
    final first = await pumpScreen(tester, database);
    final firstPlayer = first.read(playerServiceProvider);
    await openCategory(tester, 'News');
    await tapChannelRow(tester, 'News One');
    final played = await waitFor(
      tester,
      () => firstPlayer.currentChannelId != null,
      timeout: const Duration(seconds: 30),
    );
    expect(played, isTrue, reason: 'se puso un canal a mano');
    final watchedId = firstPlayer.currentChannelId;
    final watchedUrl = firstPlayer.currentUrl;
    expect(first.read(channelHistoryProvider).lastChannelId, watchedId,
        reason: 'lo que se ve queda apuntado en el historial');

    // Segunda sesión: la app vuelve sola al último canal y a su categoría.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 300));

    final second = ProviderContainer(
      overrides: <Override>[databaseProvider.overrideWithValue(database)],
    );
    addTearDown(second.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: second,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          routerConfig: testRouter(const ChannelsScreen()),
        ),
      ),
    );
    final secondPlayer = second.read(playerServiceProvider);
    final resumed = await waitFor(
      tester,
      () => secondPlayer.currentChannelId == watchedId,
      timeout: const Duration(seconds: 90),
      step: const Duration(milliseconds: 300),
    );
    // ignore: avoid_print
    print('[verify] último canal recordado: $watchedId '
        '→ al abrir: ${secondPlayer.currentChannelId}');
    expect(resumed, isTrue,
        reason: 'la app vuelve sola al último canal visitado');
    expect(secondPlayer.currentUrl, watchedUrl,
        reason: 'y vuelve al mismo stream que se estaba viendo');
    expect(find.textContaining('News One'), findsWidgets,
        reason: 'la barra lateral se sitúa en su categoría y el canal está '
            'en la lista');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
