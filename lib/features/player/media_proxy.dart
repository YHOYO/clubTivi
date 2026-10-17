import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// Proxy HTTP loopback para fuentes que el origen no entrega sin cabeceras.
///
/// Un stream de addon puede exigir `Referer`/`User-Agent`, o venir marcado
/// `notWebReady`. mpv no acepta cabeceras por pista, así que se le sirve una
/// URL `http://127.0.0.1:<puerto>/p/<destino>/<nombre>` y este proxy reenvía al
/// origen con las cabeceras de la fuente.
///
/// Las listas HLS se reescriben para que claves (`#EXT-X-KEY`), init maps
/// (`#EXT-X-MAP`), sub-playlists y segmentos —relativos o absolutos— sigan
/// pasando por aquí y reciban las mismas cabeceras. `Range` se reenvía de
/// extremo a extremo: el estado (200/206, `Content-Range`, `Content-Length`)
/// lo decide el origen, no el proxy.
///
/// Es el único dueño de la URL local mientras está activo: `PlayerService` lo
/// para antes de abrir otra fuente, de detener la reproducción o de recurrir al
/// proxy de códec de `StreamProxy`.
class MediaProxy {
  /// Tope para buffear una lista HLS antes de reescribirla. Una playlist real
  /// no pasa de unos cientos de KB; por encima de esto el cuerpo se descarta.
  static const int _maxPlaylistBytes = 8 * 1024 * 1024;

  static const String _pathPrefix = '/p/';

  static final RegExp _uriAttribute = RegExp(r'URI="([^"]*)"');
  static final RegExp _lineBreak = RegExp(r'\r?\n');

  HttpServer? _server;
  HttpClient? _client;
  Map<String, String> _headers = const {};
  int? _port;

  /// Serializa `start`/`stop`: dos reproducciones seguidas no pueden quedar con
  /// el puerto de la anterior ni con dos servidores escuchando a la vez.
  Future<void> _lifecycle = Future<void>.value();

  /// Whether the proxy is currently running.
  bool get isRunning => _server != null;

  /// Puerto local, o `null` si el proxy no está escuchando.
  int? get port => _port;

  /// Arranca el proxy para [url] y devuelve la URL local que debe abrir mpv.
  /// Devuelve `null` si no se pudo escuchar en loopback.
  Future<String?> start(String url, {Map<String, String> headers = const {}}) {
    return _serialized(() => _start(url, headers));
  }

  /// Cierra el servidor, las conexiones abiertas y libera el puerto.
  Future<void> stop() => _serialized(_stop);

  Future<String?> _start(String url, Map<String, String> headers) async {
    await _stop();
    final target = Uri.tryParse(url);
    if (target == null ||
        (target.scheme != 'http' && target.scheme != 'https') ||
        target.host.isEmpty) {
      return null;
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..autoUncompress = true;
    HttpServer? server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    } catch (error) {
      debugPrint('[MediaProxy] No se pudo escuchar en loopback: $error');
      client.close(force: true);
      return null;
    }

    server.autoCompress = false;
    _server = server;
    _client = client;
    _headers = _normalizeHeaders(headers);
    _port = server.port;
    server.listen(
      (request) => _handle(request),
      onError: (Object error) =>
          debugPrint('[MediaProxy] Error de servidor: $error'),
    );
    return urlFor(target);
  }

