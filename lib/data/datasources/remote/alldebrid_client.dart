/// AllDebrid — https://docs.alldebrid.com/
///
/// Único dueño del flujo magnet → URL reproducible: subir el magnet, sondear
/// `/v4.1/magnet/status`, elegir el fichero de vídeo y desbloquear con
/// `/v4/link/unlock` (incluido el enlace diferido).
///
/// Contrato con el resto de la app, y sólo tres cosas que pueden cambiar aquí:
///
///  * **Progreso**: `onProgress(status, percent)` con `status` en minúsculas
///    («downloading», «ready», …) y `percent` real (0–100, calculado con
///    `downloaded/size`; 90 mientras comprime/sube). Nunca un valor fijo.
///  * **Fallo**: cualquier error del API, `statusCode` 5–15 o espera agotada se
///    lanza como [AllDebridException] con un mensaje ya listo para el usuario.
///  * **Éxito**: un `ResolvedStream` con `url` no vacía y `source: 'alldebrid'`.
///
/// La caché instantánea no se consulta: AllDebrid retiró `/magnet/instant`
/// (404) y la única pista fiable es `ready` en la respuesta de subida.
library;

import 'package:dio/dio.dart';

import '../../models/show.dart';
import 'debrid_service.dart';

/// Un fallo concreto de AllDebrid: se muestra su mensaje en vez de un
/// «timeout» genérico que no dice qué pasó.
class AllDebridException implements Exception {
  final String code;
  final String message;

  const AllDebridException(this.code, this.message);

  @override
  String toString() => message.isEmpty ? 'AllDebrid: $code' : message;
}

/// Un archivo ya listo dentro de un magnet (enlace AllDebrid sin desbloquear).
class _AllDebridFile {
  final String name;
  final int size;
  final String link;

  const _AllDebridFile({
    required this.name,
    required this.size,
    required this.link,
  });

  bool get isVideo {
    final lower = name.toLowerCase();
    return const [
      '.mkv',
      '.mp4',
      '.avi',
      '.webm',
      '.m4v',
      '.mov',
      '.ts',
    ].any(lower.endsWith);
  }
}

/// Foto de un magnet en un instante. Es el único sitio que decide, para el
/// contrato de este fichero, si el magnet ya está listo, qué progreso se
/// anuncia y qué mensaje tiene un fallo.
class _MagnetSnapshot {
  _MagnetSnapshot.fromJson(Map<String, dynamic> json)
    : code = (json['statusCode'] as num?)?.toInt() ?? 0,
      label = (json['status'] as String? ?? '').trim().toLowerCase(),
      progress = _percent(json),
      files = _filesOf(json),
      _error = json['error'];

  /// Antes del primer sondeo el magnet está en cola: mismo mensaje que antes
  /// de este refactor si se agota la espera sin respuesta.
  _MagnetSnapshot.inQueue()
    : code = 0,
      label = 'in queue',
      progress = 0,
      files = const [],
      _error = null;

  final int code;
  final String label;
  final int progress;
  final List<_AllDebridFile> files;
  final Object? _error;

  bool get isReady => code == 4;

  /// null mientras el magnet siga avanzando.
  AllDebridException? get failure {
    if (code < 5) return null;
    const messages = {
      5: 'AllDebrid no pudo subir el fichero',
      6: 'AllDebrid falló al descomprimir',
      7: 'AllDebrid no lo descargó en 20 minutos (sin peers)',
      8: 'El fichero es demasiado grande para AllDebrid',
      9: 'AllDebrid tuvo un error interno',
      10: 'AllDebrid tardó más de 72 h en descargarlo',
      11: 'El fichero se borró en el host original',
      12: 'AllDebrid no pudo procesar el release',
      13: 'AllDebrid no pudo procesar el release',
      14: 'AllDebrid no pudo contactar con el tracker',
      15: 'No hay peers para descargar el release',
    };
    final error = _error;
    final detail = error is Map ? '${error['message'] ?? ''}' : '';
    final message = messages[code] ?? 'AllDebrid falló procesando el release';
    return AllDebridException(
      'MAGNET_STATUS_$code',
      detail.isEmpty ? message : '$message ($detail)',
    );
  }

  /// Progreso real: `downloaded/size` mientras descarga y tramos altos para
  /// comprimir/subir. Un «50 %» fijo fue el síntoma original.
  static int _percent(Map<String, dynamic> json) {
    final code = (json['statusCode'] as num?)?.toInt() ?? 0;
    if (code == 4) return 100;
    if (code >= 2) return 90;
    final size = (json['size'] as num?)?.toDouble() ?? 0;
    final downloaded = (json['downloaded'] as num?)?.toDouble() ?? 0;
    if (size <= 0 || downloaded <= 0) return 0;
    return (downloaded / size * 100).clamp(0, 99).round();
  }

