// La descarga del motor solo vale si se verifica: estos tests sirven bytes
// falsos y comprueban caché, checksum y errores.
import 'dart:io';

import 'package:clubtivi/data/services/p2p/rqbit_binary.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

class _DownloadServer {
  final HttpServer server;
  int requests = 0;
  int status = 200;

  _DownloadServer._(this.server) {
    server.listen((request) async {
      requests++;
      request.response.statusCode = status;
      if (status == 200) {
        request.response.add(payload);
      }
      await request.response.close();
    });
  }

  static const payload = <int>[1, 2, 3, 4, 5, 6, 7, 8, 9, 10];

  static Future<_DownloadServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _DownloadServer._(server);
  }

  Uri get uri => Uri.parse('http://127.0.0.1:${server.port}/rqbit.exe');

  Future<void> close() => server.close(force: true);
}

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

void main() {
  late Directory root;
  late Directory cache;
  late Directory bundled;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('rqbit-binary-');
    cache = Directory('${root.path}${Platform.pathSeparator}cache');
    bundled = Directory('${root.path}${Platform.pathSeparator}app');
    await bundled.create(recursive: true);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('el binario junto a la app tiene prioridad y no descarga', () async {
    await File('${bundled.path}${Platform.pathSeparator}rqbit.exe')
        .writeAsBytes(const [1, 2, 3]);

    final binary = RqbitBinary(
      cacheDirectory: cache,
      executableDirectory: bundled.path,
      downloadUri: Uri.parse('http://127.0.0.1:1/never'),
      expectedSha256: 'unused',
    );

    final location = await binary.ensureAvailable();

    expect(location.source, RqbitBinarySource.bundled);
    expect(location.path, endsWith('rqbit.exe'));
  });

  test('descarga, verifica el hash y luego reutiliza la caché', () async {
    final server = await _DownloadServer.start();
    addTearDown(server.close);
    final binary = RqbitBinary(
      cacheDirectory: cache,
      downloadUri: server.uri,
      expectedSha256: _sha(_DownloadServer.payload),
    );
    final progress = <RqbitDownloadProgress>[];

    final location = await binary.ensureAvailable(onProgress: progress.add);

    expect(location.source, RqbitBinarySource.downloaded);
    expect(await File(location.path).readAsBytes(), _DownloadServer.payload);
    expect(progress, isNotEmpty);
    expect(progress.last.fraction, 1);
    expect(server.requests, 1);

    final again = await binary.ensureAvailable();
    expect(again.source, RqbitBinarySource.cache);
    expect(server.requests, 1, reason: 'la caché evita otra descarga');
  });

  test('un hash que no coincide borra la descarga y falla', () async {
    final server = await _DownloadServer.start();
    addTearDown(server.close);
    final binary = RqbitBinary(
      cacheDirectory: cache,
      downloadUri: server.uri,
      expectedSha256: '0' * 64,
    );

    await expectLater(
      binary.ensureAvailable(),
      throwsA(isA<RqbitBinaryChecksumException>()),
    );
    expect(
      await File('${cache.path}${Platform.pathSeparator}rqbit-9.0.1'
              '${Platform.pathSeparator}rqbit.exe.download')
          .exists(),
      isFalse,
    );
  });

  test('un HTTP de error se reporta como descarga fallida', () async {
    final server = await _DownloadServer.start();
    server.status = 503;
    addTearDown(server.close);
    final binary = RqbitBinary(
      cacheDirectory: cache,
      downloadUri: server.uri,
      expectedSha256: _sha(_DownloadServer.payload),
    );

    await expectLater(
      binary.ensureAvailable(),
      throwsA(isA<RqbitBinaryDownloadException>()),
    );
  });

  test('sin binario empaquetado y sin descarga el error es explícito', () async {
    final binary = RqbitBinary(
      cacheDirectory: cache,
      executableDirectory: bundled.path,
      allowDownload: false,
    );

    await expectLater(
      binary.ensureAvailable(),
      throwsA(
        isA<RqbitBinaryMissingException>().having(
          (error) => error.message,
          'message',
          contains('not included in this build'),
        ),
      ),
    );
  });
}
