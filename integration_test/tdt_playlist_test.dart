// Verificación EXTREMO A EXTREMO con una lista M3U real (p. ej. la de
// TDTChannels, `tv.m3u8`), pasando por el mismo camino que usa la app:
// descarga HTTP → M3uParser → SQLite (ProviderManager) → reproductor (mpv).
//
// El fichero da igual en qué carpeta esté: el test lo lee del disco y lo sirve
// por loopback, que es lo único que la app acepta (el diálogo de proveedores
// valida que la URL empiece por http y ProviderManager lo descarga con Dio).
//
//   flutter test integration_test/tdt_playlist_test.dart -d windows \
//     --dart-define=M3U_PATH="C:\Users\Usuario\Downloads\tv.m3u8"
//
// Sin --dart-define usa la ruta por defecto de abajo.

import 'dart:io';

import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/features/player/player_service.dart';
import 'package:clubtivi/features/providers/provider_manager.dart';
import 'package:drift/drift.dart' show countAll;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

const String kM3uPath = String.fromEnvironment(
  'M3U_PATH',
  defaultValue: r'C:\Users\Usuario\Downloads\tv.m3u8',
);

/// Una entrada del fichero tal cual: URL + nombre de la línea #EXTINF anterior
/// y las directivas #EXTVLCOPT que la preceden, por nombre (`http-referrer`…).
class Entry {
  final String name;
  final String url;
  final Map<String, String> vlcOpts;
  const Entry(this.name, this.url, [this.vlcOpts = const {}]);

  /// Cabeceras HTTP que el reproductor debe enviar, al estilo de mpv.
  Map<String, String> get httpHeaders => <String, String>{
        if (vlcOpts['http-referrer'] != null) 'Referer': vlcOpts['http-referrer']!,
        if (vlcOpts['http-user-agent'] != null)
          'User-Agent': vlcOpts['http-user-agent']!,
      };

  bool get needsHeaders => httpHeaders.isNotEmpty;
}

