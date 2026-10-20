import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:logger/logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _log = Logger(printer: SimplePrinter());

/// Keys in SharedPreferences to include in backup.
///
/// Ninguna es un secreto: las claves de Trakt/TMDB, los tokens debrid y la
/// clave de emparejamiento de las TV LG viven en el almacén seguro y no se
/// exportan. Restaurar deja la configuración intacta y sólo hay que volver a
/// introducir las credenciales.
const _backupPrefKeys = [
  'shows_favorites',
  'last_group',
  'last_channel_id',
  'channel_history',
  'resume_last_channel',
  'failover_enabled',
];

/// Prefix patterns for dynamic keys to back up.
const _backupPrefPrefixes = [
  'show_last_season_',
];

/// La estructura de debrid sí viaja (orden y habilitado), sin tokens.
const _debridConfigsKey = 'shows_debrid_configs';

/// Copia de preferencias apta para un backup: nunca lleva credenciales.
///
/// Se sanea también el documento de debrid, por si una instalación donde el
/// almacén seguro no estaba disponible aún conserva tokens dentro: es el
/// único punto donde un secreto podría colarse en el fichero.
Map<String, dynamic> collectBackupPreferences(SharedPreferences prefs) {
  final data = <String, dynamic>{};
  for (final key in _backupPrefKeys) {
    final value = prefs.get(key);
    if (value != null) data[key] = value;
  }
  final debrid = prefs.getString(_debridConfigsKey);
  final sanitized = debrid == null ? null : _stripDebridTokens(debrid);
  if (sanitized != null) data[_debridConfigsKey] = sanitized;

  for (final allKey in prefs.getKeys()) {
    for (final prefix in _backupPrefPrefixes) {
      if (allKey.startsWith(prefix)) {
        data[allKey] = prefs.get(allKey);
      }
    }
  }
  return data;
}

/// Quita los tokens de un documento de debrid conservando el resto.
/// Devuelve null si no se puede interpretar (mejor no exportarlo a ciegas).
String? _stripDebridTokens(String raw) {
  try {
    final decoded = jsonDecode(raw);
    final services = decoded is Map ? decoded['services'] : decoded;
    if (services is! List) return null;
    return jsonEncode({
      'version': 3,
      'services': [
        for (final entry in services)
          if (entry is Map && entry['type'] is String)
            {'type': entry['type'], 'enabled': entry['enabled'] != false},
      ],
    });
  } catch (_) {
    return null;
  }
}

/// Creates and restores `.clubtivi` backup files (ZIP archive) containing
/// the SQLite database and SharedPreferences snapshot.
class BackupService {
  /// Export all data to a `.clubtivi` backup file.
  static Future<String> exportBackup() async {
    final archive = Archive();

    // 1. SQLite database
    final dir = await getApplicationSupportDirectory();
    final dbFile = File(p.join(dir.path, 'clubtivi', 'clubtivi.db'));
    if (await dbFile.exists()) {
      final bytes = await dbFile.readAsBytes();
      archive.addFile(ArchiveFile('clubtivi.db', bytes.length, bytes));
      _log.i('Backup: added database (${bytes.length} bytes)');
    }

    // 2. SharedPreferences as JSON (sin credenciales)
    final prefs = await SharedPreferences.getInstance();
    final prefJson = utf8.encode(jsonEncode(collectBackupPreferences(prefs)));
    archive.addFile(ArchiveFile('preferences.json', prefJson.length, prefJson));

    // 3. Metadata
    final meta = utf8.encode(jsonEncode({
      'version': 1,
      'app': 'clubTivi',
      'created': DateTime.now().toIso8601String(),
      'platform': Platform.operatingSystem,
    }));
    archive.addFile(ArchiveFile('meta.json', meta.length, meta));

    // 4. Write ZIP
    final zipBytes = ZipEncoder().encode(archive);

    final ts = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    final outDir = await getApplicationDocumentsDirectory();
    final outPath = p.join(outDir.path, 'clubtivi-backup-$ts.clubtivi');
    await File(outPath).writeAsBytes(zipBytes);
    _log.i('Backup exported to: $outPath');
    return outPath;
  }

  /// Import data from a `.clubtivi` backup file.
  static Future<String> importBackup(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) throw Exception('Backup file not found');

    final bytes = await file.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    String summary = '';

    // 1. Check metadata
    final metaFile = archive.findFile('meta.json');
    if (metaFile != null) {
      final meta = jsonDecode(utf8.decode(metaFile.content as List<int>));
      if ((meta['version'] as int? ?? 0) > 1) {
        throw Exception('Backup version too new');
      }
      summary += 'Backup from ${meta['created'] ?? 'unknown'}\n';
    }

    // 2. Restore database
    final dbArchiveFile = archive.findFile('clubtivi.db');
    if (dbArchiveFile != null) {
      final dir = await getApplicationSupportDirectory();
      final dbPath = p.join(dir.path, 'clubtivi', 'clubtivi.db');
      await File(dbPath).parent.create(recursive: true);
      await File(dbPath).writeAsBytes(dbArchiveFile.content as List<int>);
      summary += 'Database restored\n';
    }

    // 3. Restore preferences
    final prefFile = archive.findFile('preferences.json');
    if (prefFile != null) {
      final prefs = await SharedPreferences.getInstance();
      final data = jsonDecode(utf8.decode(prefFile.content as List<int>))
          as Map<String, dynamic>;

      // Un backup antiguo solo trae el mapa tipo→token. Si la app ya migró a
      // `shows_debrid_configs`, esa clave taparía la restaurada y la migración
      // no volvería a correr: se descarta para que se reconstruya al leerla.
      if (data.containsKey('shows_debrid_tokens') &&
          !data.containsKey('shows_debrid_configs')) {
        await prefs.remove('shows_debrid_configs');
      }

      int count = 0;
      for (final entry in data.entries) {
        final v = entry.value;
        if (v is String) { await prefs.setString(entry.key, v); count++; }
        else if (v is int) { await prefs.setInt(entry.key, v); count++; }
        else if (v is double) { await prefs.setDouble(entry.key, v); count++; }
        else if (v is bool) { await prefs.setBool(entry.key, v); count++; }
      }
      summary += '$count preferences restored\n';
    }

    return summary.trim();
  }
}
