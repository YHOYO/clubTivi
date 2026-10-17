// Las filas de descubrimiento son una vista de los catálogos: un catálogo de
// sólo búsqueda no se ofrece, un género obligatorio se rellena y un addon
// caído se queda en su fila con el motivo, sin tumbar las demás.
import 'package:clubtivi/data/datasources/remote/stremio_addon_client.dart';
import 'package:clubtivi/data/models/stremio_addon.dart';
import 'package:clubtivi/data/services/stremio_addon_settings.dart';
import 'package:clubtivi/features/shows/shows_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeClient extends StremioAddonClient {
  _FakeClient({this.failing});

  final String? failing;
  final List<String> requested = [];

  @override
  Future<List<StremioMeta>> fetchCatalog({
    required InstalledAddon addon,
    required StremioCatalog catalog,
    String? genre,
    int skip = 0,
    String? search,
  }) async {
    requested.add('${catalog.id}|${genre ?? ''}');
    if (catalog.id == failing) {
      throw const StremioAddonException('El addon respondió HTTP 500');
    }
    return [
      StremioMeta(
        id: '${catalog.id}:1',
        type: catalog.type,
        name: 'Title ${catalog.id}',
        poster: 'https://img.test/${catalog.id}.jpg',
      ),
    ];
  }
}

const _manifest = StremioManifest(
  id: 'community.anime.kitsu',
  name: 'Anime Kitsu',
  version: '0.0.10',
  types: ['anime'],
  resources: ['catalog', 'meta'],
  catalogs: [
    StremioCatalog(type: 'anime', id: 'trending', name: 'Trending'),
    StremioCatalog(
      type: 'anime',
      id: 'genres',
      name: 'By genre',
      extra: [
        StremioCatalogExtra(
          name: 'genre',
          isRequired: true,
          options: ['Action', 'Comedy'],
        ),
      ],
    ),
    StremioCatalog(
      type: 'anime',
      id: 'search',
      name: 'Search',
      extra: [StremioCatalogExtra(name: 'search', isRequired: true)],
    ),
  ],
);

Future<ProviderContainer> _container(
  _FakeClient client, {
  bool enabled = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  final notifier = StremioAddonSettingsNotifier();
  await notifier.load();
  await notifier.save(_manifest, 'https://anime-kitsu.strem.fun');
  if (!enabled) {
    await notifier.setEnabled('https://anime-kitsu.strem.fun', false);
  }
  final container = ProviderContainer(overrides: [
    stremioAddonClientProvider.overrideWithValue(client),
    stremioAddonSettingsProvider.overrideWith((ref) => notifier),
  ]);
  addTearDown(container.dispose);
  return container;
}

AddonCatalogParams _params(AddonCatalogSpec spec, {String? genre}) =>
    AddonCatalogParams(
      addonUrl: spec.addon.url,
      catalogType: spec.catalog.type,
      catalogId: spec.catalog.id,
      genre: genre ?? spec.defaultGenre,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ofrece una fila por catálogo navegable y salta los de búsqueda',
      () async {
    final container = await _container(_FakeClient());

    final specs = container.read(stremioCatalogSpecsProvider);

    expect(specs.map((s) => s.title), ['Trending', 'By genre']);
    expect(specs.last.defaultGenre, 'Action',
        reason: 'un género obligatorio abre con su primera opción');
    expect(specs.first.defaultGenre, isNull);
  });

  test('la fila se pide con su género y se puede cambiar', () async {
    final client = _FakeClient();
    final container = await _container(client);
    final spec = container.read(stremioCatalogSpecsProvider).last;

    final row = await container.read(
      addonCatalogRowProvider(_params(spec)).future,
    );
    expect(row.metas.single.name, 'Title genres');

    final comedy = await container.read(
      addonCatalogRowProvider(_params(spec, genre: 'Comedy')).future,
    );
    expect(comedy.metas, hasLength(1));
    expect(client.requested, ['genres|Action', 'genres|Comedy']);
  });

  test('un catálogo caído se explica en su fila', () async {
    final client = _FakeClient(failing: 'trending');
    final container = await _container(client);
    final spec = container.read(stremioCatalogSpecsProvider).first;

    final row = await container.read(
      addonCatalogRowProvider(_params(spec)).future,
    );

    expect(row.hasError, isTrue);
    expect(row.error, contains('HTTP 500'));
  });

  test('los addons deshabilitados no se consultan', () async {
    final client = _FakeClient();
    final container = await _container(client, enabled: false);

    expect(container.read(stremioCatalogSpecsProvider), isEmpty);
    expect(client.requested, isEmpty);
  });

  test('sin addons con catálogos no hay filas', () async {
    SharedPreferences.setMockInitialValues({});
    final notifier = StremioAddonSettingsNotifier();
    await notifier.load();
    final container = ProviderContainer(overrides: [
      stremioAddonClientProvider.overrideWithValue(_FakeClient()),
      stremioAddonSettingsProvider.overrideWith((ref) => notifier),
    ]);
    addTearDown(container.dispose);

    expect(container.read(stremioCatalogSpecsProvider), isEmpty);
  });
}
