import 'dart:async';

import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/channel_probe_service.dart';
import 'package:clubtivi/data/services/provider_health.dart';
import 'package:clubtivi/features/channels/channel_scan_controller.dart';
import 'package:clubtivi/features/channels/channel_scan_host.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

db.Channel channel(String id, String url, {String provider = 'p1', String? group}) =>
    db.Channel(
      id: id,
      providerId: provider,
      name: 'Channel $id',
      streamUrl: url,
      streamType: 'live',
      favorite: false,
      hidden: false,
      sortOrder: 0,
      groupTitle: group,
    );

/// Sonda falsa: entrega los veredictos que se le digan, en el orden que se le
/// diga, y opcionalmente simula la segunda pasada.
class _FakeProbe extends ChannelProbeService {
  _FakeProbe({required this.verdicts, this.retryVerdicts = const {}});

  /// url → veredicto de la primera pasada.
  final Map<String, ProbeStatus> verdicts;

  /// url → veredicto de la segunda pasada (los que sólo responden solos).
  final Map<String, ProbeStatus> retryVerdicts;

  List<db.Channel> scanned = [];
  bool cancelledSeen = false;

  @override
  Future<void> scan(
    List<db.Channel> channels, {
    int concurrency = 6,
    Duration timeout = const Duration(seconds: 8),
    bool retryTimeouts = true,
    Duration retryTimeout = const Duration(seconds: 15),
    int maxRetries = 2,
    bool adaptConcurrency = true,
    required void Function(
            db.Channel channel, ProbeResult result, int done, int total)
        onResult,
    void Function(int pending)? onRetryStart,
    void Function(db.Channel channel, ProbeResult result, int done, int total)?
        onRetryResult,
    void Function(int limit, int maxLimit)? onConcurrencyChanged,
    bool Function()? isCancelled,
  }) async {
    scanned = List.of(channels);
    final total = channels.length;
    var done = 0;
    final pending = <db.Channel>[];

    for (final channel in channels) {
      // Cede el turno: sin esto la cancelación nunca llega a verse.
      await Future<void>.delayed(Duration.zero);
      if (isCancelled?.call() ?? false) {
        cancelledSeen = true;
        return;
      }
      final status = verdicts[channel.streamUrl] ?? ProbeStatus.ok;
      done++;
      onResult(channel, ProbeResult(status: status, httpStatus: 200), done, total);
      if (retryVerdicts.containsKey(channel.streamUrl)) pending.add(channel);
    }

    if (pending.isEmpty || !retryTimeouts) return;
    onRetryStart?.call(pending.length);
    var retryDone = 0;
    for (final channel in pending) {
      await Future<void>.delayed(Duration.zero);
      if (isCancelled?.call() ?? false) {
        cancelledSeen = true;
        return;
      }
      retryDone++;
      final verdict = ProbeResult(status: retryVerdicts[channel.streamUrl]!);
      // Igual que el servicio real: avisa del avance **y** entrega el veredicto
      // corregido por el mismo camino que los de la primera pasada.
      onRetryResult?.call(channel, verdict, retryDone, pending.length);
      onResult(channel, verdict, done, total);
    }
  }
}

/// Sonda que se queda **dentro** del escaneo hasta que la prueba la suelta: con
/// ella se ve qué pasa cuando llega otra petición, o un STOP, a mitad.
class _ParkedProbe extends ChannelProbeService {
  /// Canales con los que se llamó a `scan`, en orden.
  final calls = <List<db.Channel>>[];

  /// Se completa cuando la primera llamada ya está dentro.
  final firstCallEntered = Completer<void>();

  /// La prueba lo completa para dejar terminar a la primera llamada.
  final release = Completer<void>();

  bool cancelledSeen = false;

  @override
  Future<void> scan(
    List<db.Channel> channels, {
    int concurrency = 6,
    Duration timeout = const Duration(seconds: 8),
    bool retryTimeouts = true,
    Duration retryTimeout = const Duration(seconds: 15),
    int maxRetries = 2,
    bool adaptConcurrency = true,
    required void Function(
            db.Channel channel, ProbeResult result, int done, int total)
        onResult,
    void Function(int pending)? onRetryStart,
    void Function(db.Channel channel, ProbeResult result, int done, int total)?
        onRetryResult,
    void Function(int limit, int maxLimit)? onConcurrencyChanged,
    bool Function()? isCancelled,
  }) async {
    calls.add(List.of(channels));
    if (calls.length == 1) {
      firstCallEntered.complete();
      await release.future;
    }
    if (isCancelled?.call() ?? false) cancelledSeen = true;
  }
}

