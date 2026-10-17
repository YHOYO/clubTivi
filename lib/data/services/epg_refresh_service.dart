import 'package:drift/drift.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../datasources/local/database.dart' as db;
import '../datasources/parsers/xmltv_parser.dart';
import '../../features/providers/provider_manager.dart';

class EpgRefreshService {
  /// Guide window kept in the database around "now".
  ///
  /// Feeds carry far more (the default sources ship a week or two of listings),
  /// and storing it all was what made the guide database — and the memory the
  /// app needs to walk it — grow without bound.
  static const retentionPast = Duration(days: 1);
  static const retentionFuture = Duration(days: 7);

  /// Programmes handed to SQLite per batch during a refresh. Large enough that
  /// the transaction count stays small (each commit is a real disk sync) and
  /// small enough that a batch is a few hundred KB of objects.
  static const insertBatchSize = 5000;

  final db.AppDatabase _db;
  final _uuid = const Uuid();

  EpgRefreshService(this._db);

  /// Refresh a single EPG source by ID.
  Future<void> refreshSource(String sourceId) async {
    final sources = await _db.getAllEpgSources();
    final source = sources.firstWhere((s) => s.id == sourceId);
    debugPrint('[EPG] Refreshing source: ${source.name} (${source.url})');

    // Download XMLTV data
    final dio = Dio(BaseOptions(
      headers: {
        'User-Agent': 'clubTivi/1.0 IPTV Player (compatible; XMLTV fetcher)',
      },
    ));
    try {
      final response = await dio.get<List<int>>(
        source.url,
        options: Options(responseType: ResponseType.bytes),
      );

      final bytes = response.data!;
      debugPrint('[EPG] Downloaded ${bytes.length} bytes');

      final now = DateTime.now();
      final stopwatch = Stopwatch()..start();

      // Old programmes go first: the streamed parse writes the new ones as it
      // walks the feed.
      await _db.deleteEpgProgrammesForSource(sourceId);

      // Streamed parse + batched inserts: the feed is never materialized as a
      // document nor as a list of every programme (see XmltvParser.parseStreaming).
      final stats = await XmltvParser().parseBytesStreaming(
        bytes,
        sourceId: sourceId,
        batchSize: insertBatchSize,
        keepFrom: now.subtract(retentionPast),
        keepUntil: now.add(retentionFuture),
        onChannels: (channels) async {
          await _db.upsertEpgChannels(channels.map((c) {
            return db.EpgChannelsCompanion.insert(
              id: '${sourceId}_${c.id}',
              sourceId: sourceId,
              channelId: c.id,
              displayName: c.primaryName,
              iconUrl: Value(c.iconUrl),
            );
          }).toList());
        },
        onProgrammes: (programmes) async {
          await _db.insertEpgProgrammes(programmes.map((p) {
            return db.EpgProgrammesCompanion.insert(
              epgChannelId: '${sourceId}_${p.channelId}',
              sourceId: sourceId,
              title: p.title,
              description: Value(p.description),
              category: Value(p.category),
              subtitle: Value(p.subtitle),
              episodeNum: Value(p.episodeNum),
              start: p.start,
              stop: p.stop,
            );
          }).toList());
          // Yield to the event loop between batches so the UI stays responsive
          // and the batch becomes garbage as soon as it is written.
          await Future<void>.delayed(Duration.zero);
        },
      );
      debugPrint('[EPG] Stored ${stats.programmes} programmes in '
          '${stats.batches} batches (${stats.skipped} outside the window, '
          '${stats.channels} channels) in ${stopwatch.elapsedMilliseconds} ms');

      // Anything the previous refresh left outside the window (or older feeds)
      // is dead weight for every guide query.
      await _db.pruneProgrammes(
        keepPast: retentionPast,
        keepFuture: retentionFuture,
      );

      // Update last refresh timestamp
      await _db.updateEpgSourceRefreshTime(sourceId);
    } finally {
      dio.close();
    }
  }

  /// Refresh all enabled EPG sources (skips sources refreshed within the last 4 hours).
  Future<void> refreshAllSources({bool force = false}) async {
    final sources = await _db.getAllEpgSources();
    final now = DateTime.now();
    for (final source in sources.where((s) => s.enabled)) {
      if (!force && source.lastRefresh != null &&
          now.difference(source.lastRefresh!).inHours < 4) {
        debugPrint('[EPG] Skipping ${source.name} — refreshed ${now.difference(source.lastRefresh!).inMinutes}m ago');
        continue;
      }
      try {
        await refreshSource(source.id);
      } catch (e) {
        debugPrint('[EPG] Error refreshing ${source.name}: $e');
      }
    }
  }

  /// Add default free EPG sources if none exist.
  Future<void> addDefaultSources() async {
    final existing = await _db.getAllEpgSources();
    if (existing.isNotEmpty) return;
    await _insertDefaults();
  }

  /// Delete all existing sources and re-add defaults.
  Future<void> resetToDefaultSources() async {
    final existing = await _db.getAllEpgSources();
    for (final s in existing) {
      await _db.deleteEpgSource(s.id);
    }
    await _insertDefaults();
  }

  Future<void> _insertDefaults() async {
    final defaults = [
      (
        name: 'EPG.best',
        url: 'http://epg.best/16b5b-ypkixv.xml.gz',
        enabled: true,
      ),
      (
        name: 'USA Locals (ABC, CBS, Fox, NBC)',
        url: 'https://raw.githubusercontent.com/usa-local-epg/usa-locals/main/usalocals.xml.gz',
        enabled: true,
      ),
    ];

    for (final d in defaults) {
      await _db.upsertEpgSource(db.EpgSourcesCompanion.insert(
        id: _uuid.v4(),
        name: d.name,
        url: d.url,
        enabled: Value(d.enabled),
      ));
    }
  }
}

final epgRefreshServiceProvider = Provider<EpgRefreshService>((ref) {
  return EpgRefreshService(ref.watch(databaseProvider));
});


