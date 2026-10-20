// Al reabrir un pack de temporada hay que elegir el fichero del episodio, no el
// que se vio la última vez: el índice recordado apunta al capítulo anterior.
import 'package:clubtivi/data/datasources/remote/torrent_hash_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reconoce la marca SxxExx', () {
    expect(
      findEpisodeFile(
        const ['Carrie.S01E01.1080p.mkv', 'Carrie.S01E02.1080p.mkv'],
        1,
        2,
      ),
      'Carrie.S01E02.1080p.mkv',
    );
  });

  test('reconoce la marca 1x02 de los packs en castellano', () {
    expect(
      findEpisodeFile(
        const ['Carrie 1x01 (Castellano).mkv', 'Carrie 1x02 (Castellano).mkv'],
        1,
        2,
      ),
      'Carrie 1x02 (Castellano).mkv',
    );
  });

  test('sin capítulo pedido no elige nada', () {
    expect(findEpisodeFile(const ['Carrie.S01E02.mkv'], null, null), isNull);
  });

  test('si el pack no trae ese capítulo no hay nombre', () {
    expect(
      findEpisodeFile(const ['Carrie.S01E01.mkv'], 1, 5),
      isNull,
    );
  });

  test('el magnet mínimo sólo lleva el hash', () {
    expect(magnetForTorrentHash(' ABC123 '), 'magnet:?xt=urn:btih:ABC123');
  });
}
