// El reproductor recibe una URL y, desde este paso, también la identidad de lo
// que reproduce. Aquí se fija el contrato del `extra` de `/player`: un canal en
// vivo no lleva identidad, un VOD sí, y nada más cambia.
import 'package:clubtivi/data/models/playback_request.dart';
import 'package:clubtivi/features/player/player_screen.dart';
import 'package:flutter_test/flutter_test.dart';

const _episode = PlaybackRequest(
  kind: PlaybackKind.series,
  mediaKey: 'imdb:tt7654321',
  season: 1,
  episode: 2,
  title: 'Carrie S01E02',
  sourceId: 'torrentio:def:1',
);

void main() {
  test('un VOD conserva la identidad que venía en el extra', () {
    final screen = PlayerScreen.fromExtra({
      'streamUrl': 'https://p1.alldebrid.com/dl/1/carrie-s01e02.mkv',
      'channelName': 'Carrie S01E02',
      'channelLogo': 'https://img.test/poster.jpg',
      'httpHeaders': {'Referer': 'https://cdn.test/'},
      'playback': _episode,
    });

    expect(screen.playback, _episode);
    expect(screen.streamUrl, 'https://p1.alldebrid.com/dl/1/carrie-s01e02.mkv');
    expect(screen.channelName, 'Carrie S01E02');
    expect(screen.httpHeaders, {'Referer': 'https://cdn.test/'});
  });

  test('un canal en vivo sigue llegando sin identidad de reproducción', () {
    final screen = PlayerScreen.fromExtra({
      'streamUrl': 'http://iptv.test/live/1.m3u8',
      'channelName': 'La 1',
      'channels': <Map<String, dynamic>>[
        {'id': 1, 'name': 'La 1'},
      ],
      'currentIndex': 0,
    });

    expect(screen.playback, isNull);
    expect(screen.channelName, 'La 1');
    expect(screen.channels, hasLength(1));
  });

  test('sin extra el reproductor arranca como antes', () {
    final screen = PlayerScreen.fromExtra(null);

    expect(screen.streamUrl, '');
    expect(screen.channelName, '');
    expect(screen.playback, isNull);
  });
}