List<Entry> readEntries(String content) {
  final entries = <Entry>[];
  String? pendingName;
  final pendingOpts = <String, String>{};
  for (final raw in content.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.startsWith('#EXTINF:')) {
      pendingName = line.substring(line.lastIndexOf(',') + 1).trim();
      pendingOpts.clear();
    } else if (line.startsWith('#EXTVLCOPT:')) {
      final directive = line.substring('#EXTVLCOPT:'.length);
      final separator = directive.indexOf('=');
      if (separator > 0) {
        pendingOpts[directive.substring(0, separator).trim().toLowerCase()] =
            directive.substring(separator + 1).trim();
      }
    } else if (line.isNotEmpty && !line.startsWith('#')) {
      entries.add(Entry(pendingName ?? '', line, Map.of(pendingOpts)));
    }
  }
  return entries;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(MediaKit.ensureInitialized);

  late String playlist;
  late List<Entry> entries;
  late HttpServer server;
  late String playlistUrl;

  setUpAll(() async {
    final file = File(kM3uPath);
    if (!file.existsSync()) {
      fail('No se encuentra la lista en $kM3uPath');
    }
    playlist = file.readAsStringSync();
    entries = readEntries(playlist);

    // La app sólo carga M3U por HTTP, así que aquí se sirve el fichero local.
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    playlistUrl = 'http://127.0.0.1:${server.port}/tv.m3u8';
    server.listen((request) {
      request.response
        ..headers.contentType = ContentType('application', 'vnd.apple.mpegurl')
        ..write(playlist)
        ..close();
    });
    // ignore: avoid_print
    print('[verify] lista real servida en $playlistUrl '
        '(${entries.length} entradas, ${(playlist.length / 1024).toStringAsFixed(0)} KB)');
  });

  tearDownAll(() => server.close(force: true));

  testWidgets('M3U real: la app descarga, parsea y guarda la lista',
      (tester) async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);

    final manager = ProviderManager(database);
    await manager.addM3uProvider(
      id: 'tdt-real',
      name: 'TDTChannels',
      url: playlistUrl,
    );

    final channels = await database.getAllChannels();
    final groups = await database.getProviderGroups();
    final stored = channels.map((c) => c.streamUrl).toSet();

    // ignore: avoid_print
    print('[verify] guardados ${channels.length} canales '
        'de ${entries.length} entradas del fichero · '
        '${groups['tdt-real']?.length ?? 0} grupos');

    expect(channels, isNotEmpty,
        reason: 'la app debe cargar la lista real por HTTP');
    expect(channels.length, greaterThan(400));
    expect(groups['tdt-real'], isNotNull);
    expect((groups['tdt-real'] ?? []).length, greaterThan(10));

    // Diagnóstico: entradas del fichero cuyo URL no llegó a la base de datos.
    final missing = entries.where((e) => !stored.contains(e.url)).toList();
    final byId = <String, List<Entry>>{};
    for (final e in entries) {
      byId.putIfAbsent(e.name, () => []).add(e);
    }
    final multi = byId.values.where((v) => v.length > 1).toList();
    // ignore: avoid_print
    print('[verify] entradas con varios URL (failover): ${multi.length} · '
        'URLs del fichero ausentes en la base: ${missing.length}');
    for (final v in multi.take(6)) {
      final kept =
          v.firstWhere((e) => stored.contains(e.url), orElse: () => const Entry('', '(ninguno)'));
      // ignore: avoid_print
      print('[verify]   "${v.first.name}": fichero ${v.length} URL(s) → '
          'guardado ${kept.url.isEmpty ? 'NINGUNO' : kept.url.substring(0, kept.url.length.clamp(0, 70))}');
    }

    final needsHeaders = entries.where((e) => e.needsHeaders);
    // ignore: avoid_print
    print('[verify] entradas que dependen de #EXTVLCOPT '
        '(referrer/user-agent): ${needsHeaders.length}');
    if (needsHeaders.isNotEmpty) {
      // ignore: avoid_print
      print('[verify]   p. ej. "${needsHeaders.first.name}" → ${needsHeaders.first.url}');
    }

    // El canal de ETB necesita referrer; debe quedar guardado con el canal.
    final withHeaders =
        channels.where((c) => c.httpHeaders != null && c.httpHeaders!.isNotEmpty);
    final etb = channels.where((c) => (c.tvgId ?? '') == 'ETBD.TV').toList();
    // ignore: avoid_print
    print('[verify] canales guardados con cabeceras: ${withHeaders.length} · '
        'de las entradas que las piden: ${needsHeaders.length}');
    expect(withHeaders, isNotEmpty,
        reason: 'las cabeceras #EXTVLCOPT deben llegar a la base de datos');
    if (etb.isNotEmpty) {
      // ignore: avoid_print
      print('[verify] ${etb.first.name} → ${etb.first.httpHeaders}');
      expect(etb.first.httpHeaders, contains('Referer'));
    }

    // La guía puede consultar por rango de tiempo, pero esos canales aún no
    // tienen EPG: la consulta debe responder sin error y sin filas.
    final now = DateTime.now();
    final slots = await database.getProgrammeSlots(
      epgChannelId: channels.first.tvgId ?? 'desconocido',
      start: now.subtract(const Duration(hours: 1)),
      end: now.add(const Duration(hours: 1)),
    );
    // ignore: avoid_print
    print('[verify] consulta de guía sobre el canal 1 → ${slots.length} fila(s)');

    final count = await (database.selectOnly(database.channels)
          ..addColumns([countAll()]))
        .map((row) => row.read(countAll()) ?? 0)
        .getSingle();
    expect(count, channels.length);
  });

  testWidgets('M3U real: la app carga la lista desde un archivo local',
      (tester) async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);

    // Mismo camino que el diálogo: la ruta se guarda como URI file:// y
    // ProviderManager la lee del disco en lugar de descargarla.
    final uri = ProviderManager.toPlaylistUri(File(kM3uPath).absolute.path);
    expect(ProviderManager.isLocalPlaylistPath(uri), isTrue);

    await ProviderManager(database).addM3uProvider(
      id: 'tdt-file',
      name: 'TDTChannels (archivo)',
      url: uri,
    );

    final channels = await database.getAllChannels();
    final headers = channels.where((c) => (c.httpHeaders ?? '').isNotEmpty);
    // ignore: avoid_print
    print('[verify] desde archivo local ($uri) → ${channels.length} canales, '
        '${headers.length} con cabeceras');

    expect(channels.length, greaterThan(400),
        reason: 'la app debe leer la lista del disco sin servidor HTTP');
    expect(headers, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('Reproducción real de canales de la lista con mpv', (tester) async {
    // Canales públicos sin cabeceras especiales, tal y como aparecen en la lista.
    final la1 = entries.firstWhere((e) => e.name == 'La 1');
    final veinticuatro = entries.firstWhere((e) => e.name == '24h');

    final service = PlayerService();
    addTearDown(service.dispose);
    service.configureFailover(null, null);

    final results = <String, String>{};
    for (final channel in <Entry>[la1, veinticuatro]) {
      await service.play(channel.url,
          channelId: 'tdt-test', channelName: channel.name);

      var advanced = false;
      final deadline = DateTime.now().add(const Duration(seconds: 40));
      while (!advanced && DateTime.now().isBefore(deadline)) {
        final pos =
            double.tryParse(await service.getMpvProperty('time-pos') ?? '');
        if (pos != null && pos > 0.5) advanced = true;
        if (!advanced) await Future<void>.delayed(const Duration(seconds: 1));
      }
      final video = await service.getMpvProperty('video-format') ?? '';
      final fps = await service.getMpvProperty('estimated-vf-fps') ?? '';
      final audio = await service.getMpvProperty('audio-codec-name') ?? '';
      results[channel.name] = 'advanced=$advanced video=$video fps=$fps audio=$audio';
      // ignore: avoid_print
      print('[verify] play "${channel.name}" → ${results[channel.name]} '
          '(${channel.url})');
    }

    expect(results['La 1'], contains('advanced=true'),
        reason: 'el directo de La 1 de la lista debe reproducirse en mpv');
  }, timeout: const Timeout(Duration(minutes: 4)));

  testWidgets('Reproducción de un canal que exige referrer (#EXTVLCOPT)',
      (tester) async {
    // ETB Deportes responde 403 a un GET sin referrer y 200 con él; el
    // reproductor debe enviar la cabecera que traía la lista.
    final etb = entries.firstWhere(
      (e) => e.vlcOpts.containsKey('http-referrer'),
      orElse: () => const Entry('', ''),
    );
    if (etb.url.isEmpty) return;
    final httpHeaders = etb.httpHeaders;

    final service = PlayerService();
    addTearDown(service.dispose);
    service.configureFailover(null, null);
    await service.play(etb.url,
        channelId: 'tdt-headers',
        channelName: etb.name,
        httpHeaders: httpHeaders);

    var advanced = false;
    final deadline = DateTime.now().add(const Duration(seconds: 40));
    while (!advanced && DateTime.now().isBefore(deadline)) {
      final pos =
          double.tryParse(await service.getMpvProperty('time-pos') ?? '');
      if (pos != null && pos > 0.5) advanced = true;
      if (!advanced) await Future<void>.delayed(const Duration(seconds: 1));
    }
    // ignore: avoid_print
    print('[verify] con cabeceras "${etb.name}" → advanced=$advanced '
        'headers=$httpHeaders (${etb.url})');

    expect(advanced, isTrue,
        reason: 'la cabecera de la lista debe desbloquear el stream (403 sin ella)');

    // Y las cabeceras no deben quedarse pegadas al canal siguiente: se pasa a
    // un canal sin directivas y tiene que seguir reproduciéndose.
    final plain = entries.firstWhere((e) => e.name == '24h');
    await service.play(plain.url, channelId: 'tdt-plain', channelName: plain.name);
    var plainAdvanced = false;
    final plainDeadline = DateTime.now().add(const Duration(seconds: 40));
    while (!plainAdvanced && DateTime.now().isBefore(plainDeadline)) {
      final pos =
          double.tryParse(await service.getMpvProperty('time-pos') ?? '');
      if (pos != null && pos > 0.5) plainAdvanced = true;
      if (!plainAdvanced) await Future<void>.delayed(const Duration(seconds: 1));
    }
    final fields = await service.getMpvProperty('http-header-fields') ?? '';
    // ignore: avoid_print
    print('[verify] tras el canal con cabeceras, play "${plain.name}" → '
        'advanced=$plainAdvanced http-header-fields="$fields"');
    expect(plainAdvanced, isTrue,
        reason: 'cambiar a un canal sin cabeceras no debe romper la reproducción');
  }, timeout: const Timeout(Duration(minutes: 4)));
}
