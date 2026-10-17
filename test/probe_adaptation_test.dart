// Cuando el servidor devuelve 502 en ráfaga, no es culpa de los canales: hay
// que bajar el ritmo. Estas pruebas fijan la política y comprueban que un
// servidor que sólo aguanta una petición a la vez acaba sirviendo canales.
import 'dart:io';

import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/channel_probe_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AdaptiveConcurrency', () {
    AdaptiveConcurrency controller() => AdaptiveConcurrency(
          maxLimit: 8,
          window: 4,
          failuresToBackOff: 2,
          resultsToSpeedUp: 6,
        );

    test('starts at the requested limit', () {
      final c = controller();
      expect(c.limit, 8);
      expect(c.isThrottled, isFalse);
    });

    test('two server-side failures in the window halve the rate', () {
      final c = controller();
      expect(c.record(ProbeVerdict.serverSide), isNull);
      expect(c.record(ProbeVerdict.works), isNull);
      expect(c.record(ProbeVerdict.serverSide), 4);
      expect(c.limit, 4);
      expect(c.isThrottled, isTrue);
    });

    test('keeps halving while the server keeps refusing', () {
      final c = controller();
      c.record(ProbeVerdict.serverSide);
      c.record(ProbeVerdict.serverSide);
      expect(c.limit, 4);
      c.record(ProbeVerdict.serverSide);
      c.record(ProbeVerdict.serverSide);
      expect(c.limit, 2);
      c.record(ProbeVerdict.serverSide);
      c.record(ProbeVerdict.serverSide);
      expect(c.limit, 1);
      expect(c.downgrades, 3);
    });

    test('never goes below one request at a time', () {
      final c = controller();
      for (var i = 0; i < 20; i++) {
        c.record(ProbeVerdict.serverSide);
      }
      expect(c.limit, 1);
    });

    test('dead channels do not slow the scan down', () {
      // Un 404 dice que la entrada de la lista está vieja, no que el servidor
      // esté ahogado: bajar el ritmo sólo haría el escaneo más lento.
      final c = controller();
      for (var i = 0; i < 30; i++) {
        expect(c.record(ProbeVerdict.dead), isNull);
      }
      expect(c.limit, 8);
      expect(c.downgrades, 0);
    });

    test('timeouts alone are not attributed to the server', () {
      final c = controller();
      for (var i = 0; i < 30; i++) {
        expect(c.record(ProbeVerdict.noAnswer), isNull);
      }
      expect(c.limit, 8);
    });

    test('climbs back up after a clean streak, never above the maximum', () {
      final c = controller();
      c.record(ProbeVerdict.serverSide);
      c.record(ProbeVerdict.serverSide); // → 4
      expect(c.limit, 4);

      for (var i = 0; i < 6; i++) {
        c.record(ProbeVerdict.works);
      }
      expect(c.limit, 5);

      for (var i = 0; i < 60; i++) {
        c.record(ProbeVerdict.works);
      }
      expect(c.limit, 8);
    });
  });

  group('scan against a server that chokes', () {
    late HttpServer server;
    late ChannelProbeService probe;
    var activeRequests = 0;
    var maxSeen = 0;

    setUp(() async {
      activeRequests = 0;
      maxSeen = 0;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        activeRequests++;
        if (activeRequests > maxSeen) maxSeen = activeRequests;
        // Este servidor sólo atiende de una en una: con varias a la vez
        // devuelve 502, que es exactamente el caso de la lista real.
        if (activeRequests > 1) {
          request.response.statusCode = 502;
        } else {
          request.response.write('#EXTM3U\n#EXTINF:-1,Canal\n');
        }
        await request.response.close();
        activeRequests--;
      });
      probe = ChannelProbeService();
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('lowers the rate and still rescues channels', () async {
      final channels = List.generate(
        24,
        (i) => db.Channel(
          id: 'ch$i',
          providerId: 'p1',
          name: 'Canal $i',
          streamUrl: 'http://127.0.0.1:${server.port}/live$i.m3u8',
          streamType: 'live',
          favorite: false,
          hidden: false,
          sortOrder: 0,
        ),
      );

      final limits = <int>[];
      final verdicts = <String, ProbeResult>{};
      var retried = 0;

      await probe.scan(
        channels,
        concurrency: 8,
        timeout: const Duration(milliseconds: 700),
        retryTimeout: const Duration(milliseconds: 700),
        onConcurrencyChanged: (limit, max) => limits.add(limit),
        onRetryResult: (_, _, _, _) => retried++,
        onResult: (channel, result, _, _) => verdicts[channel.id] = result,
      );

      expect(verdicts, hasLength(channels.length));
      // El ritmo bajó solo al ver los 502…
      expect(limits, isNotEmpty);
      expect(limits.last, lessThan(8));
      // …y aun así algún canal se salvó (los que salieron con una sola
      // petición en vuelo quedan como «lentos», que sí sirven).
      expect(verdicts.values.where((r) => r.works), isNotEmpty);
      // La segunda pasada también aporta su grano de arena.
      expect(retried, greaterThan(0));
    });

    test('skipping adaptation is possible when the caller knows better',
        () async {
      final channels = List.generate(
        6,
        (i) => db.Channel(
          id: 'ch$i',
          providerId: 'p1',
          name: 'Canal $i',
          streamUrl: 'http://127.0.0.1:${server.port}/live$i.m3u8',
          streamType: 'live',
          favorite: false,
          hidden: false,
          sortOrder: 0,
        ),
      );
      var changes = 0;
      await probe.scan(
        channels,
        concurrency: 4,
        timeout: const Duration(milliseconds: 700),
        retryTimeouts: false,
        adaptConcurrency: false,
        onConcurrencyChanged: (_, _) => changes++,
        onResult: (_, _, _, _) {},
      );
      expect(changes, 0);
    });
  });
}
