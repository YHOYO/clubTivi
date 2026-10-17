/// Cliente HTTP de la API local de rqbit.
///
/// Solo cubre lo que la app usa: añadir un magnet, consultar detalles y
/// estadísticas, comprobar que el servidor responde y construir la URL de
/// streaming. El rango HTTP (`Range`) lo interpreta rqbit; el reproductor envía
/// la cabecera directamente contra [RqbitClient.streamUrl].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'rqbit_models.dart';

/// Contrato que usa el motor P2P, para poder probarlo sin red.
abstract class RqbitApi {
  Future<void> ping();

  Future<RqbitAddResult> addTorrent(
    String magnet, {
    String? outputFolder,
    List<int>? onlyFiles,
  });

  Future<RqbitTorrentDetails> torrent(String idOrHash);

  Future<RqbitTorrentStats> stats(String idOrHash);

  Uri streamUrl(String idOrHash, int fileIndex);
}

/// Cliente real contra `http://127.0.0.1:<puerto>`.
class RqbitClient implements RqbitApi {
  final Uri baseUri;
  final http.Client _http;
  final Duration _timeout;

  RqbitClient({
    required this.baseUri,
    http.Client? client,
    Duration timeout = const Duration(seconds: 10),
  }) : _http = client ?? http.Client(),
       _timeout = timeout;

  @override
  Future<void> ping() async {
    final response = await _send(
      () => _http.get(
        _endpoint('/'),
        headers: const {'accept': 'application/json'},
      ),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RqbitHttpException.fromResponse(response);
    }
  }

  @override
  Future<RqbitAddResult> addTorrent(
    String magnet, {
    String? outputFolder,
    List<int>? onlyFiles,
  }) async {
    final query = <String, String>{
      if (outputFolder != null && outputFolder.isNotEmpty)
        'output_folder': outputFolder,
      if (onlyFiles != null && onlyFiles.isNotEmpty)
        'only_files': onlyFiles.join(','),
    };
    final uri = _endpoint('/torrents', query: query);
    final response = await _send(
      () => _http.post(
        uri,
        // rqbit lee el cuerpo como texto: un magnet o una URL.
        headers: const {'content-type': 'text/plain; charset=utf-8'},
        body: magnet,
      ),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RqbitHttpException.fromResponse(response);
    }
    return RqbitAddResult.fromJson(_decode(response.body));
  }

  @override
  Future<RqbitTorrentDetails> torrent(String idOrHash) async {
    final response = await _get('/torrents/${Uri.encodeComponent(idOrHash)}');
    return RqbitTorrentDetails.fromJson(_decode(response.body));
  }

  @override
  Future<RqbitTorrentStats> stats(String idOrHash) async {
    final response = await _get(
      '/torrents/${Uri.encodeComponent(idOrHash)}/stats/v1',
    );
    return RqbitTorrentStats.fromJson(_decode(response.body));
  }

  @override
  Uri streamUrl(String idOrHash, int fileIndex) =>
      _endpoint('/torrents/${Uri.encodeComponent(idOrHash)}/stream/$fileIndex');

  Future<http.Response> _get(String path) async {
    final response = await _send(() => _http.get(_endpoint(path)));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RqbitHttpException.fromResponse(response);
    }
    return response;
  }

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request().timeout(_timeout);
    } on TimeoutException {
      throw RqbitTimeoutException();
    } on SocketException catch (error) {
      throw RqbitConnectionException(error.message);
    } on http.ClientException catch (error) {
      throw RqbitConnectionException(error.message);
    }
  }

  Uri _endpoint(String path, {Map<String, String>? query}) {
    return baseUri.replace(
      path: '${baseUri.path.replaceAll(RegExp(r'/+$'), '')}$path',
      queryParameters: query == null || query.isEmpty ? null : query,
    );
  }
}

Object? _decode(String body) {
  if (body.isEmpty) return const <String, dynamic>{};
  try {
    return jsonDecode(body);
  } on FormatException {
    throw RqbitProtocolException('rqbit devolvió una respuesta inesperada');
  }
}

/// Base de los fallos del motor P2P. [message] es visible para el usuario.
class RqbitException implements Exception {
  final String message;
  const RqbitException(this.message);

  @override
  String toString() => message;
}

/// El proceso no acepta conexiones (caído, arrancando o matado).
class RqbitConnectionException extends RqbitException {
  const RqbitConnectionException(String detail)
    : super('The P2P engine is not responding: $detail');
}

class RqbitTimeoutException extends RqbitException {
  const RqbitTimeoutException()
    : super('The P2P engine did not answer in time');
}

class RqbitProtocolException extends RqbitException {
  const RqbitProtocolException(super.message);
}

/// Error HTTP con el código y el mensaje humano que manda rqbit.
class RqbitHttpException extends RqbitException {
  final int statusCode;
  final String? errorKind;

  const RqbitHttpException(
    super.message, {
    required this.statusCode,
    this.errorKind,
  });

  factory RqbitHttpException.fromResponse(http.Response response) {
    String? kind;
    String message = 'rqbit responded ${response.statusCode}';
    try {
      final json = jsonDecode(response.body);
      if (json is Map) {
        if (json['human_readable'] is String &&
            (json['human_readable'] as String).isNotEmpty) {
          message = json['human_readable'] as String;
        } else if (json['error'] is String) {
          message = json['error'] as String;
        }
        if (json['error_kind'] is String) kind = json['error_kind'] as String;
      }
    } on FormatException {
      // Sin JSON, el mensaje genérico con el código sigue siendo útil.
    }
    return RqbitHttpException(
      message,
      statusCode: response.statusCode,
      errorKind: kind,
    );
  }

  bool get isNotFound => statusCode == 404;
}
