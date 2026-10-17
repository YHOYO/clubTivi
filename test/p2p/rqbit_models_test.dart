import 'package:clubtivi/data/services/p2p/rqbit_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseo de la API', () {
    test('el id 0 es un id válido', () {
      final result = RqbitAddResult.fromJson({
        'id': 0,
        'details': {
          'id': 0,
          'info_hash': 'ABC',
          'name': 'Movie',
          'files': [
            {'name': 'Movie.mkv', 'length': 1024, 'included': true},
          ],
        },
      });

      expect(result.id, 0);
      expect(result.details!.hasMetadata, isTrue);
      expect(result.details!.files.single.name, 'Movie.mkv');
    });

    test('sin metadatos files viene vacío y hasMetadata es false', () {
      final details = RqbitTorrentDetails.fromJson({
        'id': 3,
        'info_hash': 'ABC',
        'name': 'Movie',
        'files': <Object>[],
      });

      expect(details.hasMetadata, isFalse);
      expect(details.files, isEmpty);
    });

    test('un archivo sin included explícito cuenta como incluido', () {
      final file = RqbitTorrentFile.fromJson({'name': 'a.mp4', 'length': 10});

      expect(file.included, isTrue);
      expect(file.length, 10);
    });

    test('los stats calculan el progreso y conservan el error', () {
      final stats = RqbitTorrentStats.fromJson({
        'state': 'live',
        'progress_bytes': 25,
        'total_bytes': 100,
        'finished': false,
        'error': null,
      });

      expect(stats.progress, closeTo(0.25, 0.0001));
      expect(stats.error, isNull);

      final failed = RqbitTorrentStats.fromJson({
        'state': 'error',
        'error': 'disk full',
      });
      expect(failed.error, 'disk full');
      expect(failed.progress, isNull);
    });
  });

  group('magnet', () {
    const hash = '08ADA5A7A6183AAE1E09D831DF6748D566095A10';

    test('respeta el magnet del addon con sus trackers', () {
      const magnet = 'magnet:?xt=urn:btih:$hash'
          '&dn=Sintel&tr=udp%3A%2F%2Ftracker.example%3A1337%2Fannounce';
      final request = P2pStreamRequest(infoHash: hash, magnetUrl: magnet);

      expect(request.magnet, magnet);
    });

    test('si el magnet es de otro hash, se construye con el bueno', () {
      final request = P2pStreamRequest(
        infoHash: hash,
        magnetUrl: 'magnet:?xt=urn:btih:0000000000000000000000000000000000000000',
        title: 'Sintel',
      );

      expect(request.magnet, contains(hash));
      expect(request.magnet, isNot(contains('btih:0000')));
      expect(request.magnet, contains('dn=Sintel'));
    });

    test('sin magnet se construye con hash y título codificado', () {
      final magnet = buildP2pMagnet(
        infoHash: hash,
        name: 'Movie 2024 & more',
      );

      expect(magnet, startsWith('magnet:?xt=urn:btih:$hash'));
      expect(magnet, contains('dn=Movie%202024%20%26%20more'));
    });

    test('sin título el magnet sigue siendo válido', () {
      expect(
        buildP2pMagnet(infoHash: hash),
        'magnet:?xt=urn:btih:$hash',
      );
    });
  });

  group('selección de archivo', () {
    const files = [
      RqbitTorrentFile(name: 'sample.mkv', length: 10),
      RqbitTorrentFile(name: 'movie.mp4', length: 1000),
      RqbitTorrentFile(name: 'extras.mkv', length: 2000, included: false),
      RqbitTorrentFile(name: 'notes.txt', length: 5000),
      RqbitTorrentFile(name: 'subs.srt', length: 5),
    ];

    test('fileIdx del addon manda si existe y está incluido', () {
      expect(selectTorrentFileIndex(files, 0), 0);
      expect(selectTorrentFileIndex(files, 3), 3);
    });

    test('un fileIdx excluido o fuera de rango cae al vídeo más grande', () {
      expect(selectTorrentFileIndex(files, 2), 1);
      expect(selectTorrentFileIndex(files, 99), 1);
      expect(selectTorrentFileIndex(files, -1), 1);
    });

    test('sin vídeos elige el archivo incluido más grande', () {
      const onlyText = [
        RqbitTorrentFile(name: 'a.txt', length: 10),
        RqbitTorrentFile(name: 'b.bin', length: 30),
        RqbitTorrentFile(name: 'c.bin', length: 20),
      ];

      expect(selectTorrentFileIndex(onlyText, null), 1);
    });

    test('un torrent sin archivos no se puede mapear', () {
      expect(
        () => selectTorrentFileIndex(const [], null),
        throwsA(isA<RqbitNoFilesException>()),
      );
    });
  });
}
