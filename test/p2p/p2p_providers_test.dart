// El provider es el punto donde los ajustes guardados se convierten en el
// motor real: si esa unión se rompe, la pantalla guardaría valores que nadie
// aplica.
import 'dart:convert';
import 'dart:io';

import 'package:clubtivi/data/services/p2p/p2p_providers.dart';
import 'package:clubtivi/data/services/p2p/p2p_settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory base;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    base = await Directory.systemTemp.createTemp('p2p-providers-');
  });

  tearDown(() async {
    if (await base.exists()) await base.delete(recursive: true);
  });

  Future<ProviderContainer> containerWith(P2pSettingsNotifier settings) async {
    await settings.load();
    final container = ProviderContainer(
      overrides: [
        p2pSettingsProvider.overrideWith((ref) => settings),
        p2pBaseDirectoryProvider.overrideWith((ref) async => base),
        p2pDefaultDownloadDirectoryProvider
            .overrideWith((ref) async => 'C:/default/clubTivi'),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }  test('sin ajustes el motor usa la carpeta por defecto y puerto automático',
      () async {
    final container = await containerWith(P2pSettingsNotifier());

    final engine = await container.read(rqbitEngineProvider.future);

    expect(engine.downloadDirectory, 'C:/default/clubTivi');
    expect(engine.supervisor.preferredPort, isNull);
    expect(engine.supervisor.downloadLimitBytesPerSecond, isNull);
    expect(engine.supervisor.uploadLimitBytesPerSecond, isNull);
    expect(engine.sessionDirectory, contains('session'));
    await engine.dispose();
  });

  test('los ajustes guardados llegan al supervisor en sus unidades', () async {
    SharedPreferences.setMockInitialValues({
      p2pSettingsKey: jsonEncode(
        const P2pSettings(
          downloadDirectory: 'D:/Media',
          port: 33123,
          downloadLimitKbps: 512,
          uploadLimitKbps: 64,
        ).toJson(),
      ),
    });
    final settings = P2pSettingsNotifier();
    final container = await containerWith(settings);

    final engine = await container.read(rqbitEngineProvider.future);

    expect(engine.downloadDirectory, 'D:/Media');
    expect(engine.supervisor.preferredPort, 33123);
    expect(engine.supervisor.downloadLimitBytesPerSecond, 512 * 1024);
    expect(engine.supervisor.uploadLimitBytesPerSecond, 64 * 1024);
    await engine.dispose();
  });
}
