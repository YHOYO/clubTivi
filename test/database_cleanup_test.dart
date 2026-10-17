// Qué pasa con los canales cuando cambian los proveedores: borrar un proveedor
// debe llevarse sus canales (antes quedaban huérfanos en la lista) y los
// canales marcados como ocultos no deben aparecer en las consultas que pinta la
// interfaz.
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late db.AppDatabase database;

  setUp(() {
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await database.close();
  });

  Future<void> addProvider(String id) => database.upsertProvider(
        db.ProvidersCompanion.insert(id: id, name: id, type: 'm3u'),
      );

  Future<void> addChannel(
    String id,
    String providerId, {
    String? group,
    bool hidden = false,
    bool favorite = false,
  }) =>
      database.upsertChannels([
        db.ChannelsCompanion.insert(
          id: id,
          providerId: providerId,
          name: id,
          streamUrl: 'http://example.com/$id.m3u8',
          groupTitle: Value(group),
          hidden: Value(hidden),
          favorite: Value(favorite),
        ),
      ]);

  group('hidden channels stay out of the listings', () {
    setUp(() async {
      await addProvider('p1');
      await addChannel('visible', 'p1', group: 'News');
      await addChannel('dupe', 'p1', group: 'News', hidden: true);
      await addChannel('other', 'p1', group: 'Sports');
    });

    test('getChannelsForProvider skips hidden rows but can include them',
        () async {
      final shown = await database.getChannelsForProvider('p1');
      expect(shown.map((c) => c.id), unorderedEquals(['visible', 'other']));

      final all = await database.getChannelsForProvider('p1', includeHidden: true);
      expect(all, hasLength(3));
    });

    test('getVisibleChannels returns only what the user should see', () async {
      final visible = await database.getVisibleChannels();
      expect(visible.map((c) => c.id), unorderedEquals(['visible', 'other']));
    });

    test('a group is not offered in the sidebar if it is all hidden', () async {
      await addChannel('dupe2', 'p1', group: 'Hidden group', hidden: true);
      final groups = await database.getProviderGroups();
      expect(groups['p1'], isNot(contains('Hidden group')));
      expect(groups['p1'], contains('News'));
    });

    test('setChannelsHidden takes them out and puts them back', () async {
      await database.setChannelsHidden({'visible'}, hidden: true);
      expect((await database.getChannelsForProvider('p1')).map((c) => c.id),
          unorderedEquals(['other']));

      await database.setChannelsHidden({'visible'}, hidden: false);
      expect(
          (await database.getChannelsForProvider('p1')).map((c) => c.id),
          unorderedEquals(['visible', 'other']));
    });
  });

  group('deleting a provider', () {
    test('removes its channels, mappings and list membership', () async {
      await addProvider('p1');
      await addProvider('p2');
      await addChannel('a', 'p1');
      await addChannel('b', 'p1');
      await addChannel('keep', 'p2');

      await database.upsertEpgSource(db.EpgSourcesCompanion.insert(
        id: 'src1',
        name: 'Guide',
        url: 'http://example.com/epg.xml',
      ));
      await database.upsertMapping(db.EpgMappingsCompanion.insert(
        channelId: 'a',
        providerId: 'p1',
        epgChannelId: 'A.tv',
        epgSourceId: 'src1',
      ));

      final list = await database.createFavoriteList('Favoritos');
      await database.addChannelToList(list.id, 'a');

      final group = await database.createFailoverGroup('Alternativas');
      await database.addChannelsToFailoverGroup(group.id, ['a', 'b']);

      await database.deleteProvider('p1');

      expect(await database.getAllProviders(), hasLength(1));
      expect((await database.getAllChannels()).map((c) => c.id), ['keep']);
      expect(await database.getAllMappings(), isEmpty);
      expect(await database.getChannelsInList(list.id), isEmpty);
      expect(await database.getFailoverGroupMembers(group.id), isEmpty);
    });

    test('takes the guide the playlist brought with it', () async {
      await addProvider('p1');
      await addChannel('a', 'p1');
      final sourceId = 'p1-playlist-epg';
      await database.upsertEpgSource(db.EpgSourcesCompanion.insert(
        id: sourceId,
        name: 'playlist guide',
        url: 'http://example.com/epg.xml',
      ));
      await database.upsertEpgChannels([
        db.EpgChannelsCompanion.insert(
          id: '${sourceId}_A.tv',
          sourceId: sourceId,
          channelId: 'A.tv',
          displayName: 'A',
        ),
      ]);
      await database.insertProgrammes([
        db.EpgProgrammesCompanion.insert(
          epgChannelId: '${sourceId}_A.tv',
          sourceId: sourceId,
          title: 'Noticias',
          start: DateTime(2026, 1, 1, 20),
          stop: DateTime(2026, 1, 1, 21),
        ),
      ]);

      await database.deleteProvider('p1');

      expect(await database.getAllEpgSources(), isEmpty);
      expect(await database.getEpgChannelsForSource(sourceId), isEmpty);
      expect(
        await database.getProgrammes(
          epgChannelId: '${sourceId}_A.tv',
          start: DateTime(2026, 1, 1),
          end: DateTime(2026, 1, 2),
        ),
        isEmpty,
      );
    });
  });

  test('channels left behind by older versions are purged', () async {
    await addProvider('p1');
    await addChannel('linked', 'p1');
    // Como quedaban las bases antiguas: el canal sigue, el proveedor no.
    await addChannel('orphan', 'gone-provider');

    final removed = await database.purgeOrphanChannels();

    expect(removed, 1);
    expect((await database.getAllChannels()).map((c) => c.id), ['linked']);
  });
}
