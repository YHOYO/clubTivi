import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/datasources/local/database.dart' as db;
import '../../data/services/channel_probe_service.dart';
import '../../data/services/provider_health.dart';

/// Estado de una comprobación de canales, fuera de cualquier diálogo.
///
/// Vive aquí y no en la vista porque la comprobación corre acoplada a la lista
/// de canales y sobrevive a que el usuario cambie de categoría o reproduzca
/// otro canal: la vista sólo pinta lo que este controlador mide.
///
/// No toca `BuildContext` ni `Navigator`, así que se puede probar sin widgets.
class ChannelScanController extends ChangeNotifier {
  ChannelScanController({
    required this.probe,
    required this.store,
    this.providerHealthStore,
    Map<String, String> providerNames = const {},
    Future<void> Function(Set<String> channelIds)? onHideDead,
  })  : providerNames = Map.of(providerNames),
        _onHideDead = onHideDead;

  final ChannelProbeService probe;

  /// Veredicto por URL: el escaneo lo escribe y la lista lo lee para el punto
  /// de color sin volver a medir nada.
  final ChannelHealthStore store;

  /// Resumen por proveedor, que se guarda al terminar.
  ProviderHealthStore? providerHealthStore;

  /// Nombres de proveedor para el resumen (id → nombre).
  Map<String, String> providerNames;

  final Future<void> Function(Set<String> channelIds)? _onHideDead;

  /// Cuántos canales van en paralelo en la primera pasada.
  static const concurrency = 6;

  // ── Ámbito ──────────────────────────────────────────────────────────────

  List<db.Channel> _visible = const [];
  List<db.Channel> _all = const [];

  /// Los canales que se ven ahora (el filtro de categoría o grupo activo).
  List<db.Channel> get visibleChannels => _visible;

  /// Todos los canales cargados.
  List<db.Channel> get allChannels => _all;

  bool _scanAllChannels = false;
  bool get scanAllChannels => _scanAllChannels;

  /// Nombre del ámbito cuando no es ni la lista visible ni todo lo cargado
  /// (p. ej. los canales de un proveedor concreto, pedidos desde su tarjeta).
  String? _scopeLabel;
  String get scopeLabel =>
      _scopeLabel ?? (_scanAllChannels ? 'all channels' : 'this list');

  /// Quién pidió la pasada que se está midiendo, para que su botón enseñe el
  /// spinner y los demás se sepan deshabilitados mientras corre.
  String? _scopeKey;
  String? get activeScopeKey => _scopeKey;

  void setScopeLabel(String? label) {
    if (_scopeLabel == label) return;
    _scopeLabel = label;
    notifyListeners();
  }

  List<db.Channel> get targets => _scanAllChannels ? _all : _visible;

  /// Con un solo ámbito posible no se ofrece elegir: sólo hay uno.
  bool get singleScope => _visible.length == _all.length;

  void setTargets({
    required List<db.Channel> visible,
    required List<db.Channel> all,
  }) {
    _visible = visible;
    _all = all;
    notifyListeners();
  }

  void setProviderNames(Map<String, String> names) {
    providerNames = Map.of(names);
  }

  void setScope({required bool all}) {
    // Elegir el ámbito invalida cualquier etiqueta de proveedor: el usuario
    // acaba de decir qué quiere comprobar.
    _scopeLabel = null;
    _scopeKey = null;
    if (_scanAllChannels == all) return;
    _scanAllChannels = all;
    notifyListeners();
  }

  /// Comprueba exactamente [channels], que es lo que pide el icono CHECK de una
  /// categoría, un proveedor o una lista de la barra lateral.
  ///
  /// El ámbito viaja con sus canales y su nombre: la pantalla puede repintarse
  /// veinte veces entre que el usuario pulsa y la sonda empieza, y lo que se
  /// mide tiene que seguir siendo lo que pidió.
  Future<void> startScope(
    List<db.Channel> channels, {
    required String label,
    String? key,
  }) {
    final request = _ScopeRequest(
      List<db.Channel>.of(channels),
      label: label,
      key: key,
    );
    _pendingScope = request;
    // El panel deja de ofrecer elegir ámbito: el usuario ya lo eligió al pulsar
    // el icono de la categoría.
    _visible = request.channels;
    _all = request.channels;
    _scanAllChannels = false;
    _scopeLabel = label;
    return start();
  }

  // ── Avance ──────────────────────────────────────────────────────────────

  bool _running = false;
  bool _cancelled = false;

  /// El usuario pulsó STOP en esta pasada. La pasada sigue viva hasta que
  /// sueltan las peticiones que ya estaban en vuelo (un HTTP a medias no se
  /// puede abortar), pero para el usuario ya está parada: no tiene que esperar
  /// a que se vacíen para pedir otra cosa.
  bool _stopped = false;

