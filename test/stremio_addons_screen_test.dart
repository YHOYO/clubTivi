// La pantalla de addons es donde el usuario pega la URL: debe validar antes de
// aceptarla, explicar el error si no es un addon y dejar gestionar la lista.
import 'package:clubtivi/data/datasources/remote/stremio_addon_client.dart';
import 'package:clubtivi/data/models/stremio_addon.dart';
import 'package:clubtivi/data/services/stremio_addon_settings.dart';
import 'package:clubtivi/features/settings/stremio_addons_screen.dart';
import 'package:clubtivi/features/shows/shows_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _manifest = StremioManifest(
  id: 'com.stremio.torrentio.addon',
  name: 'Torrentio',
  version: '0.0.15',
  types: ['movie', 'series'],
  resources: ['stream'],
);

class _FakeClient extends StremioAddonClient {
  _FakeClient({this.error});

  final StremioAddonException? error;
  final List<String> requested = [];

  @override
  Future<StremioManifest> fetchManifest(String addonUrl) async {
    requested.add(addonUrl);
    if (error != null) throw error!;
    return _manifest;
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pump(WidgetTester tester, _FakeClient client) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [stremioAddonClientProvider.overrideWithValue(client)],
        child: const MaterialApp(home: StremioAddonsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('validar e instalar deja el addon en la lista', (tester) async {
    final client = _FakeClient();
    await pump(tester, client);

    expect(find.textContaining('No addons installed'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'torrentio.strem.fun');
    await tester.tap(find.text('Install addon'));
    await tester.pumpAndSettle();

    expect(client.requested, ['torrentio.strem.fun']);
    expect(find.text('Torrentio'), findsOneWidget);
    expect(find.textContaining('#1'), findsOneWidget);
    expect(find.textContaining('1 of 1 enabled'), findsOneWidget);

    final store = await SharedPreferences.getInstance();
    expect(store.getString('shows_stremio_addons'), contains('torrentio.strem.fun'));
  });

  testWidgets('una URL que no es un addon explica el motivo y no guarda nada',
      (tester) async {
    final client = _FakeClient(
      error: const StremioAddonException(
        'El addon "OpenSubtitles v3" no ofrece streams (recursos: subtitles).',
      ),
    );
    await pump(tester, client);

    await tester.enterText(find.byType(TextField), 'https://opensubtitles.test');
    await tester.tap(find.text('Install addon'));
    await tester.pumpAndSettle();

    expect(find.textContaining('no ofrece streams'), findsOneWidget);
    expect(find.textContaining('No addons installed'), findsOneWidget);

    final store = await SharedPreferences.getInstance();
    expect(store.getString('shows_stremio_addons'), isNull);
  });

  testWidgets('desactivar un addon lo saca de la consulta sin borrarlo',
      (tester) async {
    final client = _FakeClient();
    await pump(tester, client);

    await tester.enterText(find.byType(TextField), 'torrentio.strem.fun');
    await tester.tap(find.text('Install addon'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(find.textContaining('1 installed • all disabled'), findsOneWidget);
    expect(find.text('Torrentio'), findsOneWidget);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(StremioAddonsScreen)),
    );
    expect(
      container.read(stremioAddonSettingsProvider).enabledAddons,
      isEmpty,
      reason: 'un addon deshabilitado no se consulta',
    );
    expect(container.read(stremioAddonSettingsProvider).count, 1);
  });

  testWidgets('quitar un addon pide confirmación antes de borrarlo',
      (tester) async {
    final client = _FakeClient();
    await pump(tester, client);

    await tester.enterText(find.byType(TextField), 'torrentio.strem.fun');
    await tester.tap(find.text('Install addon'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.text('Quitar addon'), findsOneWidget);

    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(find.text('Torrentio'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quitar'));
    await tester.pumpAndSettle();

    expect(find.textContaining('No addons installed'), findsOneWidget);
  });
}