  Future<void> _stop() async {
    final server = _server;
    _server = null;
    _port = null;
    _headers = const {};
    _client?.close(force: true);
    _client = null;
    if (server != null) {
      try {
        await server.close(force: true);
      } catch (_) {
        // El servidor ya estaba cerrado.
      }
    }
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _lifecycle = _lifecycle.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  /// URL local que representa [target] mientras este proxy esté activo.
  ///
  /// Conserva el nombre del último segmento (`seg1.ts`, `index.m3u8`) porque
  /// los clientes HLS —el demuxer de ffmpeg, por ejemplo— descartan URLs sin
  /// una extensión que reconozcan.
  String urlFor(Uri target) {
    final token = base64Url
        .encode(utf8.encode(target.toString()))
        .replaceAll('=', '');
    final name = _safeName(
      target.pathSegments.isEmpty ? '' : target.pathSegments.last,
    );
    return 'http://127.0.0.1:$_port$_pathPrefix$token${name.isEmpty ? '' : '/$name'}';
  }

  static String _safeName(String segment) {
    if (segment.isEmpty || segment.length > 120) return '';
    if (!segment.contains('.')) return '';
    final safe = segment.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return safe;
  }

  Future<void> _handle(HttpRequest request) async {
    final server = _server;
    final client = _client;
    if (server == null || client == null) {
      await _respondText(
        request,
        HttpStatus.serviceUnavailable,
        'proxy detenido',
      );
      return;
    }
    if (request.method != 'GET' && request.method != 'HEAD') {
      await _respondText(request, HttpStatus.methodNotAllowed, 'solo GET/HEAD');
      return;
    }

    final target = _targetOf(request.uri);
    if (target == null) {
      await _respondText(request, HttpStatus.notFound, 'ruta desconocida');
      return;
    }

    var started = false;
    try {
      final upstream = await client.openUrl(request.method, target);
      _headers.forEach(upstream.headers.set);
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null && range.isNotEmpty) {
        upstream.headers.set(HttpHeaders.rangeHeader, range);
      }
      // Las listas deben llegar en claro para poder reescribirlas.
      upstream.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');

      final response = await upstream.close();
      if (!identical(_server, server)) {
        // Otra reproducción sustituyó a esta mientras se abría el origen.
        await _discard(response);
        await _respondText(
          request,
          HttpStatus.serviceUnavailable,
          'proxy sustituido',
        );
        return;
      }

      final contentType = response.headers.value(HttpHeaders.contentTypeHeader);
      if (_looksLikePlaylist(target, contentType)) {
        final effectiveUri = response.redirects.isNotEmpty
            ? response.redirects.last.location
            : target;
        final bytes = await _readAll(response, _maxPlaylistBytes);
        if (!identical(_server, server)) {
          await _respondText(
            request,
            HttpStatus.serviceUnavailable,
            'proxy sustituido',
          );
          return;
        }
        final text = utf8.decode(bytes, allowMalformed: true);
        final isPlaylist =
            text.startsWith('\uFEFF#EXTM3U') || text.startsWith('#EXTM3U');
        if (isPlaylist) {
          final rewritten = utf8.encode(_rewritePlaylist(text, effectiveUri));
          request.response
            ..statusCode = response.statusCode
            ..headers.contentType = _playlistContentType(contentType)
            ..headers.contentLength = rewritten.length;
          started = true;
          if (request.method == 'GET') request.response.add(rewritten);
          await request.response.close();
          return;
        }
        // Se anunció como lista pero no lo es: se entrega tal cual llegó.
        request.response
          ..statusCode = response.statusCode
          ..headers.contentType = _parseContentType(
            contentType,
            ContentType.binary,
          )
          ..headers.contentLength = bytes.length;
        started = true;
        if (request.method == 'GET') request.response.add(bytes);
        await request.response.close();
        return;
      }

      request.response.statusCode = response.statusCode;
      _copyResponseHeaders(response, request.response);
      started = true;
      if (request.method == 'HEAD') {
        await _discard(response);
        await request.response.close();
        return;
      }
      await request.response.addStream(response);
      await request.response.close();
    } catch (error) {
      debugPrint(
        '[MediaProxy] Fallo reenviando ${target.host}${target.path}: $error',
      );
      if (!started) {
        await _respondText(
          request,
          HttpStatus.badGateway,
          'origen inalcanzable',
        );
      } else {
        try {
          await request.response.close();
        } catch (_) {}
      }
    }
  }