  bool _disposed = false;
  int _done = 0;
  int _total = 0;
  final Map<ProbeStatus, int> _counts = {};
  final List<MapEntry<db.Channel, ProbeResult>> _failures = [];
  bool _hiddenApplied = false;
  bool _retrySecondPass = true;
  int _retryDone = 0;
  int _retryTotal = 0;
  int? _throttledTo;

  /// Petición que llegó mientras otra comprobación corría: la más nueva manda.
  ///
  /// Se guarda **con sus canales**, no como una bandera: un cambio de filtro en
  /// la pantalla mientras la que corre termina no puede llevarse por delante el
  /// ámbito que el usuario pidió.
  _ScopeRequest? _queued;

  /// Ámbito pedido desde fuera de la pantalla (el icono CHECK de una categoría
  /// de la barra lateral) antes de que su pasada arranque.
  ///
  /// Se guarda con sus canales porque `setTargets` reescribe `visible`/`all` en
  /// cada repintado de la lista: sin esto, el ámbito pedido se perdería entre
  /// que se pulsa el botón y que `start()` lee los canales.
  _ScopeRequest? _pendingScope;

  /// ¿Hay una comprobación que el usuario esté esperando? Parar deja de contar
  /// desde el mismo momento en que se pulsa.
  bool get running => _running && !_stopped;

  /// ¿Está la comprobación ocupada? Es lo que apaga los botones CHECK que no
  /// son el que la pidió.
  bool get busy => running;
  int get doneCount => _done;
  int get total => _total;
  Map<ProbeStatus, int> get counts => Map.unmodifiable(_counts);
  List<MapEntry<db.Channel, ProbeResult>> get failures =>
      List.unmodifiable(_failures);
  bool get hiddenApplied => _hiddenApplied;
  bool get retrySecondPass => _retrySecondPass;
  int get retryDone => _retryDone;
  int get retryTotal => _retryTotal;
  int? get throttledTo => _throttledTo;

  /// Los que sirven: los que contestan rápido y los que sólo contestan solos.
  int get okCount =>
      (_counts[ProbeStatus.ok] ?? 0) + (_counts[ProbeStatus.slow] ?? 0);
  int get deadCount => _done - okCount;

  /// Avance de la primera pasada, o null si aún no hay total.
  double? get progress => _total == 0 ? null : (_done / _total).clamp(0.0, 1.0);
  double? get retryProgress =>
      _retryTotal == 0 ? null : (_retryDone / _retryTotal).clamp(0.0, 1.0);

  /// Último veredicto por canal: al reintentar hay que **corregir** su estado
  /// anterior, no sumar otro.
  final Map<String, ProbeResult> _previousByChannel = {};

  /// Recuento por proveedor, actualizado al vuelo: recalcular el resumen con
  /// cada resultado sería recorrer 13.000 canales en cada repintado.
  final Map<String, _Tally> _tallies = {};

  // Notificar por cada uno de los 13.000 resultados reconstruiría la lista y la
  // barra lateral entera miles de veces; se agrupa.
  Timer? _notifyTimer;
  bool _notifyPending = false;

  void _notifySoon() {
    if (_notifyPending) return;
    _notifyPending = true;
    _notifyTimer?.cancel();
    _notifyTimer = Timer(const Duration(milliseconds: 120), () {
      _notifyPending = false;
      _notify();
    });
  }

  /// Avisa sólo si el controlador sigue vivo: la comprobación termina a
  /// destiempo (la pantalla se desmonta, el contenedor se va) y avisar a un
  /// `ChangeNotifier` ya desechado revienta.
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Carga los resultados de una sesión anterior como punto de partida.
  void seedCountsFromStore() {
    _counts.clear();
    for (final channel in targets.take(400)) {
      final known = store.resultFor(channel);
      if (known != null) {
        _counts.update(known.status, (v) => v + 1, ifAbsent: () => 1);
      }
    }
  }

