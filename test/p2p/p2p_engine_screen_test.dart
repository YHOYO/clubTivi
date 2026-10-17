// La pantalla de ajustes es la puerta del motor: debe enseñar su estado real,
// guardar en el store que usan el supervisor y el proveedor, y no borrar nada
// sin confirmación. El motor se sustituye por un doble para que el test mire
// solo la pantalla: el motor real tiene sus propias pruebas.
import 'dart:convert';
import 'dart:io';

import 'package:clubtivi/app/router.dart';
import 'package:clubtivi/data/services/p2p/p2p_providers.dart';
import 'package:clubtivi/data/services/p2p/p2p_settings.dart';
import 'package:clubtivi/data/services/p2p/rqbit_binary.dart';
import 'package:clubtivi/data/services/p2p/rqbit_engine.dart';
import 'package:clubtivi/data/services/p2p/rqbit_models.dart';
import 'package:clubtivi/data/services/p2p/rqbit_supervisor.dart';
import 'package:clubtivi/features/settings/p2p_engine_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Motor doble: sin proceso, sin disco y con las llamadas a la vista.
class _FakeEngine extends RqbitEngine {
  _FakeEngine()
      : super(
          supervisor: RqbitSupervisor(
            downloadDirectory: '.',
            stateDirectory: '.',
          ),
          binary: RqbitBinary(cacheDirectory: Directory('.')),
          outputDirectory: '.',
        );

  bool running = true;
  List<RqbitTorrentDetails> torrents = const [];
  final List<String> removed = [];
  final List<String> deleted = [];
  int cleared = 0;
  int stopped = 0;

  @override
  bool get isRunning => running;

  @override
  Uri? get baseUri =>
      running ? Uri.parse('http://127.0.0.1:45678') : null;

  @override
  Future<List<RqbitTorrentDetails>> listTorrents() async => torrents;

  @override
  Future<void> removeTorrent(String idOrHash, {bool deleteFiles = false}) async {
    if (deleteFiles) {
      deleted.add(idOrHash);
    } else {
      removed.add(idOrHash);
    }
    torrents =
        torrents.where((torrent) => '${torrent.id}' != idOrHash).toList();
  }

  @override
  Future<void> stop() async {
    stopped++;
    running = false;
  }

  @override
  Future<void> clearSession() async {
    cleared++;
    torrents = const [];
    running = false;
  }

  @override
  Future<void> dispose() async {
    running = false;
  }
}