  /// Decodifica `/p/<base64url>[/<nombre>]` al destino real. `null` si no es
  /// válido; el nombre final es decorativo y se ignora al reenviar.
  Uri? _targetOf(Uri requestUri) {
    final path = requestUri.path;
    if (!path.startsWith(_pathPrefix)) return null;
    final rest = path.substring(_pathPrefix.length);
    final token = rest.split('/').first;
    if (token.isEmpty) return null;
    try {
      final target = utf8.decode(base64Url.decode(base64Url.normalize(token)));
      final uri = Uri.tryParse(target);
      if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
        return null;
      }
      if (uri.host.isEmpty) return null;
      return uri;
    } catch (_) {
      return null;
    }
  }

  /// Solo HLS: un `.m3u` suelto no es una lista de segmentos.
  bool _looksLikePlaylist(Uri target, String? contentType) {
    if (target.path.toLowerCase().endsWith('.m3u8')) return true;
    final type = contentType?.toLowerCase() ?? '';
    return type.contains('mpegurl');
  }

  ContentType _playlistContentType(String? originContentType) {
    return _parseContentType(
      originContentType,
      ContentType('application', 'vnd.apple.mpegurl'),
    );
  }

  ContentType _parseContentType(String? value, ContentType fallback) {
    if (value == null) return fallback;
    try {
      return ContentType.parse(value);
    } catch (_) {
      return fallback;
    }
  }

  void _copyResponseHeaders(HttpClientResponse response, HttpResponse out) {
    const forwarded = [
      HttpHeaders.contentTypeHeader,
      HttpHeaders.contentLengthHeader,
      HttpHeaders.contentRangeHeader,
      HttpHeaders.acceptRangesHeader,
      HttpHeaders.lastModifiedHeader,
      HttpHeaders.etagHeader,
    ];
    for (final name in forwarded) {
      final value = response.headers.value(name);
      if (value != null) out.headers.set(name, value);
    }
  }

  /// Reescribe URIs de la lista para que todas apunten al proxy.
  ///
  /// La base es la URL efectiva (tras redirecciones) de la lista, así que tanto
  /// `seg1.ts` como `/abs/seg2.ts` o una URL absoluta conservan su destino.
  /// Esquemas que no son HTTP (por ejemplo `skd://` de FairPlay) se dejan
  /// intactos: el proxy no sabría servirlos.
  String _rewritePlaylist(String body, Uri base) {
    var text = body;
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    final eol = text.contains('\r\n') ? '\r\n' : '\n';
    final out = <String>[];

    for (final line in text.split(_lineBreak)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        out.add('');
        continue;
      }
      if (trimmed.startsWith('#')) {
        out.add(
          trimmed.replaceAllMapped(_uriAttribute, (match) {
            final raw = match.group(1)!;
            final resolved = _resolve(base, raw);
            return 'URI="${resolved == null ? raw : urlFor(resolved)}"';
          }),
        );
        continue;
      }
      final resolved = _resolve(base, trimmed);
      out.add(resolved == null ? trimmed : urlFor(resolved));
    }
    return out.join(eol);
  }

  Uri? _resolve(Uri base, String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;
    final parsed = Uri.tryParse(value);
    if (parsed == null) return null;
    final resolved = base.resolveUri(parsed);
    if (resolved.scheme != 'http' && resolved.scheme != 'https') return null;
    return resolved;
  }

  Map<String, String> _normalizeHeaders(Map<String, String> headers) {
    final normalized = <String, String>{};
    for (final entry in headers.entries) {
      final key = entry.key.trim();
      final value = entry.value.trim();
      if (key.isEmpty || value.isEmpty) continue;
      normalized[key] = value;
    }
    return normalized;
  }

  Future<Uint8List> _readAll(Stream<List<int>> stream, int maxBytes) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
      if (builder.length > maxBytes) {
        throw const HttpException('lista HLS demasiado grande');
      }
    }
    return builder.takeBytes();
  }

  Future<void> _discard(Stream<List<int>> stream) async {
    try {
      await stream.drain<void>();
    } catch (_) {}
  }

  Future<void> _respondText(
    HttpRequest request,
    int status,
    String message,
  ) async {
    try {
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.text
        ..write(message);
      await request.response.close();
    } catch (_) {}
  }
}
