// La frontera que dejaba inutilizables las fuentes de addon: las cabeceras y
// `needsProxy` tienen que sobrevivir desde el selector hasta el reproductor.
import 'package:clubtivi/data/models/stream_source.dart';
import 'package:clubtivi/data/services/stream_playback.dart';
import 'package:flutter_test/flutter_test.dart';

StreamSource _source({
  Map<String, String> headers = const {},
  String? referer,
  bool needsProxy = false,
}) {
  return StreamSource(
    id: 'addon:url:0',
    providerId: 'com.stremio.torrentio.addon',
    providerName: 'Torrentio',
    kind: SourceKind.addon,
    title: 'Movie.2024.1080p',
    url: 'https://cdn.example/movie.mp4',
    headers: headers,
    referer: referer,
    needsProxy: needsProxy,
  );
}

void main() {
  test('una fuente sin cabeceras no activa nada', () {
    expect(playbackHeaders(null), isEmpty);
    expect(playbackHeaders(_source()), isEmpty);
    expect(shouldProxyStream(null), isFalse);
    expect(shouldProxyStream(_source()), isFalse);
  });

  test('el referer propio gana sin duplicar la entrada del mapa', () {
    final headers = playbackHeaders(
      _source(
        headers: {
          'referer': 'https://wrong.example/',
          'User-Agent': 'ClubTivi/0.4',
        },
        referer: 'https://source.example/',
      ),
    );

    expect(headers, hasLength(2));
    expect(headers['Referer'], 'https://source.example/');
    expect(headers['User-Agent'], 'ClubTivi/0.4');
  });

  test('descarta cabeceras vacías y espacios sobrantes', () {
    final headers = playbackHeaders(
      _source(
        headers: {
          ' Referer ': ' https://source.example/ ',
          'X-Empty': '   ',
          '': 'sin-nombre',
        },
      ),
    );

    expect(headers, {'Referer': 'https://source.example/'});
  });

  test('needsProxy basta por sí solo; las cabeceras también', () {
    expect(shouldProxyStream(_source(needsProxy: true)), isTrue);
    expect(
      shouldProxyStream(
        _source(headers: {'Referer': 'https://source.example/'}),
      ),
      isTrue,
    );
  });
}
