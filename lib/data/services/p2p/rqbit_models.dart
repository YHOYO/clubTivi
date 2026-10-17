/// Tipos de la API HTTP de rqbit y las decisiones puras del motor P2P.
///
/// Vive fuera del cliente y del supervisor para poder probar el parseo, el
/// magnet y la elección de archivo sin red y sin procesos. Los nombres de los
/// campos replican la API real de rqbit (`/torrents`,
/// `/torrents/{id}/stats/v1`), que no devuelve un índice dentro de cada archivo:
/// el índice es la posición en `files`.
library;

/// Archivo de un torrent, tal y como lo devuelve rqbit.
class RqbitTorrentFile {
  final String name;
  final int length;
  final bool included;

  const RqbitTorrentFile({
    required this.name,
    required this.length,
    this.included = true,
  });

  factory RqbitTorrentFile.fromJson(Object? json) {
    final map = _asMap(json);
    return RqbitTorrentFile(
      name: _string(map['name']) ?? '',
      length: _int(map['length']) ?? 0,
      included: map['included'] != false,
    );
  }

  @override
  String toString() => 'RqbitTorrentFile($name, $length, included=$included)';
}

/// Detalles de un torrent: metadatos, nombre y archivos.
class RqbitTorrentDetails {
  final int? id;
  final String infoHash;
  final String name;
  final String? outputFolder;
  final List<RqbitTorrentFile> files;

  /// Presente solo cuando se pide la lista con `with_stats=true`.
  final RqbitTorrentStats? stats;

  const RqbitTorrentDetails({
    required this.id,
    required this.infoHash,
    required this.name,
    required this.files,
    this.outputFolder,
    this.stats,
  });

  /// rqbit publica `files` vacío mientras no ha descargado los metadatos.
  bool get hasMetadata => files.isNotEmpty;

  /// Tamaño total del torrent, si las estadísticas lo conocen.
  int get totalBytes => stats?.totalBytes ?? 0;

  factory RqbitTorrentDetails.fromJson(Object? json) {
    final map = _asMap(json);
    final filesJson = map['files'];
    final files = filesJson is List
        ? [for (final entry in filesJson) RqbitTorrentFile.fromJson(entry)]
        : const <RqbitTorrentFile>[];
    final statsJson = map['stats'];
    return RqbitTorrentDetails(
      id: _int(map['id']),
      infoHash: _string(map['info_hash']) ?? '',
      name: _string(map['name']) ?? '',
      outputFolder: _string(map['output_folder']),
      files: files,
      stats: statsJson is Map ? RqbitTorrentStats.fromJson(statsJson) : null,
    );
  }

  /// `GET /torrents` devuelve `{"torrents": [ ... ]}`; una lista suelta
  /// también se acepta por si la forma cambia entre versiones.
  static List<RqbitTorrentDetails> listFromJson(Object? json) {
    final entries = json is List ? json : _asMap(json)['torrents'];
    if (entries is! List) return const [];
    return [
      for (final entry in entries)
        if (entry is Map) RqbitTorrentDetails.fromJson(entry),
    ];
  }

  @override
  String toString() =>
      'RqbitTorrentDetails(id: $id, $name, ${files.length} files)';
}

/// Estadísticas v1: estado, progreso y error del torrent.
class RqbitTorrentStats {
  final String state;
  final String? error;
  final int progressBytes;
  final int totalBytes;
  final bool finished;

  const RqbitTorrentStats({
    required this.state,
    this.error,
    this.progressBytes = 0,
    this.totalBytes = 0,
    this.finished = false,
  });

  /// Progreso entre 0 y 1, o null mientras no haya tamaño conocido.
  double? get progress {
    if (totalBytes <= 0) return null;
    return (progressBytes / totalBytes).clamp(0.0, 1.0);
  }

  factory RqbitTorrentStats.fromJson(Object? json) {
    final map = _asMap(json);
    return RqbitTorrentStats(
      state: _string(map['state']) ?? 'unknown',
      error: _string(map['error']),
      progressBytes: _int(map['progress_bytes']) ?? 0,
      totalBytes: _int(map['total_bytes']) ?? 0,
      finished: map['finished'] == true,
    );
  }

  @override
  String toString() => 'RqbitTorrentStats($state, $progressBytes/$totalBytes)';
}

