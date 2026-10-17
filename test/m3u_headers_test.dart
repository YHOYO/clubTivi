// El parser debe conservar las cabeceras #EXTVLCOPT de cada entrada, que es lo
// que separa un canal que responde 200 de uno que responde 403 en las listas
// que protegen su CDN con referrer (TDTChannels, entre otras).
import 'package:clubtivi/data/datasources/parsers/m3u_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const playlist = '''
#EXTM3U url-tvg="https://example.com/epg.xml.gz"
#EXTINF:-1 tvg-id="La1.TV" group-title="Generalistas",La 1
https://example.com/la1.m3u8
#EXTINF:-1 tvg-id="ETBD.TV" group-title="Deportivos",ETB Deportes
#EXTVLCOPT:http-referrer=https://kirolakeitb.eus/es/kirolak-360/en-directo/
https://example.com/etb.m3u8
#EXTINF:-1 tvg-id="101Malaga.TV" group-title="Andalucía",101TV Málaga
#EXTVLCOPT:http-user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64)
#EXTVLCOPT:http-referrer=https://player.instantvideocloud.net/
https://example.com/101.m3u8
''';

  test('guarda referrer y user-agent como cabeceras HTTP del canal', () {
    final channels = M3uParser().parse(playlist, providerId: 'p').channels;

    expect(channels.length, 3);

    // El canal sin directivas no arrastra cabeceras.
    expect(channels[0].name, 'La 1');
    expect(channels[0].httpHeaders, isEmpty);

    expect(channels[1].name, 'ETB Deportes');
    expect(channels[1].httpHeaders, {
      'Referer': 'https://kirolakeitb.eus/es/kirolak-360/en-directo/',
    });

    expect(channels[2].httpHeaders, {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
      'Referer': 'https://player.instantvideocloud.net/',
    });
  });

  test('las cabeceras no se arrastran a la entrada siguiente', () {
    final channels = M3uParser().parse(playlist, providerId: 'p').channels;

    // La 1 va antes de las entradas con directivas; la comprobación que importa
    // es que las cabeceras de una entrada no sobrevivan a la siguiente.
    for (var i = 1; i < channels.length; i++) {
      final names = channels[i].httpHeaders.keys.toSet();
      final previous = channels[i - 1].httpHeaders.keys.toSet();
      if (names.isEmpty) continue;
      expect(previous.containsAll(names), isFalse,
          reason: 'el canal ${channels[i].name} recibió cabeceras de otro');
    }
  });

  test('reconoce otras directivas http-* con su nombre de cabecera', () {
    const content = '''
#EXTM3U
#EXTINF:-1,Prueba
#EXTVLCOPT:http-origin=https://example.com
#EXTVLCOPT:http-cookies=session=abc
#EXTVLCOPT:http-custom-thing=1
#EXTVLCOPT:no-http-option=ignored
https://example.com/x.m3u8
''';
    final channel = M3uParser().parse(content, providerId: 'p').channels.single;

    expect(channel.httpHeaders, {
      'Origin': 'https://example.com',
      'Cookie': 'session=abc',
      'Custom-Thing': '1',
    });
  });
}
