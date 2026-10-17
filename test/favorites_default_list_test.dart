// La lista fija de favoritos: la estrella de cada fila añade y quita de aquí,
// así que tiene que existir siempre (una sola vez) y alternar sin repetir.
import 'package:clubtivi/data/datasources/local/database.dart' as db;
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

  Future<void> addChannel(String id) async {
    await database.upsertProvider(
      db.ProvidersCompanion.insert(id: 'p1', name: 'p1', type: 'm3u'),
    );
    await database.upsertChannels([
      db.ChannelsCompanion.insert(
        id: id,
        providerId: 'p1',
        name: id,
        streamUrl: 'http://example.com/$id.m3u8',
      ),
    ]);
  }

  test('la lista fija se crea una vez y va la primera', () async {
    final first = await database.ensureDefaultFavoriteList();
    final second = await database.ensureDefaultFavoriteList();

    expect(first.id, db.AppDatabase.defaultFavoritesListId);
    expect(second.id, first.id, reason: 'crear dos veces no duplica nada');
    expect(second.name, 'Favorites');

    await database.createFavoriteList('Sports');
    final lists = await database.getAllFavoriteLists();
    expect(
        lists.map((l) => l.name),
        [
          'Favorites',
          'Sports',
        ],
        reason: 'la lista fija encabeza la barra lateral');
  });

  test('la estrella alterna la pertenencia a la lista fija', () async {
    await addChannel('a');
    await addChannel('b');
    final list = await database.ensureDefaultFavoriteList();

    expect(await database.toggleChannelInList(list.id, 'a'), isTrue);
    expect(await database.getAllFavoritedChannelIds(), {'a'});

    expect(await database.toggleChannelInList(list.id, 'a'), isFalse);
    expect(await database.getAllFavoritedChannelIds(), isEmpty);

    await database.addChannelToList(list.id, 'b');
    expect(
        (await database.getChannelsInList(list.id)).map((c) => c.id),
        [
          'b',
        ],
        reason: 'la vista de la lista enseña sus canales');
  });

  test(
    '«All Favorites» es estar en cualquier lista, no sólo en la fija',
    () async {
      await addChannel('a');
      await addChannel('b');
      final fixed = await database.ensureDefaultFavoriteList();
      final named = await database.createFavoriteList('Sports');

      await database.addChannelToList(fixed.id, 'a');
      await database.addChannelToList(named.id, 'b');

      expect(await database.getAllFavoritedChannelIds(), {'a', 'b'});
      expect(
          (await database.getChannelsInList(fixed.id)).map((c) => c.id),
          [
            'a',
          ],
          reason: 'la lista fija enseña sólo lo que se marcó con la estrella');
    },
  );
}