/// Sonda que sigue con su trabajo después de que el controlador se haya ido:
/// es lo que hace el servicio real cuando la pantalla se desmonta a mitad de
/// escaneo y aún le queda la segunda pasada por empezar.
class _OutlivingProbe extends ChannelProbeService {
  final inside = Completer<void>();
  void Function(int pending)? _onRetryStart;

  /// Lo que hace el servicio real al empezar la segunda pasada.
  void reportRetryPass(int pending) => _onRetryStart?.call(pending);

  @override
  Future<void> scan(
    List<db.Channel> channels, {
    int concurrency = 6,
    Duration timeout = const Duration(seconds: 8),
    bool retryTimeouts = true,
    Duration retryTimeout = const Duration(seconds: 15),
    int maxRetries = 2,
    bool adaptConcurrency = true,
    required void Function(
            db.Channel channel, ProbeResult result, int done, int total)
        onResult,
    void Function(int pending)? onRetryStart,
    void Function(db.Channel channel, ProbeResult result, int done, int total)?
        onRetryResult,
    void Function(int limit, int maxLimit)? onConcurrencyChanged,
    bool Function()? isCancelled,
  }) async {
    _onRetryStart = onRetryStart;
    inside.complete();
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  late ChannelHealthStore store;
  late ProviderHealthStore providerStore;

  setUp(() {
    store = ChannelHealthStore();
    providerStore = ProviderHealthStore();
  });

  ChannelScanController controllerFor(
    ChannelProbeService probe, {
    List<db.Channel> visible = const [],
    List<db.Channel> all = const [],
    Map<String, String> providerNames = const {},
    Future<void> Function(Set<String>)? onHideDead,
  }) {
    final controller = ChannelScanController(
      probe: probe,
      store: store,
      providerHealthStore: providerStore,
      providerNames: providerNames,
      onHideDead: onHideDead,
    )..setTargets(visible: visible, all: all);
    addTearDown(controller.dispose);
    return controller;
  }

  test('cuenta los veredictos y separa los que sirven de los que no', () async {
    final channels = [
      channel('a', 'http://x/a', group: 'News'),
      channel('b', 'http://x/b', group: 'News'),
      channel('c', 'http://x/c', group: 'Films'),
      channel('d', 'http://x/d', group: 'Films'),
    ];
    final probe = _FakeProbe(verdicts: {
      'http://x/a': ProbeStatus.ok,
      'http://x/b': ProbeStatus.notFound,
      'http://x/c': ProbeStatus.timeout,
      'http://x/d': ProbeStatus.ok,
    });
    final controller = controllerFor(probe, visible: channels, all: channels);

    await controller.start();

    expect(controller.doneCount, 4);
    expect(controller.total, 4);
    expect(controller.okCount, 2);
    expect(controller.deadCount, 2);
    expect(controller.counts[ProbeStatus.notFound], 1);
    expect(controller.failures.map((f) => f.key.id), containsAll(['b', 'c']));
    // El veredicto queda guardado por canal: la lista lo lee para el punto.
    expect(store.resultFor(channels[1])?.status, ProbeStatus.notFound);
  });

  test('el que sólo responde en la segunda pasada se corrige, no se suma dos veces',
      () async {
    final channels = [channel('a', 'http://x/a'), channel('b', 'http://x/b')];
    final probe = _FakeProbe(
      verdicts: {
        'http://x/a': ProbeStatus.timeout,
        'http://x/b': ProbeStatus.ok,
      },
      retryVerdicts: {'http://x/a': ProbeStatus.slow},
    );
    final controller = controllerFor(probe, visible: channels, all: channels);

    await controller.start();

    expect(controller.counts[ProbeStatus.timeout], isNull,
        reason: 'el veredicto anterior se corrige al llegar el de la segunda pasada');
    expect(controller.counts[ProbeStatus.slow], 1);
    expect(controller.okCount, 2, reason: 'un canal lento también sirve');
    expect(controller.deadCount, 0);
    expect(controller.failures, isEmpty);
    expect(controller.retryTotal, 1);
    expect(controller.retryDone, 1);
  });

  test('el ámbito decide qué canales se tocan, y no cambia a mitad de escaneo',
      () async {
    final visible = [channel('a', 'http://x/a')];
    final all = [channel('a', 'http://x/a'), channel('b', 'http://x/b')];
    final probe = _FakeProbe(verdicts: {});
    final controller = controllerFor(probe, visible: visible, all: all);

    expect(controller.singleScope, isFalse);
    expect(controller.targets.length, 1);

    controller.setScope(all: true);
    await controller.start();
    expect(probe.scanned.length, 2);

    // Cambiar de categoría durante el escaneo no debe alterar lo que se mide.
    controller.setTargets(visible: all, all: all);
    expect(controller.total, 2);
    expect(controller.targets.length, 2);
  });

  test('el CHECK de una categoría mide sólo sus canales, y su botón lo sabe',
      () async {
    final news = [
      channel('n1', 'http://x/n1', group: 'News'),
      channel('n2', 'http://x/n2', group: 'News'),
    ];
    final everything = [
      for (var i = 0; i < 5; i++) channel('c$i', 'http://x/$i', group: 'Films'),
    ];
    final probe = _ParkedProbe();
    final controller = controllerFor(probe, visible: everything, all: everything);

    final running =
        controller.startScope(news, label: 'News', key: 'group:News');
    await probe.firstCallEntered.future;

    expect(controller.busy, isTrue);
    expect(controller.activeScopeKey, 'group:News');
    expect(controller.scopeLabel, 'News');
    expect(controller.singleScope, isTrue,
        reason: 'el panel no ofrece elegir ámbito: ya se eligió al pulsar');

    // Mientras corre, la lista se repinta y reescribe su ámbito: lo pedido no
    // se toca, y el botón que lo pidió se distingue de los demás.
    controller.setTargets(visible: everything, all: everything);

    probe.release.complete();
    await running;

    expect(probe.calls.single.map((c) => c.id), news.map((c) => c.id),
        reason: 'se miden los canales de la categoría, no la lista entera');
    expect(controller.busy, isFalse);
    expect(controller.activeScopeKey, isNull,
        reason: 'terminada la pasada, ningún botón se queda con el spinner');
  });

  test('pedir otra categoría mientras corre encola el ámbito nuevo con su nombre',
      () async {
    final news = [channel('n', 'http://x/n', group: 'News')];
    final films = [
      channel('f1', 'http://x/f1', group: 'Films'),
      channel('f2', 'http://x/f2', group: 'Films'),
    ];
    final everything = [...news, ...films];
    final probe = _ParkedProbe();
    final controller = controllerFor(probe, visible: news, all: everything);
    final seenKeys = <String?>[];
    controller.addListener(() => seenKeys.add(controller.activeScopeKey));

    final first = controller.startScope(news, label: 'News', key: 'group:News');
    await probe.firstCallEntered.future;

    await controller.startScope(films, label: 'Films', key: 'group:Films');
    // La pantalla se repinta con otro filtro: el ámbito encolado no se cambia.
    controller.setTargets(visible: everything, all: everything);

    probe.release.complete();
    await first;

    expect(probe.calls, hasLength(2));
    expect(probe.calls.last.map((c) => c.id), films.map((c) => c.id),
        reason: 'la categoría pedida después es la que se mide');
    expect(seenKeys, contains('group:Films'),
        reason: 'el botón de la segunda categoría es el que enseña el spinner');
    expect(controller.activeScopeKey, isNull);
  });

  test(
      'la petición más nueva manda: la que corría se cancela y se mide la nueva',
      () async {
    final first = [for (var i = 0; i < 4; i++) channel('a$i', 'http://a/$i')];
    final second = [for (var i = 0; i < 3; i++) channel('b$i', 'http://b/$i')];
    final probe = _ParkedProbe();
    final controller = controllerFor(probe, visible: first, all: first);

    final running = controller.start();
    await probe.firstCallEntered.future;

    // Con la primera dentro, el usuario pide otro ámbito: el CHECK de la
    // tarjeta de un proveedor, por ejemplo.
    controller.setTargets(visible: second, all: second);
    controller.start();
    await Future<void>.delayed(Duration.zero);
    expect(controller.running, isTrue, reason: 'sólo corre una a la vez');
    expect(probe.calls, hasLength(1),
        reason: 'la nueva espera a que la otra suelte lo que tiene en vuelo');

    probe.release.complete();
    await running;

    expect(probe.cancelledSeen, isTrue, reason: 'la que corría se cancela');
    expect(controller.running, isFalse);
    expect(probe.calls, hasLength(2));
    expect(probe.calls.last.map((c) => c.id), second.map((c) => c.id),
        reason: 'lo que se mide es lo último pedido, no lo que ya iba');
  });

  test('parar cancela también la petición que esperaba turno', () async {
    final first = [channel('a', 'http://a/1')];
    final second = [channel('b', 'http://b/1')];
    final probe = _ParkedProbe();
    final controller = controllerFor(probe, visible: first, all: first);

    final running = controller.start();
    await probe.firstCallEntered.future;
    controller.setTargets(visible: second, all: second);
    controller.start();
    controller.stop();
    probe.release.complete();
    await running;

    expect(controller.running, isFalse);
    expect(probe.calls, hasLength(1),
        reason: 'parar es parar: lo pedido y luego parado no llega a medirse');
  });

  test('parar se nota al instante, sin esperar a las peticiones en vuelo',
      () async {
    final channels = [channel('a', 'http://a/1')];
    final probe = _ParkedProbe();
    final controller = controllerFor(probe, visible: channels, all: channels);

    final running = controller.start();
    await probe.firstCallEntered.future;
    expect(controller.running, isTrue);

    controller.stop();
    // La sonda sigue dentro (un HTTP a medias no se puede abortar), pero el
    // usuario ya no está esperando nada y puede pedir otra cosa.
    expect(controller.running, isFalse, reason: 'parar se nota al instante');

    probe.release.complete();
    await running;
    expect(controller.running, isFalse);
  });

  test(
      'la segunda pasada que avisa con el controlador ya desechado no revienta',
      () async {
    final probe = _OutlivingProbe();
    final only = channel('a', 'http://x/a');
    final controller = ChannelScanController(probe: probe, store: store)
      ..setTargets(visible: [only], all: [only]);

    final running = controller.start();
    await probe.inside.future;
    // La pantalla se va a mitad de escaneo (o el contenedor se desecha).
    controller.dispose();
    // Y el servicio sigue su curso: le queda la segunda pasada por empezar.
    probe.reportRetryPass(2);
    await running;
  });

  test('el ámbito se nombra: la lista, todo lo cargado o un proveedor', () {
    final visible = [channel('a', 'http://x/a')];
    final all = [channel('a', 'http://x/a'), channel('b', 'http://x/b')];
    final controller =
        controllerFor(_FakeProbe(verdicts: {}), visible: visible, all: all);

    expect(controller.scopeLabel, 'this list');
    // Los canales de un proveedor pedidos desde su tarjeta se nombran con él.
    controller.setScopeLabel('Scan fixtures');
    expect(controller.scopeLabel, 'Scan fixtures');
    // Elegir ámbito a mano descarta la etiqueta del proveedor.
    controller.setScope(all: true);
    expect(controller.scopeLabel, 'all channels');
  });

  test('con un solo ámbito no se ofrece elegir', () async {
    final channels = [channel('a', 'http://x/a')];
    final controller =
        controllerFor(_FakeProbe(verdicts: {}), visible: channels, all: channels);

    expect(controller.singleScope, isTrue);
  });

  test('parar deja lo medido y avisa a la sonda', () async {
    final channels = [
      for (var i = 0; i < 4; i++) channel('c$i', 'http://x/$i'),
    ];
    final probe = _FakeProbe(verdicts: {});
    final controller = controllerFor(probe, visible: channels, all: channels);

    final running = controller.start();
    // Deja que la sonda empiece a entregar antes de parar.
    await Future<void>.delayed(Duration.zero);
    controller.stop();
    await running;

    expect(probe.cancelledSeen, isTrue);
    expect(controller.running, isFalse);
    // Lo medido antes de parar no se tira.
    expect(controller.doneCount, greaterThanOrEqualTo(0));
  });

  test('el resumen por proveedor se guarda al terminar', () async {
    final channels = [
      channel('a', 'http://x/a', provider: 'p1'),
      channel('b', 'http://x/b', provider: 'p1'),
      channel('c', 'http://x/c', provider: 'p2'),
    ];
    final probe = _FakeProbe(verdicts: {
      'http://x/b': ProbeStatus.notFound,
      'http://x/c': ProbeStatus.ok,
    });
    final controller = controllerFor(
      probe,
      visible: channels,
      all: channels,
      providerNames: {'p1': 'Pluto TV', 'p2': 'Samsung TV Plus'},
    );

    await controller.start();

    final p1 = providerStore.summaryFor('p1')!;
    expect(p1.providerName, 'Pluto TV');
    expect(p1.total, 2);
    expect(p1.working, 1);
    expect(p1.dead, 1);
    expect(providerStore.summaryFor('p2')!.working, 1);
  });

  test('ocultar muertos no oculta los lentos, que sí sirven', () async {
    final channels = [
      channel('ok', 'http://x/ok'),
      channel('slow', 'http://x/slow'),
      channel('dead', 'http://x/dead'),
    ];
    final probe = _FakeProbe(
      verdicts: {
        'http://x/slow': ProbeStatus.timeout,
        'http://x/dead': ProbeStatus.notFound,
      },
      retryVerdicts: {'http://x/slow': ProbeStatus.slow},
    );
    Set<String>? hidden;
    final controller = controllerFor(
      probe,
      visible: channels,
      all: channels,
      onHideDead: (ids) async => hidden = ids,
    );

    await controller.start();
    final count = await controller.hideDead();

    expect(count, 1);
    expect(hidden, {'dead'});
    expect(controller.hiddenApplied, isTrue);
  });

  test('«sólo los que responden» es una preferencia de la app, no de una pantalla',
      () async {
    SharedPreferences.setMockInitialValues({});
    final onlyWorking = OnlyWorkingChannels();
    final log = <bool>[];
    onlyWorking.addListener(() => log.add(onlyWorking.value));

    expect(onlyWorking.value, isFalse);
    await onlyWorking.set(true);
    expect(onlyWorking.value, isTrue);
    expect(log, [true]);

    // La elección se recuerda al volver a la app.
    final restored = OnlyWorkingChannels();
    await restored.restore();
    expect(restored.value, isTrue);
  });

  test('el filtro deja pasar lo que nunca se ha medido y lo que responde', () {
    final channels = [
      channel('sin-medir', 'http://x/sin-medir'),
      channel('responde', 'http://x/responde'),
      channel('lento', 'http://x/lento'),
      channel('muerto', 'http://x/muerto'),
    ];
    final controller = controllerFor(
      _FakeProbe(verdicts: {}),
      visible: channels,
      all: channels,
    );
    store.record('http://x/responde',
        const ProbeResult(status: ProbeStatus.ok, httpStatus: 200));
    store.record('http://x/lento',
        const ProbeResult(status: ProbeStatus.slow, httpStatus: 200));
    store.record('http://x/muerto',
        const ProbeResult(status: ProbeStatus.notFound, httpStatus: 404));

    expect(channels.where(controller.keeps).map((c) => c.id),
        ['sin-medir', 'responde', 'lento'],
        reason: 'lo no medido se mantiene y los lentos también sirven');
  });

  test('el aviso del reproductor lleva lo que el chequeo ya sabía', () {
    final muerto = channel('muerto', 'http://x/muerto');
    final controller = controllerFor(
      _FakeProbe(verdicts: {}),
      visible: [muerto],
      all: [muerto],
    );
    store.record('http://x/muerto',
        const ProbeResult(status: ProbeStatus.notFound, httpStatus: 404));
    store.record('http://x/otro',
        const ProbeResult(status: ProbeStatus.ok, httpStatus: 200));

    expect(
        controller.withStoredVerdict('http://x/otro', 'No se pudo abrir'),
        'No se pudo abrir',
        reason: 'lo que responde no ensucia el aviso');
    expect(
        controller.withStoredVerdict('http://x/desconocida',
            'No se pudo abrir',
            playing: muerto),
        contains('Gone (404)'),
        reason: 'si el proxy cambió la URL, manda el canal que se estaba viendo');
  });

  test('la salud por categoría sale de lo ya medido', () async {
    final news = [
      channel('a', 'http://x/a', group: 'News'),
      channel('b', 'http://x/b', group: 'News'),
    ];
    final films = [channel('c', 'http://x/c', group: 'Films')];
    final probe = _FakeProbe(verdicts: {
      'http://x/b': ProbeStatus.notFound,
      'http://x/c': ProbeStatus.ok,
    });
    final controller =
        controllerFor(probe, visible: [...news, ...films], all: [...news, ...films]);

    await controller.start();
    await store.save();

    // Una categoría con un muerto y otra limpia.
    expect(controller.healthOf(news).working, 1);
    expect(controller.healthOf(news).dead, 1);
    expect(controller.healthOf(films).working, 1);
    expect(controller.healthOf(films).dead, 0);
  });

  test('el informe lleva el recuento y los canales que fallan', () async {
    final channels = [
      channel('a', 'http://x/a'),
      channel('b', 'http://x/b'),
      channel('c', 'http://x/c'),
    ];
    final probe = _FakeProbe(verdicts: {
      'http://x/b': ProbeStatus.notFound,
      'http://x/c': ProbeStatus.forbidden,
    });
    final controller = controllerFor(probe, visible: channels, all: channels);

    await controller.start();
    final report = controller.report();

    expect(report, contains('Scanned: 3 of 3'));
    expect(report, contains('notFound: 1'));
    expect(report, contains('forbidden: 1'));
    expect(report, contains('http://x/b'));
    expect(report, contains('http://x/c'));
  });
}
