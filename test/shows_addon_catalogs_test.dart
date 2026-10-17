// La pestaña "From addons" es la puerta al contenido de AnimeFLV/Kitsu: sin
// claves de Trakt ni TMDB debe seguir habiendo algo que ver, y tocar una
// carátula tiene que abrir la ficha del addon.
import 'package:clubtivi/data/datasources/remote/stremio_addon_client.dart';
import 'package:clubtivi/data/models/stremio_addon.dart';
import 'package:clubtivi/data/services/stremio_addon_settings.dart';
import 'package:clubtivi/features/shows/shows_providers.dart';
import 'package:clubtivi/features/shows/shows_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeClient extends StremioAddonClient {
  final List<String> requested = [];

  @override
  Future<List<StremioMeta>> fetchCatalog({
    required InstalledAddon addon,
    required StremioCatalog catalog,
    String? genre,
    int skip = 0,
    String? search,
  }) async {
    requested.add(catalog.id);
    return const [
      StremioMeta(
        id: 'kitsu:7442',
        type: 'series',
        name: 'Attack on Titan',
        poster: 'https://img.test/aot.jpg',
        releaseInfo: '2013',
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
    StremioCatalog(type: 'anime', id: 'trending', name: 'Kitsu Trending'),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sin claves de Trakt/TMDB, los catálogos de addons se ven',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final client = _FakeClient();
    final keys = ShowsApiKeysNotifier();
    await keys.load();
    final settings = StremioAddonSettingsNotifier();
    await settings.load();
    await settings.save(_manifest, 'https://anime-kitsu.strem.fun');

    final router = GoRouter(
      initialLocation: '/shows',
      routes: [
        GoRoute(path: '/shows', builder: (_, _) => const ShowsScreen()),
        GoRoute(
          path: '/stremio-meta',
          builder: (_, _) => const Scaffold(body: Text('META')),
        ),
        GoRoute(
          path: '/stremio-addons',
          builder: (_, _) => const Scaffold(body: Text('ADDONS')),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          showsApiKeysProvider.overrideWith((ref) => keys),
          stremioAddonSettingsProvider.overrideWith((ref) => settings),
          stremioAddonClientProvider.overrideWithValue(client),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('From addons'));
    await tester.pumpAndSettle();

    expect(find.text('Kitsu Trending'), findsOneWidget);
    expect(find.text('Anime Kitsu'), findsOneWidget);
    expect(find.text('Attack on Titan'), findsOneWidget);
    expect(client.requested, ['trending']);

    await tester.tap(find.text('Attack on Titan'));
    await tester.pumpAndSettle();

    expect(find.text('META'), findsOneWidget);
  });

  testWidgets('sin addons, la pestaña explica cómo instalarlos',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final keys = ShowsApiKeysNotifier();
    await keys.load();
    final settings = StremioAddonSettingsNotifier();
    await settings.load();

    final router = GoRouter(
      initialLocation: '/shows',
      routes: [
        GoRoute(path: '/shows', builder: (_, _) => const ShowsScreen()),
        GoRoute(
          path: '/stremio-addons',
          builder: (_, _) => const Scaffold(body: Text('ADDONS')),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          showsApiKeysProvider.overrideWith((ref) => keys),
          stremioAddonSettingsProvider.overrideWith((ref) => settings),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    // Sin claves ni addons la pantalla explica las dos vías y ofrece addons.
    expect(find.textContaining('Add a Trakt or TMDB API key'), findsOneWidget);
    expect(find.text('Install Stremio addons'), findsOneWidget);
  });
}
