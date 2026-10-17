/// Localiza el binario de rqbit o lo descarga y verifica bajo demanda.
///
/// Orden: variable de entorno (desarrollo), junto al ejecutable de la app (lo
/// que empaqueta `tools/package_windows.ps1`), caché local ya verificada y, por
/// último, descarga de la release fijada en [rqbit_release.dart].
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'rqbit_release.dart';

/// Progreso de la descarga del motor, para la pantalla de espera.
class RqbitDownloadProgress {
  final int receivedBytes;
  final int? totalBytes;

  const RqbitDownloadProgress(this.receivedBytes, this.totalBytes);

  double? get fraction {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    return (receivedBytes / total).clamp(0.0, 1.0);
  }
}

/// De dónde salió el binario que se va a ejecutar.
enum RqbitBinarySource { override, bundled, cache, downloaded }

class RqbitBinaryLocation {
  final String path;
  final RqbitBinarySource source;

  const RqbitBinaryLocation(this.path, this.source);
}

/// Resuelve el ejecutable de rqbit para esta instalación.
class RqbitBinary {
  /// Carpeta base de la caché; dentro se aísla por versión.
  final Directory cacheDirectory;

  /// Carpeta del ejecutable de la app (`clubtivi.exe`).
  final String? executableDirectory;

  /// Permite probar la descarga contra un servidor local.
  final Uri? downloadUri;
  final String? expectedSha256;  final String fileName;

  /// Permite desactivar la descarga (macOS/Linux usan el binario empaquetado).
  final bool allowDownload;
  final http.Client _http;
  final Duration timeout;

  RqbitBinary({
    required this.cacheDirectory,
    this.executableDirectory,
    this.fileName = 'rqbit.exe',
    Uri? downloadUri,
    String? expectedSha256,
    bool? allowDownload,
    http.Client? client,
    this.timeout = const Duration(minutes: 5),
  })  : allowDownload = allowDownload ?? true,
        downloadUri = downloadUri ?? rqbitDownloadUri(),
       expectedSha256 = expectedSha256 ?? rqbitDownloadSha256(),
       _http = client ?? http.Client();

  /// Ruta del ejecutable si ya está en disco, sin descargar nada.
  Future<RqbitBinaryLocation?> locate() async {
    final override = Platform.environment['CLUBTIVI_RQBIT_BINARY']?.trim();
    if (override != null &&
        override.isNotEmpty &&
        await File(override).exists()) {
      return RqbitBinaryLocation(override, RqbitBinarySource.override);
    }

    final bundledDir = executableDirectory;
    if (bundledDir != null) {
      final bundled = File('$bundledDir${Platform.pathSeparator}$fileName');
      if (await bundled.exists()) {
        return RqbitBinaryLocation(bundled.path, RqbitBinarySource.bundled);
      }
    }

    final cached = File(_cachedPath);
    if (await cached.exists()) {
      if (await _matchesChecksum(cached.path, expectedSha256)) {
        return RqbitBinaryLocation(cached.path, RqbitBinarySource.cache);
      }
      // Una caché corrupta se descarta: se volverá a descargar.
      try {
        await cached.delete();
      } catch (_) {
        // Sin permisos para borrar, la descarga fallará con un error claro.
      }
    }
    return null;
  }

  /// Devuelve la ruta ejecutable, descargándola si hace falta.
  Future<RqbitBinaryLocation> ensureAvailable({
    void Function(RqbitDownloadProgress progress)? onProgress,
  }) async {
    final existing = await locate();
    if (existing != null) return existing;

    final uri = downloadUri;
    final expected = expectedSha256;
    if (!allowDownload || uri == null || expected == null) {
      throw RqbitBinaryMissingException(
        'The P2P engine is not included in this build. '
        'Place $fileName next to the app to enable P2P playback.',
      );
    }

    final target = File(_cachedPath);
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.download');

    try {
      await _download(uri, temporary, onProgress);
      final actual = await _sha256Of(temporary.path);
      if (actual != expected.toLowerCase()) {
        await _deleteQuietly(temporary);
        throw RqbitBinaryChecksumException(
          'The downloaded P2P engine did not match the expected checksum',
        );
      }
      if (await target.exists()) await target.delete();
      await temporary.rename(target.path);
      if (!Platform.isWindows) {
        await Process.run('chmod', ['+x', target.path]);
      }
      return RqbitBinaryLocation(target.path, RqbitBinarySource.downloaded);
    } on RqbitBinaryMissingException {
      await _deleteQuietly(temporary);
      rethrow;
    } on RqbitBinaryChecksumException {
      await _deleteQuietly(temporary);
      rethrow;
    } on RqbitBinaryDownloadException {
      await _deleteQuietly(temporary);
      rethrow;
    } catch (error) {
      await _deleteQuietly(temporary);
      throw RqbitBinaryDownloadException(
        'Could not download the P2P engine: $error',
      );
    }
  }

  String get _cachedPath {
    final separator = Platform.pathSeparator;
    return '${cacheDirectory.path}${separator}rqbit-$rqbitVersion'
        '$separator$fileName';
  }

  Future<void> _download(
    Uri uri,
    File target,
    void Function(RqbitDownloadProgress)? onProgress,
  ) async {
    final request = http.Request('GET', uri);
    final streamed = await _http.send(request).timeout(timeout);
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw RqbitBinaryDownloadException(
        'The P2P engine download failed (HTTP ${streamed.statusCode})',
      );
    }
    final total = streamed.contentLength;
    final sink = target.openWrite();
    var received = 0;
    var lastNotified = 0;
    try {
      await for (final chunk in streamed.stream.timeout(timeout)) {
        sink.add(chunk);
        received += chunk.length;
        if (onProgress != null &&
            (received - lastNotified >= 256 * 1024 ||
                (total != null && received >= total))) {
          lastNotified = received;
          onProgress(RqbitDownloadProgress(received, total));
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    onProgress?.call(RqbitDownloadProgress(received, total ?? received));
  }

  Future<bool> _matchesChecksum(String path, String? expected) async {
    if (expected == null || expected.isEmpty) return true;
    try {
      return (await _sha256Of(path)) == expected.toLowerCase();
    } catch (_) {
      return false;
    }
  }

  Future<String> _sha256Of(String path) async {
    final digest = sha256.convert(await File(path).readAsBytes());
    return digest.toString();
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Un temporal que no se puede borrar no debe ocultar el error real.
    }
  }
}

/// No hay binario y esta plataforma no tiene descarga verificada.
class RqbitBinaryMissingException implements Exception {
  final String message;
  const RqbitBinaryMissingException(this.message);

  @override
  String toString() => message;
}

class RqbitBinaryDownloadException implements Exception {
  final String message;
  const RqbitBinaryDownloadException(this.message);

  @override
  String toString() => message;
}

class RqbitBinaryChecksumException implements Exception {
  final String message;
  const RqbitBinaryChecksumException(this.message);

  @override
  String toString() => message;
}
