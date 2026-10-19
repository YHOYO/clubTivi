import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

/// Un vídeo de YouTube ya resuelto y listo para el reproductor de la app.
@immutable
class TrailerStream {
  const TrailerStream({
    required this.url,
    required this.qualityLabel,
    required this.expiresAt,
  });

  final String url;
  final String qualityLabel;

  /// Las URLs de `googlevideo` caducan; antes de eso hay que volver a resolver.
  final DateTime expiresAt;

  /// Margen para no abrir una URL que caduque mientras se ve el vídeo.
  bool get isExpired =>
      DateTime.now().isAfter(expiresAt.subtract(const Duration(minutes: 5)));
}

/// Un flujo con vídeo y audio en la misma URL: es la única forma que el
/// reproductor puede abrir de una pieza sin mezclar pistas por su cuenta.
@immutable
class MuxedCandidate {
  const MuxedCandidate({
    required this.height,
    required this.qualityLabel,
    required this.container,
    required this.url,
  });

  /// Alto en píxeles: es la medida de calidad que publica YouTube.
  final int height;
  final String qualityLabel;
  final String container;
  final String url;
}

/// Elige el mejor flujo muxed: MP4 antes que cualquier otro contenedor y,
/// dentro del contenedor, la calidad más alta. Null si no hay ninguno.
///
/// Es una decisión de la app, no del catálogo, así que vive aquí y se prueba
/// sin tocar la red.
MuxedCandidate? pickBestMuxed(Iterable<MuxedCandidate> candidates) {
  MuxedCandidate? best;
  for (final candidate in candidates) {
    if (candidate.url.isEmpty) continue;
    if (best == null) {
      best = candidate;
      continue;
    }
    final candidateIsMp4 = _isMp4(candidate);
    final bestIsMp4 = _isMp4(best);
    if (candidateIsMp4 != bestIsMp4) {
      if (candidateIsMp4) best = candidate;
      continue;
    }
    if (candidate.height > best.height) best = candidate;
  }
  return best;
}

bool _isMp4(MuxedCandidate candidate) =>
    candidate.container.toLowerCase() == 'mp4';

/// Traduce la respuesta de `youtubei/v1/player` a los flujos que la app puede
/// abrir: sólo los que traen vídeo y audio juntos y una URL directa.
///
/// Una respuesta sin `streamingData` (vídeo privado, restringido o con
/// `signatureCipher`) devuelve una lista vacía: la pantalla lo explicará y
/// ofrecerá YouTube en el navegador.
List<MuxedCandidate> muxedCandidatesFromPlayerResponse(
  Map<String, dynamic> player,
) {
  final streaming = player['streamingData'];
  if (streaming is! Map) return const [];

  final candidates = <MuxedCandidate>[];
  for (final raw in [
    ...?(streaming['formats'] as List?),
    ...?(streaming['adaptiveFormats'] as List?),
  ]) {
    if (raw is! Map) continue;
    if (raw['signatureCipher'] != null) continue;

    final mime = raw['mimeType'] as String? ?? '';
    if (!mime.startsWith('video/')) continue;
    // Sin pista de audio no sirve: media_kit abriría una imagen muda.
    if (!mime.contains('mp4a') && !mime.contains('opus')) continue;

    final url = raw['url'] as String?;
    if (url == null || url.isEmpty) continue;

    final height =
        raw['height'] as int? ?? _heightFromLabel(raw['qualityLabel']);
    candidates.add(
      MuxedCandidate(
        height: height,
        qualityLabel: raw['qualityLabel'] as String? ?? '${height}p',
        container: mime.startsWith('video/mp4') ? 'mp4' : 'webm',
        url: url,
      ),
    );
  }
  return candidates;
}

int _heightFromLabel(Object? label) {
  final match = RegExp(r'(\d+)p').firstMatch('$label');
  return int.tryParse(match?.group(1) ?? '') ?? 0;
}