void main() {
  late _FakeEngine engine;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    engine = _FakeEngine();
  });

  Future<ProviderContainer> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final notifier = P2pSettingsNotifier();
    await notifier.load();

    final container = ProviderContainer(
      overrides: [
        p2pSettingsProvider.overrideWith((ref) => notifier),
        rqbitEngineProvider.overrideWith((ref) async => engine),
        p2pBinaryLocationProvider.overrideWith(
          (ref) async => const RqbitBinaryLocation(
            'C:/app/rqbit.exe',
            RqbitBinarySource.bundled,
          ),
        ),
        p2pDefaultDownloadDirectoryProvider
            .overrideWith((ref) async => 'C:/Users/x/Downloads/clubTivi'),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: P2pEngineScreen(refreshInterval: Duration.zero),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  RqbitTorrentDetails torrent({int id = 0, String name = 'Sintel'}) {
    return RqbitTorrentDetails(
      id: id,
      infoHash: 'hash',
      name: name,
      files: const [RqbitTorrentFile(name: 'Sintel.mp4', length: 10)],
      stats: const RqbitTorrentStats(
        state: 'live',
        progressBytes: 250,
        totalBytes: 1000,
      ),
    );
  }

  test('la ruta /p2p-engine está registrada en Ajustes', () {
    final paths = <String>[];
    void collect(List<RouteBase> routes) {
      for (final route in routes) {
        if (route is GoRoute) {
          paths.add(route.path);
          collect(route.routes);
        } else if (route is ShellRoute) {
          collect(route.routes);
        }
      }
    }

    collect(createRouter().configuration.routes);

    expect(paths, contains('/settings'));
    expect(paths, contains('/p2p-engine'));
  });

  testWidgets('enseña el estado del motor, el binario y los ajustes guardados',
      (tester) async {
    await pumpScreen(tester);

    expect(find.text('P2P Engine'), findsOneWidget);
    expect(find.textContaining('Running on 127.0.0.1:45678'), findsOneWidget);
    expect(find.textContaining('Bundled with the app'), findsOneWidget);
    expect(find.textContaining('rqbit 9.0.1'), findsOneWidget);
    expect(find.text('C:/Users/x/Downloads/clubTivi'), findsOneWidget);
    expect(find.textContaining('No torrents in the session'), findsOneWidget);
  });

  testWidgets('guarda puerto y límites en el store persistido', (tester) async {
    final container = await pumpScreen(tester);

    await tester.enterText(find.byKey(const ValueKey('p2p-port')), '4040');
    await tester.enterText(
      find.byKey(const ValueKey('p2p-download-limit')),
      '256',
    );
    await tester.enterText(
      find.byKey(const ValueKey('p2p-upload-limit')),
      '64',
    );
    await tester.tap(find.byKey(const ValueKey('p2p-save')));
    await tester.pumpAndSettle();

    final saved = container.read(p2pSettingsProvider);
    expect(saved.port, 4040);
    expect(saved.downloadLimitKbps, 256);
    expect(saved.uploadLimitKbps, 64);

    final raw = (await SharedPreferences.getInstance())
        .getString(p2pSettingsKey);
    expect(P2pSettings.fromJson(jsonDecode(raw!)).port, 4040);
    expect(find.textContaining('engine restarts'), findsOneWidget);
  });

  testWidgets('un puerto inválido se explica y no se guarda', (tester) async {
    final container = await pumpScreen(tester);

    await tester.enterText(find.byKey(const ValueKey('p2p-port')), '99');
    await tester.tap(find.byKey(const ValueKey('p2p-save')));
    await tester.pumpAndSettle();

    expect(find.text('Use a port between 1024 and 65535'), findsOneWidget);
    expect(container.read(p2pSettingsProvider).port, isNull);
  });

  testWidgets('los ajustes ya guardados llegan a los campos', (tester) async {
    SharedPreferences.setMockInitialValues({
      p2pSettingsKey: jsonEncode(
        const P2pSettings(
          downloadDirectory: 'D:/Media',
          port: 33123,
          downloadLimitKbps: 512,
        ).toJson(),
      ),
    });
    await pumpScreen(tester);

    expect(find.text('D:/Media'), findsOneWidget);
    expect(find.text('Custom folder'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byKey(const ValueKey('p2p-port'))).controller!.text,
      '33123',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('p2p-download-limit')))
          .controller!
          .text,
      '512',
    );
  });

  testWidgets('lista los torrents con su estado y deja quitarlos sin borrar',
      (tester) async {
    engine.torrents = [torrent()];
    await pumpScreen(tester);

    expect(find.text('Sintel'), findsOneWidget);
    expect(find.textContaining('live · 25%'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('p2p-torrent-remove-0')));
    await tester.pumpAndSettle();

    expect(engine.removed, ['0']);
    expect(engine.deleted, isEmpty);
    expect(find.text('Sintel'), findsNothing);
  });

  testWidgets('borrar los archivos pide confirmación antes de nada',
      (tester) async {
    engine.torrents = [torrent()];
    await pumpScreen(tester);

    await tester.tap(find.byKey(const ValueKey('p2p-torrent-delete-0')));
    await tester.pumpAndSettle();
    expect(find.text('Delete torrent and files?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(engine.deleted, isEmpty);
    expect(find.text('Sintel'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('p2p-torrent-delete-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(engine.deleted, ['0']);
  });

  testWidgets('vaciar la sesión avisa de que los archivos se conservan',
      (tester) async {
    engine.torrents = [torrent()];
    final container = await pumpScreen(tester);

    await tester.tap(find.byKey(const ValueKey('p2p-clear-session')));
    await tester.pumpAndSettle();
    expect(find.text('Clear the P2P session?'), findsOneWidget);
    expect(find.textContaining('stay in the downloads folder'), findsOneWidget);

    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();

    expect(engine.cleared, 1);
    expect(engine.isRunning, isFalse);
    expect(find.textContaining('Session cleared'), findsOneWidget);
    expect(container.read(p2pSettingsProvider), P2pSettings.defaults,
        reason: 'vaciar la sesión no toca los ajustes');
  });

  testWidgets('parar el motor lo dice y no borra la sesión', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.byKey(const ValueKey('p2p-stop')));
    await tester.pumpAndSettle();

    expect(engine.stopped, 1);
    expect(engine.cleared, 0);
    expect(engine.isRunning, isFalse);
    expect(find.text('Not running'), findsOneWidget);
  });
}
