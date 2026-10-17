/// Versión de rqbit que empaqueta y descarga la app.
///
/// El binario oficial se publica en Apache-2.0; la procedencia y la licencia
/// están documentadas en `docs/P2P_PLAYBACK.md`. El hash fija exactamente los
/// bytes que se aceptan: si cambia, la descarga se rechaza.
library;

import 'dart:io';

/// Versión publicada de rqbit.
const String rqbitVersion = '9.0.1';

/// SHA-256 de `rqbit.exe` de la release v9.0.1 (Windows x64, 12 706 816 bytes).
const String rqbitWindowsSha256 =
    '2ed683203beca628e0c45f62f99feeef4242cecc3444c8422dfe5b1b6aa38cea';

const String rqbitWindowsUrl =
    'https://github.com/ikatson/rqbit/releases/download/v9.0.1/rqbit.exe';

/// Nombre del ejecutable junto a la app.
String get rqbitExecutableName => Platform.isWindows ? 'rqbit.exe' : 'rqbit';

/// URL de descarga para esta plataforma.
///
/// De momento solo Windows tiene un asset verificado con hash. En macOS y
/// Linux se usa el binario que venga empaquetado junto a la app; inventar una
/// URL sin verificar rompería la garantía de integridad.
Uri? rqbitDownloadUri() =>
    Platform.isWindows ? Uri.parse(rqbitWindowsUrl) : null;

/// Hash esperado para la descarga de esta plataforma.
String? rqbitDownloadSha256() => Platform.isWindows ? rqbitWindowsSha256 : null;
