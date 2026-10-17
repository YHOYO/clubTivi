// Los ajustes del motor son la única fuente del puerto, la carpeta y los
// límites: un valor inválido guardado no puede dejar el motor sin arrancar.
import 'dart:convert';

import 'package:clubtivi/data/services/p2p/p2p_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('modelo', () {
    test('por defecto: sin carpeta, puerto automático y sin límites', () {
      const settings = P2pSettings.defaults;

      expect(settings.downloadDirectory, isNull);
      expect(settings.port, isNull);
      expect(settings.downloadLimitKbps, 0);
      expect(settings.uploadLimitKbps, 0);
      expect(settings.downloadLimitBytesPerSecond, isNull);
      expect(settings.uploadLimitBytesPerSecond, isNull);
      expect(settings.hasCustomDownloadDirectory, isFalse);
      expect(settings.hasLimits, isFalse);
    });

    test('los límites se convierten a bytes por segundo', () {
      const settings = P2pSettings(downloadLimitKbps: 512, uploadLimitKbps: 64);

      expect(settings.downloadLimitBytesPerSecond, 512 * 1024);
      expect(settings.uploadLimitBytesPerSecond, 64 * 1024);
      expect(settings.hasLimits, isTrue);
    });

    test('serializa y recupera los valores tal cual', () {
      const settings = P2pSettings(
        downloadDirectory: 'D:/Media',
        port: 3030,
        downloadLimitKbps: 1024,
        uploadLimitKbps: 128,
      );

      expect(P2pSettings.fromJson(settings.toJson()), settings);
    });

    test('un JSON corrupto degrada campo a campo, no revienta', () {
      final settings = P2pSettings.fromJson({
        'download_directory': '   ',
        'port': 80,
        'download_limit_kbps': -5,
        'upload_limit_kbps': '2048',
      });

      expect(settings.downloadDirectory, isNull);
      expect(settings.port, isNull, reason: 'por debajo del rango permitido');
      expect(settings.downloadLimitKbps, 0);
      expect(settings.uploadLimitKbps, 2048,
          reason: 'un string numérico sí se acepta');

      expect(P2pSettings.fromJson('nonsense'), P2pSettings.defaults);
      expect(
        P2pSettings.fromJson({'port': 70000}).port,
        isNull,
        reason: 'por encima del rango permitido',
      );
    });

    test('copyWith puede volver a null el puerto y la carpeta', () {
      const settings = P2pSettings(downloadDirectory: 'D:/Media', port: 3030);

      final cleared = settings.copyWith(downloadDirectory: null, port: null);
      expect(cleared.downloadDirectory, isNull);
      expect(cleared.port, isNull);
      expect(cleared, isNot(settings));

      // Omitir los campos conserva los valores (el cambio de límites no debe
      // borrar el puerto).
      final limited = settings.copyWith(downloadLimitKbps: 100);
      expect(limited.port, 3030);
      expect(limited.downloadDirectory, 'D:/Media');
    });

    test('dos ajustes con los mismos valores son iguales', () {
      const a = P2pSettings(downloadDirectory: 'D:/Media', port: 3030);
      const b = P2pSettings(downloadDirectory: 'D:/Media', port: 3030);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('persistencia', () {
    test('save guarda y load recupera', () async {
      final notifier = P2pSettingsNotifier();
      await notifier.load();
      expect(notifier.state, P2pSettings.defaults);

      await notifier.save(const P2pSettings(
        downloadDirectory: 'D:/Media',
        port: 3030,
        downloadLimitKbps: 512,
      ));

      final raw = (await SharedPreferences.getInstance())
          .getString(p2pSettingsKey);
      expect(raw, isNotNull);
      expect(
        P2pSettings.fromJson(jsonDecode(raw!)),
        const P2pSettings(
          downloadDirectory: 'D:/Media',
          port: 3030,
          downloadLimitKbps: 512,
        ),
      );

      final reloaded = P2pSettingsNotifier();
      await reloaded.load();
      expect(reloaded.state, notifier.state);
    });

    test('un puerto fuera de rango se guarda como automático', () async {
      final notifier = P2pSettingsNotifier();

      await notifier.setPort(80);
      expect(notifier.state.port, isNull);

      await notifier.setPort(3030);
      expect(notifier.state.port, 3030);

      await notifier.setPort(null);
      expect(notifier.state.port, isNull);
    });

    test('límites negativos se guardan como sin límite', () async {
      final notifier = P2pSettingsNotifier();

      await notifier.setLimits(downloadKbps: -1, uploadKbps: 256);
      expect(notifier.state.downloadLimitKbps, 0);
      expect(notifier.state.uploadLimitKbps, 256);

      await notifier.setLimits(downloadKbps: 0);
      expect(notifier.state.uploadLimitKbps, 256,
          reason: 'omitir un límite no borra el otro');
    });

    test('la carpeta vacía vuelve a la predeterminada', () async {
      final notifier = P2pSettingsNotifier();

      await notifier.setDownloadDirectory('D:/Media');
      expect(notifier.state.downloadDirectory, 'D:/Media');

      await notifier.setDownloadDirectory('   ');
      expect(notifier.state.downloadDirectory, isNull);
    });

    test('reset vuelve a los valores por defecto', () async {
      final notifier = P2pSettingsNotifier();
      await notifier.save(const P2pSettings(
        downloadDirectory: 'D:/Media',
        port: 3030,
        downloadLimitKbps: 10,
      ));

      await notifier.reset();

      expect(notifier.state, P2pSettings.defaults);
      final raw = (await SharedPreferences.getInstance())
          .getString(p2pSettingsKey);
      expect(P2pSettings.fromJson(jsonDecode(raw!)), P2pSettings.defaults);
    });
  });
}