  /// Enlaces de un magnet listo, en el árbol `files` de `/v4.1` o en el array
  /// `links` de la respuesta antigua.
  static List<_AllDebridFile> _filesOf(Map<String, dynamic> magnet) {
    final files = <_AllDebridFile>[];

    void walk(Object? node) {
      if (node is List) {
        for (final child in node) {
          walk(child);
        }
        return;
      }
      if (node is! Map) return;
      final link = node['l'];
      if (link is String && link.isNotEmpty) {
        files.add(
          _AllDebridFile(
            name: '${node['n'] ?? ''}',
            size: (node['s'] as num?)?.toInt() ?? 0,
            link: link,
          ),
        );
      }
      walk(node['e']);
    }

    walk(magnet['files']);

    final links = magnet['links'];
    if (files.isEmpty && links is List) {
      for (final entry in links) {
        if (entry is Map && entry['link'] is String) {
          files.add(
            _AllDebridFile(
              name: '${entry['filename'] ?? entry['link']}',
              size: (entry['size'] as num?)?.toInt() ?? 0,
              link: entry['link'] as String,
            ),
          );
        } else if (entry is String) {
          files.add(_AllDebridFile(name: entry, size: 0, link: entry));
        }
      }
    }
    return files;
  }
}

/// AllDebrid API v4/v4.1.
///
/// El magnet se sube una vez y se consulta con `/v4.1/magnet/status`, que es la
/// versión vigente: `/v4/magnet/status` está obsoleto y hoy contesta con un
/// error sin datos, así que el bucle se quedaba girando con un 50 % inventado.
/// Cuando el magnet está listo los enlaces viven en `files[].l` (o en `links`
/// en la respuesta antigua) y cada uno se desbloquea con `/v4/link/unlock`.
class AllDebridService implements DebridService {
  final Dio _dio;
  final String apiToken;

  /// Cadencia del sondeo de estado. AllDebrid limita a 12 peticiones/segundo.
  final Duration pollInterval;

  /// Espera máxima preparando un magnet no cacheado antes de rendirse.
  final Duration resolveTimeout;

  static const _baseUrl = 'https://api.alldebrid.com';
  static const _agent = 'clubTivi';

  AllDebridService({
    required this.apiToken,
    Dio? dio,
    this.pollInterval = const Duration(seconds: 2),
    this.resolveTimeout = const Duration(minutes: 5),
  }) : _dio = dio ?? Dio() {
    _dio.options
      ..baseUrl = _baseUrl
      ..connectTimeout = const Duration(seconds: 10)
      ..receiveTimeout = const Duration(seconds: 30);
  }

  Map<String, String> get _params => {'agent': _agent, 'apikey': apiToken};

  @override
  String get serviceName => 'AllDebrid';

  /// Llamada al API con el sobre `{status, data, error}` que comparten todos
  /// los endpoints. Devuelve `data` o lanza [AllDebridException] con el código
  /// real (AUTH_BAD_APIKEY, MAGNET_MUST_BE_PREMIUM, …).
  Future<Map<String, dynamic>> _send(
    String path, {
    Map<String, dynamic>? query,
    Map<String, dynamic>? body,
  }) async {
    final Response<dynamic> response;
    try {
      response = body == null
          ? await _dio.get(path, queryParameters: {..._params, ...?query})
          : await _dio.post(
              path,
              queryParameters: {..._params, ...?query},
              data: FormData.fromMap(body),
            );
    } on DioException catch (e) {
      throw AllDebridException(
        'NETWORK',
        'AllDebrid no respondió (${e.type.name})',
      );
    }

    final payload = response.data;
    if (payload is! Map) {
      throw const AllDebridException(
        'BAD_RESPONSE',
        'AllDebrid devolvió una respuesta inesperada',
      );
    }
    if (payload['status'] != 'success') {
      final error = payload['error'];
      final code = error is Map ? '${error['code']}' : 'ERROR';
      final message = error is Map ? '${error['message']}' : '';
      throw AllDebridException(code, message);
    }
    final data = payload['data'];
    return data is Map<String, dynamic> ? data : <String, dynamic>{};
  }

  /// AllDebrid retiró `/magnet/instant` (contesta 404 «Endpoint doesn't
  /// exist»), así que ya no hay consulta de disponibilidad instantánea por
  /// hash: la única pista fiable es el campo `ready` de `/magnet/upload`, que
  /// sólo se conoce al resolver. No se suben 75 magnets por búsqueda, así que
  /// la lista se queda sin marcas ⚡ y el selector resuelve al pulsar.
  @override
  Future<Map<String, List<DebridFile>>> checkInstantAvailability(
    List<String> hashes,
  ) async {
    return {};
  }

  @override
  Future<ResolvedStream> unrestrictLink(String link) async {
    final data = await _send('/v4/link/unlock', body: {'link': link});
    var url = data['link'] as String? ?? '';
    final delayed = (data['delayed'] as num?)?.toInt();
    if (url.isEmpty && delayed != null) {
      // Algunos hosts devuelven un id y el enlace se genera después.
      url = await _awaitDelayedLink(delayed);
    }
    if (url.isEmpty) {
      throw const AllDebridException(
        'LINK_UNLOCK_FAILED',
        'AllDebrid no devolvió un enlace reproducible',
      );
    }
    return ResolvedStream(
      url: url,
      filename: data['filename'] as String? ?? 'unknown',
      filesize: (data['filesize'] as num?)?.toInt(),
      source: 'alldebrid',
    );
  }