/// No se pudo preparar el vídeo para verlo dentro de la app. [message] está
/// pensado para enseñarse tal cual.
class TrailerUnavailable implements Exception {
  const TrailerUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Convierte la clave de un vídeo de YouTube en algo que el reproductor pueda
/// abrir. Se abstrae para que la interfaz pueda probarse sin red.
abstract class TrailerStreamResolver {
  Future<TrailerStream> resolve(String videoKey);
}

/// Resolutor real: pregunta a la API de reproducción de YouTube por los flujos
/// del vídeo y se queda con el mejor muxed, guardando el resultado mientras la
/// URL siga siendo válida.
class YouTubeTrailerResolver implements TrailerStreamResolver {
  YouTubeTrailerResolver({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  final Map<String, TrailerStream> _cache = {};
  final Map<String, Future<TrailerStream>> _inFlight = {};

  static final _endpoint = Uri.parse(
    'https://www.youtube.com/youtubei/v1/player?prettyPrint=false',
  );

  /// Tope de espera para no dejar la pantalla en «Preparando…» si YouTube no
  /// contesta.
  static const _timeout = Duration(seconds: 20);

  /// Cliente ANDROID: es el que devuelve URLs reproducibles sin descifrado de
  /// firma, que es justo lo que necesita el reproductor.
  static const _userAgent =
      'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip';
  static const _headers = {
    'Content-Type': 'application/json',
    'User-Agent': _userAgent,
    'X-Youtube-Client-Name': '3',
    'X-Youtube-Client-Version': '20.10.38',
    'Origin': 'https://www.youtube.com',
  };

  @override
  Future<TrailerStream> resolve(String videoKey) {
    final key = videoKey.trim();
    if (key.isEmpty) {
      throw const TrailerUnavailable('Este vídeo no tiene identificador.');
    }
    final cached = _cache[key];
    if (cached != null && !cached.isExpired) return Future.value(cached);
    final pending = _inFlight[key];
    if (pending != null) return pending;

    late final Future<TrailerStream> future;
    future = _resolveFresh(key).whenComplete(() {
      // `Map.remove` devuelve el propio future: si se devolviese desde
      // `whenComplete`, este esperaría a completarse a sí mismo y la ficha se
      // quedaría en «Preparando…» para siempre.
      if (identical(_inFlight[key], future)) _inFlight.remove(key);
    });
    _inFlight[key] = future;
    return future;
  }

  Future<TrailerStream> _resolveFresh(String key) async {
    try {
      final response = await _client
          .post(
            _endpoint,
            headers: _headers,
            body: jsonEncode({
              'context': {
                'client': {
                  'clientName': 'ANDROID',
                  'clientVersion': '20.10.38',
                  'userAgent': _userAgent,
                  'hl': 'es',
                  'timeZone': 'UTC',
                  'utcOffsetMinutes': 0,
                  'osName': 'Android',
                  'osVersion': '11',
                },
              },
              'videoId': key,
              'playbackContext': {
                'contentPlaybackContext': {
                  'html5Preference': 'HTML5_PREF_WANTS',
                },
              },
            }),
          )
          .timeout(_timeout);

      if (response.statusCode != 200) {
        throw TrailerUnavailable(
          'YouTube respondió ${response.statusCode} al preparar el vídeo.',
        );
      }

      final player =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final status = (player['playabilityStatus'] as Map?)?['status'];
      if (status is String && status != 'OK') {
        throw const TrailerUnavailable(
          'YouTube no permite ver este vídeo fuera de su web.',
        );
      }

      final best = pickBestMuxed(muxedCandidatesFromPlayerResponse(player));
      if (best == null) {
        throw const TrailerUnavailable(
          'YouTube no ofrece este vídeo en un formato que la app pueda '
          'reproducir.',
        );
      }

      final stream = TrailerStream(
        url: best.url,
        qualityLabel: best.qualityLabel,
        expiresAt: _expiryOf(best.url),
      );
      _cache[key] = stream;
      return stream;
    } on TrailerUnavailable {
      rethrow;
    } catch (e) {
      debugPrint('[Trailer] No se pudo resolver $key: $e');
      throw const TrailerUnavailable(
        'No se pudo preparar el vídeo para verlo dentro de la app.',
      );
    }
  }

  /// `expire` es el parámetro que pone `googlevideo` en la URL. Sin él se
  /// asume una hora, que es lo habitual en estos enlaces.
  static DateTime _expiryOf(String url) {
    final expire = Uri.tryParse(url)?.queryParameters['expire'];
    final seconds = int.tryParse(expire ?? '');
    if (seconds == null) return DateTime.now().add(const Duration(hours: 1));
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  }

  void close() {
    _cache.clear();
    if (_ownsClient) _client.close();
  }
}

final trailerStreamResolverProvider = Provider<TrailerStreamResolver>((ref) {
  final resolver = YouTubeTrailerResolver();
  ref.onDispose(resolver.close);
  return resolver;
});