/// Respuesta de `POST /torrents`: el id (0 es válido) y, si rqbit ya tiene
/// metadatos, los detalles con los archivos.
class RqbitAddResult {
  final int? id;
  final RqbitTorrentDetails? details;

  const RqbitAddResult({required this.id, this.details});

  factory RqbitAddResult.fromJson(Object? json) {
    final map = _asMap(json);
    final detailsJson = map['details'];
    return RqbitAddResult(
      id: _int(map['id']),
      details: detailsJson is Map
          ? RqbitTorrentDetails.fromJson(detailsJson)
          : null,
    );
  }

  @override
  String toString() => 'RqbitAddResult(id: $id, details: $details)';
}

/// Petición de reproducción P2P: lo que un addon ya sabe (hash, magnet con sus
/// trackers y el archivo elegido) más el título para el nombre del magnet.
class P2pStreamRequest {
  final String infoHash;
  final String? magnetUrl;
  final int? fileIndex;
  final String? title;

  const P2pStreamRequest({
    required this.infoHash,
    this.magnetUrl,
    this.fileIndex,
    this.title,
  });

  /// Un magnet existente se respeta tal cual (con sus `tr=`); si falta, se
  /// construye con el hash y el título.
  String get magnet {
    final existing = magnetUrl?.trim();
    if (existing != null &&
        existing.startsWith('magnet:') &&
        existing.toLowerCase().contains(_normalizedHash)) {
      return existing;
    }
    return buildP2pMagnet(infoHash: infoHash, name: title);
  }

  String get _normalizedHash => infoHash.trim().toLowerCase();

  @override
  String toString() =>
      'P2pStreamRequest($infoHash, file: $fileIndex, magnet: $magnetUrl)';
}

/// Construye un magnet mínimo y válido cuando el addon solo dio el hash.
String buildP2pMagnet({required String infoHash, String? name}) {
  final buffer = StringBuffer('magnet:?xt=urn:btih:${infoHash.trim()}');
  final title = name?.trim();
  if (title != null && title.isNotEmpty) {
    buffer.write('&dn=${Uri.encodeComponent(title)}');
  }
  return buffer.toString();
}

/// Índice del archivo que hay que servir.
///
/// `fileIdx` del addon manda si existe y está incluido; si no, se elige el
/// vídeo incluido más grande (y, en su defecto, el archivo incluido más
/// grande). Un torrent sin archivos todavía no se puede mapear.
int selectTorrentFileIndex(List<RqbitTorrentFile> files, int? preferred) {
  if (files.isEmpty) {
    throw const RqbitNoFilesException();
  }
  if (preferred != null &&
      preferred >= 0 &&
      preferred < files.length &&
      files[preferred].included) {
    return preferred;
  }

  final candidates = files.where((file) => file.included).toList();
  final pool = candidates.isEmpty ? files : candidates;
  final videos = pool.where((file) => isVideoFileName(file.name)).toList();
  final ranked = videos.isEmpty ? pool : videos;

  var best = 0;
  for (var index = 1; index < ranked.length; index++) {
    if (ranked[index].length > ranked[best].length) best = index;
  }
  // Se busca el índice real dentro de la lista original, no dentro del filtro.
  return files.indexOf(ranked[best]);
}

/// Extensiones que el reproductor sabe abrir; el resto (subtítulos, NFO) no
/// sirve como pista principal.
bool isVideoFileName(String name) {
  final lower = name.toLowerCase();
  return const [
    '.mp4',
    '.mkv',
    '.avi',
    '.webm',
    '.mov',
    '.m4v',
    '.mpg',
    '.mpeg',
    '.ts',
    '.m2ts',
    '.wmv',
    '.flv',
    '.ogv',
  ].any(lower.endsWith);
}

/// El torrent todavía no tiene metadatos: no hay archivos que servir.
class RqbitNoFilesException implements Exception {
  const RqbitNoFilesException();

  @override
  String toString() => 'El torrent no tiene archivos que reproducir';
}

Map<String, dynamic> _asMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.map((key, value) => MapEntry('$key', value));
  return const {};
}

String? _string(Object? value) {
  if (value is String && value.isNotEmpty) return value;
  return null;
}

int? _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}
