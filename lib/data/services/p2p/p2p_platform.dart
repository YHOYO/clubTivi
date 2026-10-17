/// Reglas de plataforma y traducción de errores del motor P2P a texto visible.
library;

import 'dart:io';

import 'rqbit_binary.dart';
import 'rqbit_client.dart';
import 'rqbit_engine.dart';
import 'rqbit_supervisor.dart';

/// El motor es un proceso de escritorio: Android/iOS no pueden ejecutarlo.
const String kP2pUnavailableReason =
    'P2P playback needs the desktop app (Windows, macOS or Linux)';

/// Compatibilidad del motor por plataforma, inyectable en tests.
bool isP2pPlaybackSupported({bool? isDesktop}) {
  if (isDesktop != null) return isDesktop;
  return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
}

/// Mensaje de una línea, accionable, para el diálogo de error.
String p2pErrorMessage(Object error) {
  if (error is P2pCancelledException) {
    return 'P2P playback was cancelled';
  }
  if (error is RqbitBinaryMissingException) {
    return '${error.message} Reinstall the app or pick another source.';
  }
  if (error is RqbitBinaryChecksumException) {
    return 'The P2P engine download was corrupted. Check your connection and '
        'try again.';
  }
  if (error is RqbitBinaryDownloadException) {
    return '${error.message}. Check your connection and try again.';
  }
  if (error is RqbitPortException) {
    return '${error.message}. Close other torrent apps and try again.';
  }
  if (error is RqbitStartException) {
    return 'The P2P engine could not start. ${error.message}';
  }
  if (error is RqbitMetadataTimeoutException) {
    return error.message;
  }
  if (error is RqbitTorrentErrorException) {
    return 'The P2P engine could not use this torrent: ${error.message}';
  }
  if (error is RqbitTorrentNotReadyException) {
    return error.message;
  }
  if (error is RqbitConnectionException) {
    return '${error.message}. Try again in a moment.';
  }
  if (error is RqbitTimeoutException) {
    return '${error.message}. Try again in a moment.';
  }
  if (error is RqbitHttpException) {
    return 'The P2P engine rejected the request: ${error.message}';
  }
  if (error is RqbitException) {
    return error.message;
  }
  return 'P2P playback failed: $error';
}
