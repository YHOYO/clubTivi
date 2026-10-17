// El motor se prueba con un cliente y un supervisor falsos: cubre el mapeo
// infoHash + fileIdx → URL local, la espera de metadatos y los errores.
import 'dart:async';
import 'dart:io';

import 'package:clubtivi/data/services/p2p/rqbit_binary.dart';
import 'package:clubtivi/data/services/p2p/rqbit_client.dart';
import 'package:clubtivi/data/services/p2p/rqbit_engine.dart';
import 'package:clubtivi/data/services/p2p/rqbit_models.dart';
import 'package:clubtivi/data/services/p2p/rqbit_supervisor.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeApi implements RqbitApi {
  final List<String> magnets = [];
  final List<String?> outputFolders = [];
  int adds = 0;
  bool overwriteUsed = false;
  List<RqbitTorrentFile> files = const [];
  List<RqbitTorrentDetails> torrentList = const [];
  final List<String> forgotten = [];
  final List<String> deleted = [];
  String? statsError;
  RqbitTorrentStats currentStats =
      const RqbitTorrentStats(state: 'live', progressBytes: 5, totalBytes: 10);
  int initializingPolls = 0;
  int statsCalls = 0;

  @override
  Future<void> ping() async {}

  @override
  Future<RqbitAddResult> addTorrent(
    String magnet, {
    String? outputFolder,
    List<int>? onlyFiles,
    bool overwrite = false,
  }) async {
    adds++;
    overwriteUsed = overwrite;
    magnets.add(magnet);
    outputFolders.add(outputFolder);
    return RqbitAddResult(
      id: 0,
      details: files.isEmpty
          ? null
          : RqbitTorrentDetails(
              id: 0,
              infoHash: 'hash',
              name: 'Torrent',
              files: files,
            ),
    );
  }

  @override
  Future<RqbitTorrentDetails> torrent(String idOrHash) async {
    return RqbitTorrentDetails(
      id: 0,
      infoHash: 'hash',
      name: 'Torrent',
      files: files,
    );
  }

  @override
  Future<RqbitTorrentStats> stats(String idOrHash) async {
    statsCalls++;
    if (initializingPolls > 0) {
      initializingPolls--;
      return const RqbitTorrentStats(
        state: 'initializing',
        progressBytes: 1,
        totalBytes: 10,
      );
    }
    if (statsError != null) {
      return RqbitTorrentStats(state: 'error', error: statsError);
    }
    return currentStats;
  }

  @override
  Future<List<RqbitTorrentDetails>> listTorrents({bool withStats = true}) async =>
      torrentList;

  @override
  Future<void> forgetTorrent(String idOrHash) async {
    forgotten.add(idOrHash);
    torrentList =
        torrentList.where((torrent) => '${torrent.id}' != idOrHash).toList();
  }

  @override
  Future<void> deleteTorrent(String idOrHash) async {
    deleted.add(idOrHash);
    torrentList =
        torrentList.where((torrent) => '${torrent.id}' != idOrHash).toList();
  }

  @override
  Uri streamUrl(String idOrHash, int fileIndex) => Uri.parse(
        'http://127.0.0.1:45678/torrents/$idOrHash/stream/$fileIndex',
      );
}

class _FakeProcess implements RqbitProcessHandle {
  _FakeProcess(this.pid);

  @override
  final int pid;

  final Completer<int> _exit = Completer<int>();

  @override
  Stream<List<int>> get stdout => const Stream.empty();

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  Future<int> get exitCode => _exit.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_exit.isCompleted) _exit.complete(-1);
    return true;
  }
}

