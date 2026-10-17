// El resumen por proveedor: cuántos canales sirven, cuántos fallos son del
// servidor y cuántos canales ya no existen. Es la lectura que dice si hay que
// bajar el ritmo (502) o cambiar de lista (404).
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/channel_probe_service.dart';
import 'package:clubtivi/data/services/provider_health.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  db.Channel channel(String id, String providerId) => db.Channel(
        id: id,
        providerId: providerId,
        name: id,
        streamUrl: 'http://example.com/$id.m3u8',
        streamType: 'live',
        favorite: false,
        hidden: false,
        sortOrder: 0,
      );

  MapEntry<db.Channel, ProbeResult> entry(
    String id,
    String providerId,
    ProbeResult result,
  ) =>
      MapEntry(channel(id, providerId), result);

  const ok = ProbeResult(status: ProbeStatus.ok, httpStatus: 200);
  const slow = ProbeResult(
      status: ProbeStatus.slow, httpStatus: 200, latencyMs: 12000);
  const refused = ProbeResult(status: ProbeStatus.forbidden, httpStatus: 403);
  const serverError = ProbeResult(status: ProbeStatus.unreachable, httpStatus: 502);
  const badGateway = ProbeResult(status: ProbeStatus.unreachable, httpStatus: 503);
  const noAnswer = ProbeResult(status: ProbeStatus.timeout);
  const gone = ProbeResult(status: ProbeStatus.notFound, httpStatus: 404);
  const loginPage = ProbeResult(status: ProbeStatus.notAPlaylist, httpStatus: 200);
  const clientError = ProbeResult(status: ProbeStatus.unreachable, httpStatus: 400);
  const blockedCert = ProbeResult(status: ProbeStatus.tls, detail: 'handshake');
  const blockedPage = ProbeResult(status: ProbeStatus.blocked, httpStatus: 403);

  group('ProbeResult.verdict', () {
    test('splits the failures by who is to blame', () {
      expect(ok.verdict, ProbeVerdict.works);
      expect(slow.verdict, ProbeVerdict.works);
      expect(refused.verdict, ProbeVerdict.serverSide);
      expect(serverError.verdict, ProbeVerdict.serverSide);
      expect(badGateway.verdict, ProbeVerdict.serverSide);
      expect(noAnswer.verdict, ProbeVerdict.noAnswer);
      expect(gone.verdict, ProbeVerdict.dead);
      expect(loginPage.verdict, ProbeVerdict.dead);
      expect(clientError.verdict, ProbeVerdict.dead);
      // Ni el servidor ni el canal: la red que no deja pasar.
      expect(blockedCert.verdict, ProbeVerdict.blocked);
      expect(blockedPage.verdict, ProbeVerdict.blocked);
    });

    test('slow channels count as working, but not as fast', () {
      expect(slow.works, isTrue);
      expect(slow.isOk, isFalse);
      expect(slow.label, contains('Slow'));
    });
  });

  group('ProviderHealthSummary', () {
    test('counts each bucket per provider', () {
      final summaries = ProviderHealthSummary.fromResults([
        entry('a', 'p1', ok),
        entry('b', 'p1', slow),
        entry('c', 'p1', serverError),
        entry('d', 'p1', refused),
        entry('e', 'p1', noAnswer),
        entry('f', 'p1', gone),
        entry('g', 'p2', ok),
      ], providerNames: {'p1': 'Lista grande', 'p2': 'Lista pequeña'});

      final p1 = summaries['p1']!;
      expect(p1.providerName, 'Lista grande');
      expect(p1.total, 6);
      expect(p1.working, 2);
      expect(p1.slow, 1);
      expect(p1.serverSide, 2);
      expect(p1.noAnswer, 1);
      expect(p1.dead, 1);
      expect(p1.blamesTheServer, isTrue);
      expect(p1.checkedAt, isNotNull);
      expect(p1.label, contains('2/6 work'));
      expect(p1.label, contains('the server refused'));

      final p2 = summaries['p2']!;
      expect(p2.total, 1);
      expect(p2.workingRatio, 1.0);
      expect(p2.blamesTheServer, isFalse);
      expect(p2.diagnosis, contains('100%'));
    });

    test('a list full of 404s is diagnosed as old, not as a choking server', () {
      final summary = ProviderHealthSummary.fromResults([
        entry('a', 'p1', gone),
        entry('b', 'p1', gone),
        entry('c', 'p1', gone),
        entry('d', 'p1', loginPage),
      ])['p1']!;

      expect(summary.blamesTheServer, isFalse);
      expect(summary.dead, 4);
      expect(summary.diagnosis, contains('list looks old'));
    });

    test('a provider the network filters says so, and does not blame itself',
        () {
      // El caso real de Pluto TV en esta máquina: 400 canales que fallan en
      // milisegundos porque el filtro de red corta el dominio.
      final summary = ProviderHealthSummary.fromResults([
        entry('a', 'pluto-tv', blockedCert),
        entry('b', 'pluto-tv', blockedPage),
        entry('c', 'pluto-tv', blockedCert),
      ], providerNames: {'pluto-tv': 'Pluto TV'})['pluto-tv']!;

      expect(summary.blocked, 3);
      expect(summary.working, 0);
      expect(summary.blamesTheNetwork, isTrue);
      expect(summary.blamesTheServer, isFalse);
      expect(summary.label, contains('blocked by the network'));
      expect(summary.diagnosis, contains('network is filtering'));
    });

    test('survives a round trip through JSON', () {
      final original = ProviderHealthSummary.fromResults(
        [entry('a', 'p1', slow), entry('b', 'p1', serverError)],
        providerNames: {'p1': 'Proveedor'},
      )['p1']!;

      final restored = ProviderHealthSummary.fromJson(original.toJson());
      expect(restored.providerId, 'p1');
      expect(restored.providerName, 'Proveedor');
      expect(restored.total, 2);
      expect(restored.working, 1);
      expect(restored.serverSide, 1);
      expect(restored.blocked, 0);
      expect(restored.checkedAt!.millisecondsSinceEpoch,
          original.checkedAt!.millisecondsSinceEpoch);
    });
  });

  group('ProviderHealthStore', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('keeps the last summary per provider across reloads', () async {
      final summary = ProviderHealthSummary.fromResults(
        [entry('a', 'p1', ok), entry('b', 'p1', gone)],
      )['p1']!;

      final store = ProviderHealthStore();
      await store.load();
      store.record(summary);
      await store.save();

      final reloaded = ProviderHealthStore();
      await reloaded.load();
      expect(reloaded.summaryFor('p1')?.total, 2);
      expect(reloaded.summaryFor('p1')?.dead, 1);
      expect(reloaded.summaryFor('p2'), isNull);
    });

    test('forgets providers that no longer exist', () async {
      final store = ProviderHealthStore();
      await store.load();
      store.recordAll(
        ProviderHealthSummary.fromResults(
          [entry('a', 'p1', ok), entry('b', 'p2', ok)],
        ).values,
      );
      store.pruneTo({'p2'});
      await store.save();

      final reloaded = ProviderHealthStore();
      await reloaded.load();
      expect(reloaded.all.keys, ['p2']);
    });
  });
}
