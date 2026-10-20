import 'package:drift/drift.dart' show QueryRow, Variable;

import '../../models/playback_request.dart';
import 'database.dart';

/// Identidad de un título de VOD guardada en la base.
class MediaTitle {
  final String mediaKey;

  /// `movie` o `series`.
  final String kind;

  /// Nombre del título, sin código de episodio.
  final String title;
  final int? year;
  final String? posterUrl;

  const MediaTitle({
    required this.mediaKey,
    required this.kind,
    required this.title,
    this.year,
    this.posterUrl,
  });
}

/// Por dónde iba un capítulo (o una película).
class PlaybackProgressRow {
  /// Clave del capítulo: `mediaKey` + temporada/episodio.
  final String contentKey;
  final String mediaKey;
  final int? season;
  final int? episode;
  final Duration position;
  final Duration duration;
  final bool completed;
  final DateTime updatedAt;

  const PlaybackProgressRow({
    required this.contentKey,
    required this.mediaKey,
    required this.position,
    required this.duration,
    required this.completed,
    required this.updatedAt,
    this.season,
    this.episode,
  });

  /// Lo que falta para el final; cero si la duración aún no se conoce.
  Duration get remaining =>
      duration > position ? duration - position : Duration.zero;
}

/// El release recordado para volver a resolverlo sin buscar de nuevo.
class PlaybackSourceRow {
  final String mediaKey;
  final String sourceId;
  final String providerId;
  final String? infoHash;
  final int? fileIdx;
  final String? quality;
  final int? sizeBytes;
  final int failCount;
  final DateTime lastUsedAt;

  const PlaybackSourceRow({
    required this.mediaKey,
    required this.sourceId,
    required this.providerId,
    required this.lastUsedAt,
    this.infoHash,
    this.fileIdx,
    this.quality,
    this.sizeBytes,
    this.failCount = 0,
  });
}

/// Una fila de «continuar viendo»: el título con el progreso del capítulo.
class RecentlyWatched {
  final MediaTitle media;
  final PlaybackProgressRow progress;

  const RecentlyWatched({required this.media, required this.progress});
}

/// Único dueño de las tablas de VOD de la base local.
///
/// Habla con las claves de [PlaybackRequest] (`mediaKey` para el título,
/// `contentKey` para el capítulo) y con ids de release. No acepta URLs ya
/// resueltas: un enlace de debrid caduca y guardarlo sería guardar basura.
class PlaybackDao {
  PlaybackDao(this._db);

  final AppDatabase _db;

  /// Escribe (o actualiza) por dónde va [request].
  ///
  /// Idempotente por `contentKey`: guardar dos veces el mismo capítulo deja una
  /// sola fila con el último tiempo. [completed] lo calcula quien graba con los
  /// umbrales de reanudación; el DAO no interpreta posiciones.
  ///
  /// [mediaTitle] es el nombre del título sin el código de episodio (la ficha
  /// pasa «Carrie», no «Carrie S01E02»). Si se omite se usa `request.title`,
  /// que para un capítulo lleva el sufijo.
  Future<void> saveProgress(
    PlaybackRequest request, {
    required Duration position,
    required Duration duration,
    bool completed = false,
    String? mediaTitle,
    DateTime? at,
  }) {
    final when = at ?? DateTime.now();
    return _db.transaction(() async {
      await _rememberMedia(request, when, title: mediaTitle);
      await _db.customInsert(
        'INSERT INTO playback_progress '
        '(content_key, media_key, season, episode, position_ms, duration_ms, '
        'completed, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(content_key) DO UPDATE SET '
        'media_key = excluded.media_key, season = excluded.season, '
        'episode = excluded.episode, position_ms = excluded.position_ms, '
        'duration_ms = excluded.duration_ms, completed = excluded.completed, '
        'updated_at = excluded.updated_at',
        variables: [
          Variable(request.contentKey),
          Variable(request.mediaKey),
          Variable(request.season),
          Variable(request.episode),
          Variable(position.inMilliseconds),
          Variable(duration.inMilliseconds),
          Variable(completed ? 1 : 0),
          Variable(when.millisecondsSinceEpoch),
        ],
      );
    });
  }

  /// El progreso de un capítulo concreto, o null si nunca se empezó.
  Future<PlaybackProgressRow?> progressFor(String contentKey) async {
    final rows = await _db.customSelect(
      'SELECT * FROM playback_progress WHERE content_key = ?',
      variables: [Variable(contentKey)],
    ).get();
    return rows.isEmpty ? null : _progressFromRow(rows.single);
  }

  /// Lo último visto, de más reciente a más antiguo.
  ///
  /// Por defecto deja fuera lo terminado: es la lista de «continuar viendo»,
  /// no un historial.
  Future<List<RecentlyWatched>> recentlyWatched({
    int limit = 20,
    bool includeCompleted = false,
  }) async {
    final rows = await _db.customSelect(
      'SELECT p.*, m.kind AS m_kind, m.title AS m_title, m.year AS m_year, '
      'm.poster_url AS m_poster_url '
      'FROM playback_progress p '
      'JOIN media_titles m ON m.media_key = p.media_key '
      '${includeCompleted ? '' : 'WHERE p.completed = 0 '}'
      'ORDER BY p.updated_at DESC LIMIT ?',
      variables: [Variable(limit)],
    ).get();
    return [
      for (final row in rows)
        RecentlyWatched(
          media: MediaTitle(
            mediaKey: row.read<String>('media_key'),
            kind: row.read<String>('m_kind'),
            title: row.read<String>('m_title'),
            year: row.readNullable<int>('m_year'),
            posterUrl: row.readNullable<String>('m_poster_url'),
          ),
          progress: _progressFromRow(row),
        ),
    ];
  }

