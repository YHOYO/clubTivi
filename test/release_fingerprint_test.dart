// La huella no puede depender del enlace que caduca: mismo release, mismo id
// hoy y dentro de un mes; distinto fichero del pack, distinto id.
import 'package:clubtivi/data/models/release_fingerprint.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('el mismo release da siempre el mismo id', () {
    final first = releaseSourceId(
      providerId: 'torrentio',
      infoHash: 'ABC123DEF',
      fileIdx: 3,
      quality: '1080p',
    );
    // «Otra sesión»: mismos datos, objetos nuevos.
    final second = releaseSourceId(
      providerId: ' torrentio ',
      infoHash: 'abc123def',
      fileIdx: 3,
      quality: '1080P',
    );

    expect(second, first);
    expect(first, 'torrent:torrentio:abc123def:f3:1080p');
  });

  test('otro fileIdx del mismo torrent es otro release', () {
    final first = releaseSourceId(
      providerId: 'torrentio',
      infoHash: 'abc123',
      fileIdx: 0,
    );
    final second = releaseSourceId(
      providerId: 'torrentio',
      infoHash: 'abc123',
      fileIdx: 1,
    );

    expect(first, isNot(second));
  });

  test('otro proveedor con el mismo hash es otro release', () {
    expect(
      releaseSourceId(providerId: 'torrentio', infoHash: 'abc', fileIdx: 0),
      isNot(
        releaseSourceId(providerId: 'comet', infoHash: 'abc', fileIdx: 0),
      ),
    );
  });

  test('la calidad forma parte de la huella', () {
    expect(
      releaseSourceId(providerId: 'torrentio', infoHash: 'abc', fileIdx: 0),
      isNot(
        releaseSourceId(
          providerId: 'torrentio',
          infoHash: 'abc',
          fileIdx: 0,
          quality: '4K',
        ),
      ),
    );
  });

  test('un enlace directo ignora la query firmada', () {
    final first = releaseSourceIdFrom(
      providerId: 'addon',
      url: 'https://cdn.test/movie.m3u8?token=uno',
    );
    final second = releaseSourceIdFrom(
      providerId: 'addon',
      url: 'https://cdn.test/movie.m3u8?token=dos',
    );

    expect(first, second);
    expect(first, 'direct:addon:cdn.test/movie.m3u8');
  });

  test('un enlace directo con otra ruta es otro release', () {
    expect(
      releaseSourceIdFrom(providerId: 'addon', url: 'https://cdn.test/a.m3u8'),
      isNot(
        releaseSourceIdFrom(
          providerId: 'addon',
          url: 'https://cdn.test/b.m3u8',
        ),
      ),
    );
  });

  test('con hash, la URL no cambia la huella', () {
    final withUrl = releaseSourceIdFrom(
      providerId: 'torrentio',
      infoHash: 'abc',
      fileIdx: 2,
      url: 'https://alldebrid.com/dl/caducado',
    );

    expect(
      withUrl,
      releaseSourceId(providerId: 'torrentio', infoHash: 'abc', fileIdx: 2),
    );
  });
}