  /// Arranca la comprobación de los canales que toquen.
  ///
  /// Volver a llamar mientras corre es pedir **otro** ámbito: la que corre se
  /// cancela y, en cuanto suelta las peticiones que tenía en vuelo, arranca
  /// ésta con los canales pedidos. Sólo corre una comprobación a la vez, y la
  /// última pedida es la que se mide.
  Future<void> start() async {
    _stopped = false;
    if (_running) {
      // Lo último pedido es lo que se mide: un ámbito explícito manda sobre lo
      // que la pantalla tenga a la vista en ese momento.
      final pending = _pendingScope;
      _pendingScope = null;
      _queued = pending ?? _ScopeRequest(List<db.Channel>.of(targets));
      _cancelled = true;
      _notify();
      return;
    }

    while (true) {
      // El ámbito pedido desde fuera gana a la cola y a lo que la pantalla
      // tenga a la vista ahora mismo.
      final request = _pendingScope ?? _queued;
      _pendingScope = null;
      _queued = null;
      final channels = request?.channels ?? List<db.Channel>.of(targets);
      if (request?.label != null) _scopeLabel = request!.label;
      _scopeKey = request?.key;
      _running = true;
      _stopped = false;
      _cancelled = false;
      _done = 0;
      _total = channels.length;
      _counts.clear();
      _failures.clear();
      _previousByChannel.clear();
      _tallies.clear();
      _throttledTo = null;
      _retryDone = 0;
      _retryTotal = 0;
      _hiddenApplied = false;
      _notify();

      await probe.scan(
        channels,
        concurrency: concurrency,
        retryTimeouts: _retrySecondPass,
        isCancelled: () => _cancelled || _disposed,
        onRetryStart: (pending) {
          _retryTotal = pending;
          _notify();
        },
        onRetryResult: (channel, result, done, total) {
          _retryDone = done;
          _notifySoon();
        },
        onConcurrencyChanged: (limit, maxLimit) {
          _throttledTo = limit;
          _notifySoon();
        },
        onResult: (channel, result, done, total) =>
            _onResult(channel, result, done),
      );

      _running = false;
      _scopeKey = null;
      _saveProviderSummaries();
      if (_disposed) return;
      _notify();
      // Otra petición esperando turno: se mide lo que pidió.
      if (_queued == null && _pendingScope == null) return;
    }
  }

  void _onResult(db.Channel channel, ProbeResult result, int done) {
    // El veredicto se guarda siempre, aunque el usuario haya parado o cerrado
    // el panel: lo medido es medido.
    store.record(channel.streamUrl, result);
    if (_disposed) return;

    _done = done;
    final tally = _tallies.putIfAbsent(channel.providerId, _Tally.new);
    final previous = _previousByChannel[channel.id];
    if (previous != null) {
      // El recuento del veredicto anterior se corrige; si se queda a cero, la
      // entrada desaparece para que el resumen no muestre estados ya vacíos.
      final left = (_counts[previous.status] ?? 1) - 1;
      if (left <= 0) {
        _counts.remove(previous.status);
      } else {
        _counts[previous.status] = left;
      }
      tally.remove(previous);
    } else {
      tally.total++;
    }
    tally.add(result);
    _previousByChannel[channel.id] = result;
    _counts.update(result.status, (v) => v + 1, ifAbsent: () => 1);
    _failures.removeWhere((entry) => entry.key.id == channel.id);
    if (!result.works) _failures.add(MapEntry(channel, result));
    _notifySoon();
  }

  /// Al terminar se guarda el resumen por proveedor: la pantalla de proveedores
  /// puede así decir qué pasa sin volver a medir nada.
  void _saveProviderSummaries() {
    final store = providerHealthStore;
    if (store == null || _tallies.isEmpty) return;
    store.recordAll(providerBreakdown.values);
    unawaited(store.save());
  }

  /// Desglose en vivo, con lo medido hasta ahora (coste por número de
  /// proveedores, no por número de canales).
  Map<String, ProviderHealthSummary> get providerBreakdown => {
        for (final entry in _tallies.entries)
          entry.key: entry.value.toSummary(
            entry.key,
            providerNames[entry.key] ?? entry.key,
          ),
      };

  /// Veredicto ya medido de una categoría o grupo, para las etiquetas de la
  /// barra lateral: cuántos de sus canales responden.
  ({int checked, int working, int dead}) healthOf(
    Iterable<db.Channel> channels,
  ) {
    var checked = 0;
    var working = 0;
    for (final channel in channels) {
      final result = store.resultFor(channel);
      if (result == null) continue;
      checked++;
      if (result.works) working++;
    }
    return (checked: checked, working: working, dead: checked - working);
  }

  /// Detiene la comprobación; lo ya medido se conserva.
  ///
  /// Parar es parar: si había otra petición esperando turno, también se va.
  void stop() {
    _queued = null;
    _pendingScope = null;
    _scopeKey = null;
    if (!_running) return;
    _cancelled = true;
    _stopped = true;
    _notify();
  }

  void setRetrySecondPass(bool value) {
    if (_retrySecondPass == value) return;
    _retrySecondPass = value;
    notifyListeners();
  }

  /// El filtro «sólo los que responden» vive en la preferencia de la app
  /// (`onlyWorkingChannelsProvider`); aquí sólo se dice qué canal lo pasa.
  ///
  /// Lo que nunca se ha medido se mantiene: todavía no sabemos nada de él. Los
  /// lentos también sirven: sólo responden cuando se les pide solos.
  bool keeps(db.Channel channel) {
    final result = store.resultFor(channel);
    return result == null || result.works;
  }

