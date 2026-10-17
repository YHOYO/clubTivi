// Un dueño único del estado: la lista de addons decide qué se consulta y en
// qué orden. Nada de esto puede depender de un JSON bien formado.
import 'dart:convert';

import 'package:clubtivi/data/models/stremio_addon.dart';
import 'package:clubtivi/data/services/stremio_addon_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

StremioManifest _manifest(String id, String name, {String version = '1.0.0'}) {
  return StremioManifest(
    id: id,
    name: name,
    version: version,
    types: const ['movie'],
    resources: const ['stream'],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('normaliza la URL pegada por el usuario', () {
    expect(tryNormalizeAddonUrl('torrentio.strem.fun'),
        'https://torrentio.strem.fun');
    expect(tryNormalizeAddonUrl(' https://torrentio.strem.fun/ '),
        'https://torrentio.strem.fun');
    expect(tryNormalizeAddonUrl('https://x.test/manifest.json'),
        'https://x.test');
    expect(tryNormalizeAddonUrl('https://x.test/config/manifest.json'),
        'https://x.test/config');
    expect(tryNormalizeAddonUrl('ftp://x.test'), isNull);
    expect(tryNormalizeAddonUrl('   '), isNull);
  });

  test('guarda el addon y lo recarga en un notifier nuevo', () async {
    final first = StremioAddonSettingsNotifier();
    await first.load();
    expect(first.state.addons, isEmpty);

    await first.save(_manifest('com.stremio.torrentio.addon', 'Torrentio'), 'torrentio.strem.fun');

    final second = StremioAddonSettingsNotifier();
    await second.load();
    expect(second.state.addons, hasLength(1));
    expect(second.state.addons.single.url, 'https://torrentio.strem.fun');
    expect(second.state.addons.single.name, 'Torrentio');
    expect(second.state.addons.single.manifestId, 'com.stremio.torrentio.addon');
    expect(second.state.addons.single.version, '1.0.0');
    expect(second.state.addons.single.enabled, isTrue);
  });

  test('reinstalar la misma URL actualiza el nombre sin duplicar ni mover',
      () async {
    final notifier = StremioAddonSettingsNotifier();
    await notifier.load();
    await notifier.save(_manifest('a', 'Primero'), 'https://a.test');
    await notifier.save(_manifest('b', 'Segundo'), 'https://b.test');
    await notifier.setEnabled('https://a.test', false);

    await notifier.save(_manifest('a', 'Primero v2', version: '2.0.0'), 'https://a.test');

    expect(notifier.state.addons, hasLength(2));
    expect(notifier.state.addons.first.name, 'Primero v2');
    expect(notifier.state.addons.first.version, '2.0.0');
    expect(notifier.state.addons.first.enabled, isFalse,
        reason: 'actualizar no rehabilita lo que el usuario apagó');
    expect(notifier.state.addons.last.name, 'Segundo');
  });

  test('enabledAddons es lo único que se consulta', () async {
    final notifier = StremioAddonSettingsNotifier();
    await notifier.load();
    await notifier.save(_manifest('a', 'A'), 'https://a.test');
    await notifier.save(_manifest('b', 'B'), 'https://b.test');
    await notifier.setEnabled('https://a.test', false);

    expect(notifier.state.count, 2);
    expect(notifier.state.enabledCount, 1);
    expect(notifier.state.enabledAddons.map((a) => a.name), ['B']);
  });

  test('el orden es la prioridad y se puede mover', () async {
    final notifier = StremioAddonSettingsNotifier();
    await notifier.load();
    await notifier.save(_manifest('a', 'A'), 'https://a.test');
    await notifier.save(_manifest('b', 'B'), 'https://b.test');
    await notifier.save(_manifest('c', 'C'), 'https://c.test');
    expect(notifier.state.enabledAddons.map((a) => a.name), ['A', 'B', 'C']);

    await notifier.move(2, 0);
    expect(notifier.state.enabledAddons.map((a) => a.name), ['C', 'A', 'B']);

    await notifier.move(-1, 0);
    await notifier.move(0, 9);
    expect(notifier.state.enabledAddons.map((a) => a.name), ['C', 'A', 'B'],
        reason: 'los índices fuera de rango se ignoran');

    final reloaded = StremioAddonSettingsNotifier();
    await reloaded.load();
    expect(reloaded.state.enabledAddons.map((a) => a.name), ['C', 'A', 'B']);
  });

  test('borrar quita el addon de la lista y del almacenamiento', () async {
    final notifier = StremioAddonSettingsNotifier();
    await notifier.load();
    await notifier.save(_manifest('a', 'A'), 'https://a.test');
    await notifier.save(_manifest('b', 'B'), 'https://b.test');

    await notifier.remove('https://a.test');

    final reloaded = StremioAddonSettingsNotifier();
    await reloaded.load();
    expect(reloaded.state.addons.map((a) => a.name), ['B']);
  });

  test('un JSON corrupto deja la lista vacía sin romper nada', () async {
    SharedPreferences.setMockInitialValues({stremioAddonsKey: '{no json'});

    final notifier = StremioAddonSettingsNotifier();
    await notifier.load();

    expect(notifier.state.addons, isEmpty);
    expect(notifier.state.hasEnabledAddons, isFalse);
  });

  test('las entradas ilegibles y los duplicados se descartan al leer',
      () async {
    SharedPreferences.setMockInitialValues({
      stremioAddonsKey: jsonEncode({
        'version': 1,
        'addons': [
          {'url': 'https://a.test', 'name': 'A', 'manifestId': 'a', 'enabled': true},
          {'url': 'ftp://roto.test', 'name': 'Roto', 'manifestId': 'r'},
          {'name': 'Sin URL'},
          'basura',
          {'url': 'https://a.test/', 'name': 'A repetido', 'manifestId': 'a2'},
          {'url': 'https://b.test', 'name': 'B', 'manifestId': 'b', 'enabled': false},
        ],
      }),
    });

    final notifier = StremioAddonSettingsNotifier();
    await notifier.load();

    expect(notifier.state.addons.map((a) => a.name), ['A', 'B']);
    expect(notifier.state.addons.last.enabled, isFalse);
  });

  test('los catálogos y su estado de configuración sobreviven al reinicio',
      () async {
    const manifest = StremioManifest(
      id: 'community.anime.kitsu',
      name: 'Anime Kitsu',
      version: '0.0.10',
      types: ['anime'],
      resources: ['catalog', 'meta'],
      catalogs: [
        StremioCatalog(
          type: 'anime',
          id: 'kitsu-anime-top',
          name: 'Kitsu Top',
          extra: [
            StremioCatalogExtra(
              name: 'genre',
              isRequired: true,
              options: ['Action'],
            ),
          ],
        ),
        StremioCatalog(
          type: 'anime',
          id: 'kitsu-anime-list',
          extra: [StremioCatalogExtra(name: 'search', isRequired: true)],
        ),
      ],
      configurable: true,
      configurationRequired: true,
    );
    final notifier = StremioAddonSettingsNotifier();
    await notifier.load();
    await notifier.save(manifest, 'anime-kitsu.strem.fun');

    final reloaded = StremioAddonSettingsNotifier();
    await reloaded.load();
    final addon = reloaded.state.addons.single;

    expect(addon.catalogs.map((c) => c.id),
        ['kitsu-anime-top', 'kitsu-anime-list']);
    expect(addon.browsableCatalogs.map((c) => c.id), ['kitsu-anime-top'],
        reason: 'el catálogo de sólo búsqueda no se pinta como fila');
    expect(addon.catalogs.first.genreExtra?.options, ['Action']);
    expect(addon.types, ['anime']);
    expect(addon.configurable, isTrue);
    expect(addon.configurationRequired, isTrue);
    expect(addon.supportsStreams, isFalse,
        reason: 'un addon de sólo catálogo no se consulta al reproducir');
  });

  test('una entrada antigua sin catálogos sigue cargando', () async {
    SharedPreferences.setMockInitialValues({
      stremioAddonsKey: jsonEncode({
        'version': 1,
        'addons': [
          {'url': 'https://a.test', 'name': 'A', 'manifestId': 'a'},
        ],
      }),
    });

    final notifier = StremioAddonSettingsNotifier();
    await notifier.load();

    expect(notifier.state.addons, hasLength(1));
    expect(notifier.state.addons.single.hasCatalogs, isFalse);
  });

  test('un manifest sin stream ni catálogo no llega a guardarse desde la UI', () {
    // La validación vive en StremioManifest: aquí se fija que el error explica
    // el motivo, que es lo que la pantalla muestra al usuario.
    expect(
      () => StremioManifest.fromJson(const {
        'id': 'org.stremio.opensubtitlesv3',
        'name': 'OpenSubtitles v3',
        'version': '1.0.0',
        'types': ['movie'],
        'resources': ['subtitles'],
      }),
      throwsA(
        isA<StremioAddonException>().having(
          (e) => e.message,
          'message',
          contains('no ofrece streams'),
        ),
      ),
    );
  });
}
