import 'package:dio/dio.dart';

import '../../models/stremio_addon.dart';
import '../../models/stream_source.dart';
import '../../services/stremio_stream_mapper.dart';

/// Cliente del protocolo de addons de Stremio.
///
/// Solo implementa lo que la app consume: leer y validar `manifest.json` y
/// pedir `/stream/{type}/{id}.json`. Cualquier fallo se traduce a
/// [StremioAddonException] con un motivo legible, para que un addon caído o
/// lento quede fuera de la lista con explicación en vez de tumbar la búsqueda.
class StremioAddonClient {
  final Dio _dio;

  StremioAddonClient({Dio? dio}) : _dio = dio ?? Dio() {
    _dio.options
      ..connectTimeout = const Duration(seconds: 8)
      ..receiveTimeout = const Duration(seconds: 12);
  }

  /// Descarga y valida el manifest. Lanza [StremioAddonException] cuando la URL
  /// no es un addon, el manifest no es válido o el addon no responde.
  Future<StremioManifest> fetchManifest(String addonUrl) async {
    final normalized = tryNormalizeAddonUrl(addonUrl);
    if (normalized == null) {
      throw StremioAddonException(
        'Esa URL no parece válida. Pega la del addon, por ejemplo '
        'https://torrentio.strem.fun',
      );
    }

    final uri = Uri.parse('$normalized/manifest.json');
    try {
      final response = await _dio.getUri<Object?>(uri);
      return StremioManifest.fromJson(response.data);
    } on StremioAddonException {
      rethrow;
    } on DioException catch (e) {
      throw StremioAddonException(_describe(e), url: uri);
    } catch (e) {
      throw StremioAddonException(
        'El addon respondió algo que no se pudo leer',
        url: uri,
      );
    }
  }

  /// Streams de un addon concreto, ya traducidos a [StreamSource].
  ///
  /// `streams: null` o una lista con entradas basura devuelven lo que se pueda
  /// leer (posiblemente nada) en vez de fallar.
  Future<List<StreamSource>> fetchStreams({
    required InstalledAddon addon,
    required String type,
    required String id,
  }) async {
    final uri = Uri.parse('${addon.url}/stream/$type/$id.json');
    final Object? data;
    try {
      final response = await _dio.getUri<Object?>(uri);
      data = response.data;
    } on DioException catch (e) {
      throw StremioAddonException(_describe(e), url: uri);
    } catch (e) {
      throw StremioAddonException(
        'El addon respondió algo que no se pudo leer',
        url: uri,
      );
    }

    if (data is! Map) {
      throw StremioAddonException(
        'El addon devolvió algo que no es JSON de streams.',
        url: uri,
      );
    }

    final streams = data['streams'];
    if (streams == null) return const [];
    if (streams is! List) {
      throw StremioAddonException(
        'El addon devolvió "streams" con una forma inesperada.',
        url: uri,
      );
    }

    final sources = <StreamSource>[];
    for (var index = 0; index < streams.length; index++) {
      final entry = streams[index];
      if (entry is! Map) continue;
      final source = stremioStreamToSource(
        Map<String, dynamic>.from(entry),
        providerId: addon.manifestId,
        providerName: addon.name,
        index: index,
      );
      if (source != null) sources.add(source);
    }
    return sources;
  }

  String _describe(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 'El addon tardó demasiado en responder';
      case DioExceptionType.badResponse:
        return 'El addon respondió HTTP ${error.response?.statusCode ?? '?'}';
      case DioExceptionType.connectionError:
        return 'No se pudo conectar con el addon';
      case DioExceptionType.cancel:
        return 'Consulta cancelada';
      case DioExceptionType.badCertificate:
        return 'El certificado del addon no es válido';
      case DioExceptionType.unknown:
        // Un cuerpo ilegible no debe ocultar el código HTTP cuando lo hubo.
        final status = error.response?.statusCode;
        return status == null
            ? 'El addon respondió algo que no se pudo leer'
            : 'El addon respondió HTTP $status';
    }
  }
}