  /// Recuento de lo ya medido por categoría, en una pasada sobre [channels].
  ///
  /// Claves: `allChannelsHealthKey` para todo, el nombre de la categoría, el
  /// proveedor y la pareja proveedor+categoría.
  Map<String, ({int checked, int working})> groupHealth(
    List<db.Channel> channels,
  ) {
    final index = <String, ({int checked, int working})>{};
    void bump(String key, bool works) {
      final current = index[key];
      index[key] = (
        checked: (current?.checked ?? 0) + 1,
        working: (current?.working ?? 0) + (works ? 1 : 0),
      );
    }

    for (final channel in channels) {
      final result = store.resultFor(channel);
      if (result == null) continue;
      final works = result.works;
      bump(allChannelsHealthKey, works);
      bump('provider:${channel.providerId}', works);
      final group = channel.groupTitle;
      if (group != null && group.isNotEmpty) {
        bump(group, works);
        bump('provgroup:${channel.providerId}:$group', works);
      }
    }
    return index;
  }

  /// El aviso del reproductor con lo que la comprobación ya sabía del canal: si
  /// el chequeo ya lo dio por muerto, el usuario no tiene que volver a
  /// ejecutarlo a mano para enterarse de por qué no se abre.
  String withStoredVerdict(String? url, String message, {db.Channel? playing}) {
    // Si el reproductor ya reintentó a través del proxy, la URL que falló no es
    // la del canal: se busca por el canal que se estaba viendo como respaldo.
    var verdict = url == null ? null : store.resultForUrl(url);
    if (verdict == null && playing != null) verdict = store.resultFor(playing);
    if (verdict == null || verdict.status == ProbeStatus.ok) return message;
    if (message.contains(verdict.label)) return message;
    return '$message\nÚltimo chequeo: ${verdict.label} — ${verdict.advice}';
  }

  /// Oculta los canales que fallaron. Devuelve cuántos.
  Future<int> hideDead() async {
    final hide = _onHideDead;
    final dead =
        _failures.where((f) => !f.value.works).map((f) => f.key.id).toSet();
    if (hide == null || dead.isEmpty) return 0;
    await hide(dead);
    if (_disposed) return dead.length;
    _hiddenApplied = true;
    notifyListeners();
    return dead.length;
  }

  /// Informe de texto con lo medido, para pegarlo en un chat o un issue.
  String report() {
    final buffer = StringBuffer('clubTivi channel check\n');
    buffer.writeln('Scanned: $_done of $_total');
    for (final status in ProbeStatus.values) {
      final count = _counts[status];
      if (count != null && count > 0) {
        buffer.writeln('${status.name}: $count');
      }
    }
    buffer.writeln('');
    for (final failure in _failures) {
      buffer.writeln(
        '${failure.key.name}\t${failure.value.label}\t'
        '${failure.value.detail ?? ''}\t${failure.key.streamUrl}',
      );
    }
    return buffer.toString();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelled = true;
    _notifyTimer?.cancel();
    super.dispose();
  }
}

/// Clave de la etiqueta que resume todos los canales cargados.
const allChannelsHealthKey = '*';

/// Una pasada pedida: sus canales y de quién es (para nombrarla en el panel y
/// para que su botón enseñe el spinner).
class _ScopeRequest {
  _ScopeRequest(this.channels, {this.label, this.key});

  final List<db.Channel> channels;
  final String? label;
  final String? key;
}

/// Recuento mutable por proveedor.
class _Tally {
  int total = 0;
  int working = 0;
  int slow = 0;
  int server = 0;
  int noAnswer = 0;
  int dead = 0;
  int blocked = 0;

  void add(ProbeResult result) => _bump(result, 1);
  void remove(ProbeResult result) => _bump(result, -1);

  void _bump(ProbeResult result, int delta) {
    switch (result.verdict) {
      case ProbeVerdict.works:
        working += delta;
        if (result.status == ProbeStatus.slow) slow += delta;
      case ProbeVerdict.serverSide:
        server += delta;
      case ProbeVerdict.noAnswer:
        noAnswer += delta;
      case ProbeVerdict.dead:
        dead += delta;
      case ProbeVerdict.blocked:
        blocked += delta;
    }
  }

  ProviderHealthSummary toSummary(String id, String name) =>
      ProviderHealthSummary(
        providerId: id,
        providerName: name,
        total: total,
        working: working,
        slow: slow,
        serverSide: server,
        noAnswer: noAnswer,
        dead: dead,
        blocked: blocked,
        checkedAt: DateTime.now(),
      );
}