  Future<String> _awaitDelayedLink(int id) async {
    final watch = Stopwatch()..start();
    while (watch.elapsed < resolveTimeout) {
      await Future.delayed(pollInterval);
      final data = await _send('/v4/link/delayed', body: {'id': '$id'});
      final status = (data['status'] as num?)?.toInt() ?? 1;
      final link = data['link'] as String? ?? '';
      if (status == 2 && link.isNotEmpty) return link;
      if (status == 3) {
        throw const AllDebridException(
          'DELAYED_FAILED',
          'AllDebrid no pudo generar el enlace de descarga',
        );
      }
    }
    throw const AllDebridException(
      'DELAYED_TIMEOUT',
      'AllDebrid tardó demasiado en generar el enlace',
    );
  }

  @override
  Future<ResolvedStream?> resolveFromMagnet(
    String magnetLink, {
    void Function(String status, int progress)? onProgress,
  }) async {
    final magnet = await _uploadMagnet(magnetLink);
    final magnetId = '${magnet['id']}';
    if (magnet['id'] == null) {
      throw const AllDebridException(
        'MAGNET_NO_ID',
        'AllDebrid no devolvió un magnet utilizable',
      );
    }

    final watch = Stopwatch()..start();
    var snapshot = _MagnetSnapshot.inQueue();
    while (watch.elapsed < resolveTimeout) {
      snapshot = _MagnetSnapshot.fromJson(await _magnetStatus(magnetId));
      final failure = snapshot.failure;
      if (failure != null) throw failure;
      if (snapshot.isReady) break;
      onProgress?.call(snapshot.label, snapshot.progress);
      await Future.delayed(pollInterval);
    }

    if (!snapshot.isReady) {
      throw AllDebridException(
        'MAGNET_TIMEOUT',
        'AllDebrid sigue preparando este release '
            '(${snapshot.label}'
            '${snapshot.progress > 0 ? ', ${snapshot.progress}%' : ''}). '
            'No estaba cacheado: AllDebrid lo sigue descargando en segundo '
            'plano, así que puedes reintentar en un rato o elegir otra fuente.',
      );
    }

    final files = snapshot.files;
    if (files.isEmpty) {
      throw const AllDebridException(
        'MAGNET_NO_FILES',
        'El magnet terminó sin ficheros reproducibles',
      );
    }
    return unrestrictLink(_pickPlayable(files).link);
  }

  /// Sube el magnet (o reutiliza el que ya exista) y devuelve su objeto, con
  /// el flag `ready` que dice si AllDebrid ya lo tenía cacheado.
  Future<Map<String, dynamic>> _uploadMagnet(String magnetLink) async {
    final data = await _send(
      '/v4/magnet/upload',
      query: {
        'magnets[]': [magnetLink],
      },
    );
    final magnets = data['magnets'];
    if (magnets is List && magnets.isNotEmpty && magnets.first is Map) {
      final magnet = Map<String, dynamic>.from(magnets.first as Map);
      final error = magnet['error'];
      if (error is Map) {
        throw AllDebridException(
          '${error['code']}',
          '${error['message'] ?? 'AllDebrid rechazó el magnet'}',
        );
      }
      return magnet;
    }
    throw const AllDebridException(
      'MAGNET_UPLOAD_FAILED',
      'AllDebrid no aceptó el magnet',
    );
  }

  /// `/v4.1/magnet/status` devuelve `magnets` como **array**, incluso cuando se
  /// pide un único id. Leerlo como objeto era el fallo que dejaba el progreso
  /// en un 50 % fijo y el magnet sin resolver.
  Future<Map<String, dynamic>> _magnetStatus(String magnetId) async {
    final data = await _send('/v4.1/magnet/status', body: {'id': magnetId});
    final magnets = data['magnets'];
    final list = magnets is List
        ? magnets
        : (magnets is Map ? [magnets] : const []);
    for (final entry in list) {
      if (entry is Map && '${entry['id']}' == magnetId) {
        return Map<String, dynamic>.from(entry);
      }
    }
    if (list.isNotEmpty && list.first is Map) {
      return Map<String, dynamic>.from(list.first as Map);
    }
    throw AllDebridException(
      'MAGNET_NOT_FOUND',
      'AllDebrid no encuentra el magnet $magnetId',
    );
  }

  /// El fichero de vídeo más grande: en un pack de temporada el primero del
  /// árbol puede ser un sample o un .nfo.
  _AllDebridFile _pickPlayable(List<_AllDebridFile> files) {
    final videos = files.where((f) => f.isVideo).toList();
    final candidates = videos.isEmpty ? files : videos;
    candidates.sort((a, b) => b.size.compareTo(a.size));
    return candidates.first;
  }

  @override
  Future<bool> verifyToken() async {
    try {
      await _send('/v4/user');
      return true;
    } catch (_) {
      return false;
    }
  }
}