  /// Recuerda con qué release se abrió un título, para no volver a buscarlo.
  ///
  /// Guarda cómo volver a resolverlo (`infoHash` + `fileIdx` y el servicio que
  /// respondió), nunca la URL final. La clave es título + release: un pack de
  /// temporada sirve para varios capítulos, así que la memoria es del título.
  /// Volver a elegir el release pone [failCount] a cero: acaba de funcionar.
  Future<void> recordSource(
    PlaybackRequest request, {
    required String providerId,
    String? sourceId,
    String? infoHash,
    int? fileIdx,
    String? quality,
    int? sizeBytes,
    DateTime? at,
  }) {
    final when = at ?? DateTime.now();
    final id = sourceId ?? request.sourceId;
    return _db.transaction(() async {
      await _rememberMedia(request, when);
      await _db.customInsert(
        'INSERT INTO playback_sources '
        '(media_key, source_id, provider_id, info_hash, file_idx, quality, '
        'size_bytes, fail_count, last_used_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(media_key, source_id) DO UPDATE SET '
        'provider_id = excluded.provider_id, info_hash = excluded.info_hash, '
        'file_idx = excluded.file_idx, quality = excluded.quality, '
        'size_bytes = excluded.size_bytes, fail_count = 0, '
        'last_used_at = excluded.last_used_at',
        variables: [
          Variable(request.mediaKey),
          Variable(id),
          Variable(providerId),
          Variable(infoHash),
          Variable(fileIdx),
          Variable(quality),
          Variable(sizeBytes),
          Variable(0),
          Variable(when.millisecondsSinceEpoch),
        ],
      );
    });
  }

  /// El release recordado para un título, o null si nunca se usó.
  Future<PlaybackSourceRow?> sourceFor(String mediaKey, String sourceId) async {
    final rows = await _db.customSelect(
      'SELECT * FROM playback_sources WHERE media_key = ? AND source_id = ?',
      variables: [Variable(mediaKey), Variable(sourceId)],
    ).get();
    return rows.isEmpty ? null : _sourceFromRow(rows.single);
  }

  /// El release más reciente del título que todavía merece ofrecerse.
  ///
  /// Deja fuera los que ya acumulan [maxFailures] fallos: insistir con un
  /// release que no engancha sólo hace esperar al usuario. La fila no se borra,
  /// así que volver a elegirlo a mano lo recupera.
  Future<PlaybackSourceRow?> rememberedSource(
    String mediaKey, {
    int maxFailures = 2,
  }) async {
    final rows = await _db.customSelect(
      'SELECT * FROM playback_sources '
      'WHERE media_key = ? AND fail_count < ? '
      'ORDER BY last_used_at DESC LIMIT 1',
      variables: [Variable(mediaKey), Variable(maxFailures)],
    ).get();
    return rows.isEmpty ? null : _sourceFromRow(rows.single);
  }

  /// Suma un fallo al release. Nunca borra la fila: un fallo puede ser el
  /// servidor del debrid o un enlace caído, y el usuario aún puede elegirlo.
  Future<void> markSourceFailed(String mediaKey, String sourceId) =>
      _db.customUpdate(
        'UPDATE playback_sources SET fail_count = fail_count + 1 '
        'WHERE media_key = ? AND source_id = ?',
        variables: [Variable(mediaKey), Variable(sourceId)],
      );

  /// El título debe existir antes que su progreso o su release.
  ///
  /// `DO NOTHING` para no reescribir con «Carrie S01E01» un nombre limpio que
  /// ya estaba guardado; el título sólo se sustituye cuando llega uno
  /// explícito.
  Future<void> _rememberMedia(
    PlaybackRequest request,
    DateTime when, {
    String? title,
  }) async {
    await _db.customInsert(
      'INSERT INTO media_titles (media_key, kind, title, updated_at) '
      'VALUES (?, ?, ?, ?) ON CONFLICT(media_key) DO NOTHING',
      variables: [
        Variable(request.mediaKey),
        Variable(request.kind.name),
        Variable(title ?? request.title),
        Variable(when.millisecondsSinceEpoch),
      ],
    );
    if (title != null) {
      await _db.customUpdate(
        'UPDATE media_titles SET title = ?, updated_at = ? WHERE media_key = ?',
        variables: [
          Variable(title),
          Variable(when.millisecondsSinceEpoch),
          Variable(request.mediaKey),
        ],
      );
    }
  }

  PlaybackSourceRow _sourceFromRow(QueryRow row) {
    return PlaybackSourceRow(
      mediaKey: row.read<String>('media_key'),
      sourceId: row.read<String>('source_id'),
      providerId: row.read<String>('provider_id'),
      infoHash: row.readNullable<String>('info_hash'),
      fileIdx: row.readNullable<int>('file_idx'),
      quality: row.readNullable<String>('quality'),
      sizeBytes: row.readNullable<int>('size_bytes'),
      failCount: row.read<int>('fail_count'),
      lastUsedAt: _date(row.read<int>('last_used_at')),
    );
  }

  PlaybackProgressRow _progressFromRow(QueryRow row) {
    return PlaybackProgressRow(
      contentKey: row.read<String>('content_key'),
      mediaKey: row.read<String>('media_key'),
      season: row.readNullable<int>('season'),
      episode: row.readNullable<int>('episode'),
      position: Duration(milliseconds: row.read<int>('position_ms')),
      duration: Duration(milliseconds: row.read<int>('duration_ms')),
      completed: row.read<int>('completed') != 0,
      updatedAt: _date(row.read<int>('updated_at')),
    );
  }

  DateTime _date(int millisecondsSinceEpoch) =>
      DateTime.fromMillisecondsSinceEpoch(millisecondsSinceEpoch);
}
