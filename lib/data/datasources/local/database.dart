import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../models/epg.dart' show EpgProgrammeSlot;
import 'playback_schema.dart';
import 'tables.dart';

part 'database.g.dart';

const _uuid = Uuid();

@DriftDatabase(tables: [
  Providers,
  Channels,
  EpgSources,
  EpgChannels,
  EpgProgrammes,
  EpgMappings,
  ChannelGroups,
  FavoriteLists,
  FavoriteListChannels,
  EpgReminders,
  ScheduledRecordings,
  FailoverGroups,
  FailoverGroupChannels,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  AppDatabase.forTesting(super.e);

  /// The app's on-disk setup on a given file: same pragmas, migrations and
  /// background isolate, so tests and benchmarks measure what users get.
  AppDatabase.forFile(File file)
      : super(NativeDatabase.createInBackground(file));

  @override
  int get schemaVersion => 7;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        // A refresh can insert hundreds of thousands of programmes; in rollback
        // journal mode each batch waits for an fsync and the write transaction
        // blocks the guide's reads. WAL lets the guide keep querying while a
        // refresh writes, and NORMAL keeps the durability the app needs while
        // dropping the per-batch fsync. Harmless on in-memory test databases.
        beforeOpen: (details) async {
          await customStatement('PRAGMA journal_mode = WAL;');
          await customStatement('PRAGMA synchronous = NORMAL;');
        },
        onCreate: (m) async {
          await m.createAll();
          await _createVodTables();
        },
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.createTable(favoriteLists);
            await m.createTable(favoriteListChannels);
          }
          if (from < 3) {
            await m.createTable(epgReminders);
            await m.createTable(scheduledRecordings);
          }
          if (from < 4) {
            await m.addColumn(epgProgrammes, epgProgrammes.subtitle);
            await m.addColumn(epgProgrammes, epgProgrammes.episodeNum);
          }
          if (from < 5) {
            await m.createTable(failoverGroups);
            await m.createTable(failoverGroupChannels);
          }
          if (from < 6) {
            // Una base migrada a medias puede tener ya la columna y seguir en
            // la version 5: ALTER TABLE ... ADD COLUMN falla con "duplicate
            // column name" y el arranque se queda en «Loading providers…».
            // Solo se añade si de verdad falta.
            final columns =
                await customSelect('PRAGMA table_info(channels)').get();
            final hasHttpHeaders = columns.any(
              (row) => row.read<String>('name') == 'http_headers',
            );
            if (!hasHttpHeaders) {
              await m.addColumn(channels, channels.httpHeaders);
            }
          }
          if (from < 7) {
            // El VOD estrena sus propias tablas. Las trece anteriores no se
            // tocan: un canal, su EPG y sus favoritos siguen donde estaban.
            await _createVodTables();
          }
        },
      );

  /// Las tablas de la versión 7, que no son clases de Drift (ver
  /// `playback_schema.dart`). Las crea el arranque y las migra `onUpgrade`.
  Future<void> _createVodTables() async {
    for (final statement in vodSchemaV7) {
      await customStatement(statement);
    }
  }

  // --- Provider queries ---

  Future<List<Provider>> getAllProviders() => select(providers).get();

  Future<void> upsertProvider(ProvidersCompanion entry) =>
      into(providers).insertOnConflictUpdate(entry);

  /// Borra la contraseña de la fila una vez que vive en el almacén seguro.
  Future<void> clearProviderPassword(String id) =>
      (update(providers)..where((t) => t.id.equals(id)))
          .write(const ProvidersCompanion(password: Value(null)));

  /// Remove a provider **and everything it contributed**.
  ///
  /// Dropping only the provider row left its channels behind: they kept showing
  /// up in All/group lists (the orphaned Roku entries) with no provider to
  /// refresh or remove them from, and their EPG mappings pointed at nothing.
  Future<void> deleteProvider(String id) => transaction(() async {
        final channelIds = await (select(channels)
              ..where((t) => t.providerId.equals(id)))
            .map((t) => t.id)
            .get();

        await (delete(channels)..where((t) => t.providerId.equals(id))).go();
        await (delete(epgMappings)..where((t) => t.providerId.equals(id))).go();
        if (channelIds.isNotEmpty) {
          await (delete(favoriteListChannels)
                ..where((t) => t.channelId.isIn(channelIds)))
              .go();
          await (delete(failoverGroupChannels)
                ..where((t) => t.channelId.isIn(channelIds)))
              .go();
        }

        // Guide that the playlist itself announced (`#EXTM3U url-tvg=…`).
        final epgSourceId = '$id-playlist-epg';
        await (delete(epgProgrammes)..where((t) => t.sourceId.equals(epgSourceId)))
            .go();
        await (delete(epgChannels)..where((t) => t.sourceId.equals(epgSourceId)))
            .go();
        await (delete(epgMappings)..where((t) => t.epgSourceId.equals(epgSourceId)))
            .go();
        await (delete(epgSources)..where((t) => t.id.equals(epgSourceId))).go();

        await (delete(providers)..where((t) => t.id.equals(id))).go();
      });

  // --- Channel queries ---

  /// Channels of a provider.
  ///
  /// Hidden rows are duplicates the parser parked as failover alternatives, so
  /// listings exclude them by default; pass [includeHidden] when the caller
  /// needs the whole set (alternatives, failover, EPG mapping).
  /// Deletes channels left behind by older versions that removed only the
  /// provider row. They showed up in All/searches with no provider behind them.
  Future<int> purgeOrphanChannels() => customUpdate(
        'DELETE FROM channels WHERE provider_id NOT IN '
        '(SELECT id FROM providers)',
      );

  Future<List<Channel>> getChannelsForProvider(
    String providerId, {
    bool includeHidden = false,
  }) =>
      (select(channels)
            ..where((t) =>
                t.providerId.equals(providerId) &
                (includeHidden ? const Constant(true) : t.hidden.equals(false))))
          .get();

  /// Every channel the user should see in the sidebar and channel lists.
  Future<List<Channel>> getVisibleChannels() =>
      (select(channels)..where((t) => t.hidden.equals(false))).get();

  Future<void> setChannelsHidden(Iterable<String> ids, {required bool hidden}) =>
      (update(channels)..where((t) => t.id.isIn(ids)))
          .write(ChannelsCompanion(hidden: Value(hidden)));

  Future<List<Channel>> getChannelsByIds(Set<String> ids) =>
      (select(channels)..where((t) => t.id.isIn(ids))).get();

  /// Get distinct group names per provider without loading channel objects.
  Future<Map<String, List<String>>> getProviderGroups() async {
    final rows = await customSelect(
      'SELECT DISTINCT provider_id, group_title FROM channels '
      "WHERE hidden = 0 AND group_title IS NOT NULL AND group_title != '' "
      'ORDER BY provider_id, group_title',
    ).get();
    final result = <String, List<String>>{};
    for (final row in rows) {
      final pid = row.read<String>('provider_id');
      final g = row.read<String>('group_title');
      (result[pid] ??= []).add(g);
    }
    return result;
  }

  /// Get channels for a specific provider and group.
  Future<List<Channel>> getChannelsForProviderGroup(
    String providerId,
    String groupTitle, {
    bool includeHidden = false,
  }) =>
      (select(channels)..where((t) =>
          t.providerId.equals(providerId) &
          t.groupTitle.equals(groupTitle) &
          (includeHidden ? const Constant(true) : t.hidden.equals(false))))
          .get();

  Future<List<Channel>> getFavoriteChannels() =>
      (select(channels)..where((t) => t.favorite.equals(true))).get();

  Future<void> upsertChannels(List<ChannelsCompanion> entries) async {
    await batch((b) {
      b.insertAllOnConflictUpdate(channels, entries);
    });
  }

  Future<void> updateChannelLogo(String channelId, String logoUrl) =>
      (update(channels)..where((t) => t.id.equals(channelId)))
          .write(ChannelsCompanion(tvgLogo: Value(logoUrl)));

  /// Batch-update logos for multiple channels in a single transaction.
  Future<void> updateChannelLogos(Map<String, String> idToLogoUrl) async {
    await batch((b) {
      for (final entry in idToLogoUrl.entries) {
        b.update(channels, ChannelsCompanion(tvgLogo: Value(entry.value)),
            where: (t) => t.id.equals(entry.key));
      }
    });
  }

  Future<void> renameChannel(String channelId, String providerId, String newName) =>
      (update(channels)..where((t) => t.id.equals(channelId)))
          .write(ChannelsCompanion(name: Value(newName)));

  Future<void> toggleFavorite(String channelId) async {
    final channel =
        await (select(channels)..where((t) => t.id.equals(channelId)))
            .getSingle();
    await (update(channels)..where((t) => t.id.equals(channelId)))
        .write(ChannelsCompanion(favorite: Value(!channel.favorite)));
  }

  // --- EPG Source queries ---

  Future<List<EpgSource>> getAllEpgSources() => select(epgSources).get();

  Future<void> upsertEpgSource(EpgSourcesCompanion entry) =>
      into(epgSources).insertOnConflictUpdate(entry);

  // --- EPG Channel queries ---

  Future<List<EpgChannel>> getEpgChannelsForSource(String sourceId) =>
      (select(epgChannels)..where((t) => t.sourceId.equals(sourceId))).get();

  Future<void> upsertEpgChannels(List<EpgChannelsCompanion> entries) async {
    await batch((b) {
      b.insertAllOnConflictUpdate(epgChannels, entries);
    });
  }

  // --- EPG Programme queries ---

  Future<List<EpgProgramme>> getProgrammes({
    required String epgChannelId,
    required DateTime start,
    required DateTime end,
  }) =>
      (select(epgProgrammes)
            ..where((t) =>
                t.epgChannelId.equals(epgChannelId) &
                t.start.isBiggerOrEqualValue(start) &
                t.stop.isSmallerOrEqualValue(end))
            ..orderBy([(t) => OrderingTerm.asc(t.start)]))
          .get();

  /// Get what's on now for a list of EPG channel IDs.
  /// Lightweight guide query: only the fields the timeline paints.
  ///
  /// The full-row query loads every description/category/episode string of the
  /// day for each visible channel, which is a lot of memory for data the guide
  /// never renders.
  Future<List<EpgProgrammeSlot>> getProgrammeSlots({
    required String epgChannelId,
    required DateTime start,
    required DateTime end,
  }) async {
    final query = selectOnly(epgProgrammes)
      ..addColumns(
          [epgProgrammes.title, epgProgrammes.start, epgProgrammes.stop])
      ..where(epgProgrammes.epgChannelId.equals(epgChannelId) &
          epgProgrammes.start.isBiggerOrEqualValue(start) &
          epgProgrammes.stop.isSmallerOrEqualValue(end))
      ..orderBy([OrderingTerm.asc(epgProgrammes.start)]);

    final rows = await query.get();
    return rows
        .map((row) => EpgProgrammeSlot(
              title: row.read(epgProgrammes.title) ?? '',
              start: row.read(epgProgrammes.start)!,
              stop: row.read(epgProgrammes.stop)!,
            ))
        .toList();
  }

  Future<List<EpgProgramme>> getNowPlaying(List<String> epgChannelIds) {
    final now = DateTime.now();
    return (select(epgProgrammes)
          ..where((t) =>
              t.epgChannelId.isIn(epgChannelIds) &
              t.start.isSmallerOrEqualValue(now) &
              t.stop.isBiggerOrEqualValue(now)))
        .get();
  }

  Future<List<EpgProgramme>> getNowPlayingWindow(
    List<String> epgChannelIds, DateTime from, DateTime to,
  ) {
    return (select(epgProgrammes)
          ..where((t) =>
              t.epgChannelId.isIn(epgChannelIds) &
              t.start.isSmallerOrEqualValue(to) &
              t.stop.isBiggerOrEqualValue(from)))
        .get();
  }

  Future<void> insertProgrammes(List<EpgProgrammesCompanion> entries) async {
    await batch((b) {
      b.insertAll(epgProgrammes, entries, mode: InsertMode.insertOrReplace);
    });
  }

  Future<void> deleteEpgProgrammesForSource(String sourceId) =>
      (delete(epgProgrammes)..where((t) => t.sourceId.equals(sourceId))).go();

  Future<void> insertEpgProgrammes(List<EpgProgrammesCompanion> entries) async {
    await batch((b) {
      b.insertAll(epgProgrammes, entries);
    });
  }

  Future<void> updateEpgSourceRefreshTime(String id) =>
      (update(epgSources)..where((t) => t.id.equals(id)))
          .write(EpgSourcesCompanion(lastRefresh: Value(DateTime.now())));

  Future<void> deleteEpgSource(String id) async {
    await deleteEpgProgrammesForSource(id);
    await (delete(epgChannels)..where((t) => t.sourceId.equals(id))).go();
    await (delete(epgSources)..where((t) => t.id.equals(id))).go();
  }

  Future<List<Channel>> getAllChannels() => select(channels).get();

  /// Delete old programmes to keep DB size manageable.
  Future<void> pruneOldProgrammes({Duration maxAge = const Duration(days: 7)}) =>
      pruneProgrammes(keepPast: maxAge);

  /// Delete programmes outside the retention window, in both directions.
  ///
  /// Feeds usually carry a week or two of listings; keeping the far future (and
  /// the distant past) only inflates the database and every guide query that
  /// has to scan it. The next refresh downloads the window again.
  Future<void> pruneProgrammes({
    Duration keepPast = const Duration(days: 1),
    Duration keepFuture = const Duration(days: 7),
  }) {
    final now = DateTime.now();
    return (delete(epgProgrammes)
          ..where((t) =>
              t.stop.isSmallerThanValue(now.subtract(keepPast)) |
              t.start.isBiggerThanValue(now.add(keepFuture))))
        .go();
  }

  // --- EPG Mapping queries ---

  Future<List<EpgMapping>> getAllMappings() => select(epgMappings).get();

  Future<void> upsertMapping(EpgMappingsCompanion entry) =>
      into(epgMappings).insertOnConflictUpdate(entry);

  Future<void> upsertMappings(List<EpgMappingsCompanion> entries) async {
    await batch((b) {
      b.insertAllOnConflictUpdate(epgMappings, entries);
    });
  }

  Future<void> deleteMapping(String channelId, String providerId) =>
      (delete(epgMappings)
            ..where((t) =>
                t.channelId.equals(channelId) &
                t.providerId.equals(providerId)))
          .go();

  Future<void> deleteAllMappings() => delete(epgMappings).go();

  /// Get mapping stats.
  Future<Map<String, int>> getMappingStats() async {
    final all = await select(epgMappings).get();
    int mapped = 0, suggested = 0;
    for (final m in all) {
      if (m.source == 'auto' || m.source == 'manual') {
        mapped++;
      } else {
        suggested++;
      }
    }
    return {'mapped': mapped, 'suggested': suggested};
  }

  // --- Favorite List queries ---

  /// La lista fija de favoritos: la estrella de cada fila añade y quita de
  /// aquí, sin preguntar a qué lista. Las listas con nombre siguen existiendo
  /// para organizarlos (Sports, Kids…).
  static const defaultFavoritesListId = 'favorites-default';

  Future<List<FavoriteList>> getAllFavoriteLists() =>
      (select(favoriteLists)..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
          .get();

  /// La lista fija de favoritos, creada la primera vez que hace falta.
  ///
  /// Idempotente: se puede llamar en cada arranque sin duplicar nada.
  Future<FavoriteList> ensureDefaultFavoriteList() async {
    final existing = await (select(favoriteLists)
          ..where((t) => t.id.equals(defaultFavoritesListId)))
        .getSingleOrNull();
    if (existing != null) return existing;
    await into(favoriteLists).insertOnConflictUpdate(
      FavoriteListsCompanion.insert(
        id: defaultFavoritesListId,
        name: 'Favorites',
        icon: const Value('star'),
        // Por delante de las listas con nombre, que empiezan en 0.
        sortOrder: const Value(-1),
      ),
    );
    return (select(favoriteLists)
          ..where((t) => t.id.equals(defaultFavoritesListId)))
        .getSingle();
  }

  /// Añade o quita el canal de la lista. Devuelve si quedó dentro.
  Future<bool> toggleChannelInList(String listId, String channelId) async {
    final inside = await isChannelInList(listId, channelId);
    if (inside) {
      await removeChannelFromList(listId, channelId);
    } else {
      await addChannelToList(listId, channelId);
    }
    return !inside;
  }

  Future<List<Channel>> getChannelsInList(String listId) async {
    final query = select(channels).join([
      innerJoin(favoriteListChannels,
          favoriteListChannels.channelId.equalsExp(channels.id)),
    ])
      ..where(favoriteListChannels.listId.equals(listId))
      ..orderBy([OrderingTerm.asc(favoriteListChannels.sortOrder)]);
    final rows = await query.get();
    return rows.map((row) => row.readTable(channels)).toList();
  }

  Future<void> addChannelToList(String listId, String channelId) =>
      into(favoriteListChannels).insertOnConflictUpdate(
        FavoriteListChannelsCompanion.insert(
          listId: listId,
          channelId: channelId,
        ),
      );

  Future<void> removeChannelFromList(String listId, String channelId) =>
      (delete(favoriteListChannels)
            ..where(
                (t) => t.listId.equals(listId) & t.channelId.equals(channelId)))
          .go();

  Future<FavoriteList> createFavoriteList(String name) async {
    final id = _uuid.v4();
    final count = await (select(favoriteLists)..limit(1000)).get();
    final entry = FavoriteListsCompanion.insert(
      id: id,
      name: name,
      sortOrder: Value(count.length),
    );
    await into(favoriteLists).insert(entry);
    return (select(favoriteLists)..where((t) => t.id.equals(id))).getSingle();
  }

  Future<void> renameFavoriteList(String id, String name) =>
      (update(favoriteLists)..where((t) => t.id.equals(id)))
          .write(FavoriteListsCompanion(name: Value(name)));

  Future<void> deleteFavoriteList(String id) async {
    await (delete(favoriteListChannels)..where((t) => t.listId.equals(id)))
        .go();
    await (delete(favoriteLists)..where((t) => t.id.equals(id))).go();
  }

  Future<bool> isChannelInList(String listId, String channelId) async {
    final row = await (select(favoriteListChannels)
          ..where(
              (t) => t.listId.equals(listId) & t.channelId.equals(channelId)))
        .getSingleOrNull();
    return row != null;
  }

  Future<List<FavoriteList>> getListsForChannel(String channelId) async {
    final query = select(favoriteLists).join([
      innerJoin(favoriteListChannels,
          favoriteListChannels.listId.equalsExp(favoriteLists.id)),
    ])
      ..where(favoriteListChannels.channelId.equals(channelId));
    final rows = await query.get();
    return rows.map((row) => row.readTable(favoriteLists)).toList();
  }

  /// Get all channel IDs that belong to any favorite list.
  Future<Set<String>> getAllFavoritedChannelIds() async {
    final rows = await select(favoriteListChannels).get();
    return rows.map((r) => r.channelId).toSet();
  }

  // --- Reminder queries ---

  Future<void> addReminder(EpgRemindersCompanion entry) =>
      into(epgReminders).insertOnConflictUpdate(entry);

  Future<void> deleteReminder(String id) =>
      (delete(epgReminders)..where((t) => t.id.equals(id))).go();

  Future<List<EpgReminder>> getActiveReminders() =>
      (select(epgReminders)..where((t) => t.fired.equals(false))).get();

  Future<List<EpgReminder>> getRemindersForTimeRange(DateTime start, DateTime end) =>
      (select(epgReminders)
            ..where((t) => t.programmeStart.isBiggerOrEqualValue(start) &
                t.programmeStart.isSmallerOrEqualValue(end)))
          .get();

  Future<void> markReminderFired(String id) =>
      (update(epgReminders)..where((t) => t.id.equals(id)))
          .write(const EpgRemindersCompanion(fired: Value(true)));

  // --- Scheduled Recording queries ---

  Future<void> addScheduledRecording(ScheduledRecordingsCompanion entry) =>
      into(scheduledRecordings).insertOnConflictUpdate(entry);

  Future<void> deleteScheduledRecording(String id) =>
      (delete(scheduledRecordings)..where((t) => t.id.equals(id))).go();

  Future<List<ScheduledRecording>> getAllScheduledRecordings() =>
      select(scheduledRecordings).get();

  Future<List<ScheduledRecording>> getScheduledRecordingsForTimeRange(
          DateTime start, DateTime end) =>
      (select(scheduledRecordings)
            ..where((t) => t.programmeStart.isBiggerOrEqualValue(start) &
                t.programmeStart.isSmallerOrEqualValue(end)))
          .get();

  Future<void> updateRecordingStatus(String id, String status) =>
      (update(scheduledRecordings)..where((t) => t.id.equals(id)))
          .write(ScheduledRecordingsCompanion(status: Value(status)));

  // --- Failover Group queries ---

  Future<List<FailoverGroup>> getAllFailoverGroups() =>
      (select(failoverGroups)..orderBy([(t) => OrderingTerm.asc(t.name)])).get();

  Future<FailoverGroup> createFailoverGroup(String name) async {
    final id = await into(failoverGroups).insert(
      FailoverGroupsCompanion.insert(name: name),
    );
    return (select(failoverGroups)..where((t) => t.id.equals(id))).getSingle();
  }

  Future<void> addChannelsToFailoverGroup(int groupId, List<String> channelIds) async {
    await batch((b) {
      for (var i = 0; i < channelIds.length; i++) {
        b.insert(
          failoverGroupChannels,
          FailoverGroupChannelsCompanion.insert(
            groupId: groupId,
            channelId: channelIds[i],
            priority: Value(i),
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  Future<List<FailoverGroupChannel>> getFailoverGroupMembers(int groupId) =>
      (select(failoverGroupChannels)
            ..where((t) => t.groupId.equals(groupId))
            ..orderBy([(t) => OrderingTerm.asc(t.priority)]))
          .get();

  /// Get all failover group memberships keyed by channel ID for fast lookup.
  Future<Map<String, List<FailoverGroupMembership>>> getFailoverGroupIndex() async {
    final groups = await getAllFailoverGroups();
    final members = await select(failoverGroupChannels).get();
    final groupMap = {for (final g in groups) g.id: g};
    final index = <String, List<FailoverGroupMembership>>{};
    for (final m in members) {
      final group = groupMap[m.groupId];
      if (group == null) continue;
      index.putIfAbsent(m.channelId, () => []).add(
        FailoverGroupMembership(group: group, priority: m.priority),
      );
    }
    return index;
  }

  Future<void> deleteFailoverGroup(int groupId) async {
    await (delete(failoverGroupChannels)..where((t) => t.groupId.equals(groupId))).go();
    await (delete(failoverGroups)..where((t) => t.id.equals(groupId))).go();
  }

  Future<void> renameFailoverGroup(int groupId, String name) =>
      (update(failoverGroups)..where((t) => t.id.equals(groupId)))
          .write(FailoverGroupsCompanion(name: Value(name)));

  Future<void> removeChannelFromFailoverGroup(int groupId, String channelId) =>
      (delete(failoverGroupChannels)
            ..where((t) => t.groupId.equals(groupId) & t.channelId.equals(channelId)))
          .go();
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, 'clubtivi', 'clubtivi.db'));
    await file.parent.create(recursive: true);

    // Migrate from old ~/Documents location if the new DB doesn't exist yet.
    if (!await file.exists()) {
      final oldDir = await getApplicationDocumentsDirectory();
      final oldFile = File(p.join(oldDir.path, 'clubtivi', 'clubtivi.db'));
      if (await oldFile.exists()) {
        await oldFile.copy(file.path);
      }
    }

    return NativeDatabase.createInBackground(file);
  });
}

/// Lightweight struct for failover group membership lookups.
class FailoverGroupMembership {
  final FailoverGroup group;
  final int priority;
  const FailoverGroupMembership({required this.group, required this.priority});
}
