/// Esquema de VOD (versión 7 de la base) en SQL.
///
/// Estas cinco tablas no son clases de Drift como las trece anteriores: la
/// cadena de generación de este entorno (build_runner + analyzer 7.6) no sabe
/// leer el SDK 3.13 y `database.g.dart` no se puede regenerar. Se declaran aquí
/// para que la migración tenga un único dueño; el día que se actualice esa
/// cadena se pueden mover a `tables.dart` sin tocar el DAO.
///
/// Las claves son las de `PlaybackRequest`: `media_key` identifica el título y
/// `content_key` el capítulo. Las fechas se guardan como milisegundos desde
/// epoch (UTC), igual que hace Drift en el resto de la base.
library;

/// `CREATE TABLE` de la versión 7, en orden de dependencias.
const List<String> vodSchemaV7 = [
  // Identidad de un título de VOD: una fila por película o serie, compartida
  // por progreso, favoritos y estado de serie.
  '''
  CREATE TABLE IF NOT EXISTS media_titles (
    media_key TEXT NOT NULL PRIMARY KEY,
    kind TEXT NOT NULL,
    title TEXT NOT NULL,
    year INTEGER,
    poster_url TEXT,
    updated_at INTEGER NOT NULL
  )
  ''',
  // Por dónde iba cada capítulo: `content_key` ya incluye temporada y
  // episodio, así que S01E02 y S01E03 son dos filas del mismo título.
  '''
  CREATE TABLE IF NOT EXISTS playback_progress (
    content_key TEXT NOT NULL PRIMARY KEY,
    media_key TEXT NOT NULL REFERENCES media_titles (media_key),
    season INTEGER,
    episode INTEGER,
    position_ms INTEGER NOT NULL DEFAULT 0,
    duration_ms INTEGER NOT NULL DEFAULT 0,
    completed INTEGER NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL
  )
  ''',
  // El release elegido para no volver a abrir el selector. Guarda cómo volver
  // a resolverlo, nunca la URL final: un enlace de debrid caduca.
  '''
  CREATE TABLE IF NOT EXISTS playback_sources (
    media_key TEXT NOT NULL REFERENCES media_titles (media_key),
    source_id TEXT NOT NULL,
    provider_id TEXT NOT NULL,
    info_hash TEXT,
    file_idx INTEGER,
    quality TEXT,
    size_bytes INTEGER,
    fail_count INTEGER NOT NULL DEFAULT 0,
    last_used_at INTEGER NOT NULL,
    PRIMARY KEY (media_key, source_id)
  )
  ''',
  // Favoritos de VOD, separados de los favoritos de canales.
  '''
  CREATE TABLE IF NOT EXISTS media_favorites (
    media_key TEXT NOT NULL PRIMARY KEY REFERENCES media_titles (media_key),
    added_at INTEGER NOT NULL
  )
  ''',
  // La temporada que el usuario estaba mirando en la ficha (hoy en
  // `show_last_season_*` de SharedPreferences). El capítulo, por dónde va,
  // vive en playback_progress.
  '''
  CREATE TABLE IF NOT EXISTS series_state (
    media_key TEXT NOT NULL PRIMARY KEY REFERENCES media_titles (media_key),
    last_season INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
  )
  ''',
];

/// Nombres de las tablas de la versión 7, para comprobaciones y limpiezas.
const List<String> vodTablesV7 = [
  'media_titles',
  'playback_progress',
  'playback_sources',
  'media_favorites',
  'series_state',
];