void main() {
  late Directory root;
  late Directory bundled;
  late _FakeApi api;
  late RqbitSupervisor supervisor;
  late RqbitBinary binary;
  late RqbitEngine engine;
  var supervisorStarts = 0;

  setUp(() async {
    supervisorStarts = 0;
    root = await Directory.systemTemp.createTemp('rqbit-engine-');
    bundled = Directory('${root.path}${Platform.pathSeparator}app');
    await bundled.create(recursive: true);
    await File('${bundled.path}${Platform.pathSeparator}rqbit.exe')
        .writeAsBytes(const [1, 2, 3]);

    api = _FakeApi();
    supervisor = RqbitSupervisor(
      downloadDirectory: '${root.path}${Platform.pathSeparator}downloads',
      stateDirectory: '${root.path}${Platform.pathSeparator}session',
      startProcess: (exe, args) async {
        supervisorStarts++;
        return _FakeProcess(5000 + supervisorStarts);
      },
      allocatePort: () async => 45678,
      probe: (_) async => true,
      probeInterval: const Duration(milliseconds: 5),
      restartDelay: Duration.zero,
      maxRestarts: 0,
    );
    binary = RqbitBinary(
      cacheDirectory: Directory('${root.path}${Platform.pathSeparator}cache'),
      executableDirectory: bundled.path,
      allowDownload: false,
    );
    engine = RqbitEngine(
      supervisor: supervisor,
      binary: binary,
      outputDirectory: '${root.path}${Platform.pathSeparator}downloads',
      apiFactory: (_) => api,
      metadataTimeout: const Duration(milliseconds: 200),
      readinessTimeout: const Duration(milliseconds: 200),
      pollInterval: const Duration(milliseconds: 10),
    );
  });

  tearDown(() async {
    await engine.dispose();
    if (await root.exists()) await root.delete(recursive: true);
  });

  P2pStreamRequest request({
    String hash = '08ada5a7a6183aae1e09d831df6748d566095a10',
    int? fileIndex,
    String? magnetUrl,
  }) {
    return P2pStreamRequest(
      infoHash: hash,
      fileIndex: fileIndex,
      title: 'Sintel',
      magnetUrl: magnetUrl,
    );
  }

  test('mapea infoHash + fileIdx al endpoint de streaming local', () async {
    api.files = const [
      RqbitTorrentFile(name: 'sample.mkv', length: 10),
      RqbitTorrentFile(name: 'Sintel.mp4', length: 1000),
    ];

    final playback = await engine.prepare(request(fileIndex: 1));

    expect(playback.fileIndex, 1);
    expect(playback.fileName, 'Sintel.mp4');
    expect(playback.streamUrl.path, '/torrents/0/stream/1');
    expect(playback.streamUrl.host, '127.0.0.1');
    expect(playback.streamUrl.port, 45678);
    expect(supervisorStarts, 1);
  });

  test('respeta el magnet con trackers y la carpeta de descargas', () async {
    api.files = const [RqbitTorrentFile(name: 'Sintel.mp4', length: 10)];
    const magnet = 'magnet:?xt=urn:btih:08ada5a7a6183aae1e09d831df6748d566095a10'
        '&dn=Sintel&tr=udp%3A%2F%2Ftracker.example%3A1337%2Fannounce';

    await engine.prepare(request(fileIndex: 0, magnetUrl: magnet));

    expect(api.magnets.single, magnet);
    expect(api.outputFolders.single, contains('downloads'));
  });

  test('un fileIdx inválido cae al vídeo incluido más grande', () async {
    api.files = const [
      RqbitTorrentFile(name: 'sample.mkv', length: 10),
      RqbitTorrentFile(name: 'Sintel.mp4', length: 1000),
    ];

    final playback = await engine.prepare(request(fileIndex: 99));

    expect(playback.fileIndex, 1);
  });

  test('sin metadatos el timeout es un error legible, no una espera infinita',
      () async {
    api.files = const [];

    await expectLater(
      engine.prepare(request(fileIndex: 0)),
      throwsA(
        isA<RqbitMetadataTimeoutException>().having(
          (error) => error.message,
          'message',
          contains('No metadata'),
        ),
      ),
    );
  });

  test('un error del torrent en stats se propaga con su mensaje', () async {
    api.files = const [];
    api.statsError = 'disk full';

    await expectLater(
      engine.prepare(request(fileIndex: 0)),
      throwsA(
        isA<RqbitTorrentErrorException>().having(
          (error) => error.message,
          'message',
          'disk full',
        ),
      ),
    );
  });

  test('espera a que el torrent esté live antes de devolver el stream',
      () async {
    api.files = const [RqbitTorrentFile(name: 'Sintel.mp4', length: 10)];
    api.initializingPolls = 2;

    final playback = await engine.prepare(request(fileIndex: 0));

    expect(playback.streamUrl.path, '/torrents/0/stream/0');
    expect(api.statsCalls, greaterThan(2),
        reason: 'mientras initializing no se puede servir el stream');
  });

  test('un torrent que no sale de initializing agota su timeout', () async {
    api.files = const [RqbitTorrentFile(name: 'Sintel.mp4', length: 10)];
    api.initializingPolls = 1000;

    await expectLater(
      engine.prepare(request(fileIndex: 0)),
      throwsA(
        isA<RqbitTorrentNotReadyException>().having(
          (error) => error.message,
          'message',
          contains('initializing'),
        ),
      ),
    );
  });

  test('añade con overwrite para poder reanudar archivos ya presentes',
      () async {
    api.files = const [RqbitTorrentFile(name: 'Sintel.mp4', length: 10)];

    await engine.prepare(request(fileIndex: 0));

    expect(api.overwriteUsed, isTrue);
  });

  test('sin motor arrancado no hay torrents ni acciones', () async {
    expect(await engine.listTorrents(), isEmpty);
    expect(engine.isRunning, isFalse);
    await engine.removeTorrent('0');
    expect(api.forgotten, isEmpty,
        reason: 'sin API no se llama a un motor que no existe');
  });

  test('quitar un torrent usa forget y borra la caché del hash', () async {
    api.files = const [RqbitTorrentFile(name: 'Sintel.mp4', length: 10)];
    api.torrentList = const [
      RqbitTorrentDetails(
        id: 0,
        infoHash: 'hash',
        name: 'Sintel',
        files: [RqbitTorrentFile(name: 'Sintel.mp4', length: 10)],
        stats: RqbitTorrentStats(
          state: 'live',
          progressBytes: 5,
          totalBytes: 10,
        ),
      ),
    ];
    await engine.prepare(request(fileIndex: 0));

    expect((await engine.listTorrents()).single.stats!.progress, 0.5);

    await engine.removeTorrent('0');

    expect(api.forgotten, ['0']);
    expect(api.deleted, isEmpty);
    expect(await engine.listTorrents(), isEmpty);

    // Tras olvidarlo, el siguiente play lo vuelve a añadir.
    await engine.prepare(request(fileIndex: 0));
    expect(api.adds, 2);
  });

  test('borrar con archivos usa delete en vez de forget', () async {
    api.files = const [RqbitTorrentFile(name: 'Sintel.mp4', length: 10)];
    await engine.prepare(request(fileIndex: 0));

    await engine.removeTorrent('0', deleteFiles: true);

    expect(api.deleted, ['0']);
    expect(api.forgotten, isEmpty);
  });

  test('vaciar la sesión olvida todo, para el motor y borra su estado',
      () async {
    api.files = const [RqbitTorrentFile(name: 'Sintel.mp4', length: 10)];
    api.torrentList = const [
      RqbitTorrentDetails(
        id: 0,
        infoHash: 'hash',
        name: 'Sintel',
        files: [RqbitTorrentFile(name: 'Sintel.mp4', length: 10)],
      ),
    ];
    await engine.prepare(request(fileIndex: 0));
    final session = Directory(engine.sessionDirectory);
    expect(await session.exists(), isTrue);

    await engine.clearSession();

    expect(api.forgotten, ['0']);
    expect(engine.isRunning, isFalse);
    expect(await session.exists(), isFalse);

    // El motor vuelve a arrancar para el siguiente play.
    await engine.prepare(request(fileIndex: 0));
    expect(engine.isRunning, isTrue);
  });

  test('parar el motor no lo cierra: el siguiente play lo arranca', () async {
    api.files = const [RqbitTorrentFile(name: 'Sintel.mp4', length: 10)];
    await engine.prepare(request(fileIndex: 0));

    await engine.stop();
    expect(engine.isRunning, isFalse);

    await engine.prepare(request(fileIndex: 0));
    expect(engine.isRunning, isTrue);
    expect(supervisorStarts, 2);
  });

  test('el segundo play del mismo hash no vuelve a añadir el torrent', () async {
    api.files = const [RqbitTorrentFile(name: 'Sintel.mp4', length: 10)];

    await engine.prepare(request(fileIndex: 0));
    await engine.prepare(request(fileIndex: 0));

    expect(api.adds, 1);
    expect(supervisorStarts, 1);
  });

  test('cancelar antes de añadir no toca rqbit', () async {
    await expectLater(
      engine.prepare(request(), isCancelled: () => true),
      throwsA(isA<P2pCancelledException>()),
    );
    expect(api.adds, 0);
    expect(supervisorStarts, 0);
  });

  test('sin binario el error llega antes de arrancar nada', () async {
    final missing = RqbitEngine(
      supervisor: supervisor,
      binary: RqbitBinary(
        cacheDirectory:
            Directory('${root.path}${Platform.pathSeparator}empty-cache'),
        executableDirectory:
            '${root.path}${Platform.pathSeparator}does-not-exist',
        allowDownload: false,
      ),
      outputDirectory: root.path,
    );

    await expectLater(
      missing.prepare(request()),
      throwsA(isA<RqbitBinaryMissingException>()),
    );
    expect(supervisorStarts, 0);
  });
}
