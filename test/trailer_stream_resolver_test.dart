import 'dart:convert';

import 'package:clubtivi/data/services/trailer_stream_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Respuesta mínima de `youtubei/v1/player` con un único flujo muxed.
String _playerResponse({String status = 'OK'}) => jsonEncode({
  'playabilityStatus': {'status': status},
  'streamingData': {
    'formats': [
      {
        'itag': 18,
        'mimeType': 'video/mp4; codecs="avc1.42001E, mp4a.40.2"',
        'qualityLabel': '360p',
        'height': 360,
        'url': 'https://v.test/trailer.mp4?expire=4102444800',
      },
    ],
  },
});

void main() {
  test('resuelve el flujo y lo reutiliza de la caché', () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response(_playerResponse(), 200);
    });
    final resolver = YouTubeTrailerResolver(client: client);

    final first = await resolver.resolve('abc123');
    final second = await resolver.resolve('abc123');

    expect(first.url, contains('v.test/trailer.mp4'));
    expect(first.qualityLabel, '360p');
    expect(identical(first, second), isTrue);
    expect(requests, 1, reason: 'la segunda vez debe salir de la caché');
    resolver.close();
  });

  test(
    'dos peticiones simultáneas comparten una sola resolución y terminan',
    () async {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return http.Response(_playerResponse(), 200);
      });
      final resolver = YouTubeTrailerResolver(client: client);

      final a = resolver.resolve('abc123');
      final b = resolver.resolve('abc123');
      expect(identical(a, b), isTrue);

      // Regresión: `whenComplete(() => _inFlight.remove(key))` devolvía el
      // propio future y esperaba a completarse a sí mismo, dejando la ficha
      // en «Preparando el vídeo…» para siempre.
      final streams = await Future.wait([
        a,
        b,
      ]).timeout(const Duration(seconds: 2));

      expect(requests, 1);
      expect(streams.every((stream) => stream.url.isNotEmpty), isTrue);

      // Tras completarse, el vuelo en curso se limpia y se puede reintentar.
      await resolver.resolve('abc123');
      expect(requests, 1);
      resolver.close();
    },
  );

  test('un vídeo restringido se cuenta en vez de quedarse en negro', () async {
    final client = MockClient(
      (_) async =>
          http.Response(_playerResponse(status: 'LOGIN_REQUIRED'), 200),
    );
    final resolver = YouTubeTrailerResolver(client: client);

    await expectLater(
      resolver.resolve('abc123'),
      throwsA(
        isA<TrailerUnavailable>().having(
          (e) => e.message,
          'message',
          contains('no permite ver este vídeo'),
        ),
      ),
    );
    resolver.close();
  });

  test('un error de red se explica con un mensaje para la pantalla', () async {
    final client = MockClient((_) async => http.Response('', 500));
    final resolver = YouTubeTrailerResolver(client: client);

    await expectLater(
      resolver.resolve('abc123'),
      throwsA(
        isA<TrailerUnavailable>().having(
          (e) => e.message,
          'message',
          contains('500'),
        ),
      ),
    );
    resolver.close();
  });
}
