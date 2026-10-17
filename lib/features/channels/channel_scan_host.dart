import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/datasources/local/database.dart' as db;
import '../../data/services/channel_probe_service.dart';
import '../../data/services/provider_health.dart';
import '../providers/provider_manager.dart' show databaseProvider;
import 'channel_health_panel.dart';
import 'channel_scan_controller.dart';

export 'channel_scan_controller.dart' show allChannelsHealthKey;

/// La comprobación de canales como una pieza más de la app.
///
/// Aquí vive todo lo suyo: quién la pide, con qué canales, si la tira está
/// abierta, qué canales pasa el filtro de los que responden, los recuentos por
/// categoría y las superficies que la enseñan (la tira, el botón CHECK, el
/// punto de cada fila y la etiqueta de cada categoría). La pantalla de canales
/// sólo entrega sus canales y pinta lo que se le da.

/// Si la tira está abierta y desplegada.
///
/// Es estado de la comprobación, no de la pantalla que la aloja: la piden el
/// botón CHECK, la tarjeta de un proveedor y la propia tira.
class ScanPanelController extends ChangeNotifier {
  bool _open = false;
  bool _expanded = false;

  bool get open => _open;
  bool get expanded => _expanded;

  /// Abre la tira desplegada: pedir una comprobación es querer verla.
  void show() {
    if (_open && _expanded) return;
    _open = true;
    _expanded = true;
    notifyListeners();
  }

  void setExpanded(bool value) {
    if (!_open || _expanded == value) return;
    _expanded = value;
    notifyListeners();
  }

  void close() {
    if (!_open) return;
    _open = false;
    _expanded = false;
    notifyListeners();
  }
}

final scanPanelProvider = Provider<ScanPanelController>((ref) {
  final panel = ScanPanelController();
  ref.onDispose(panel.dispose);
  return panel;
});

/// Comprobación pedida desde otra pantalla (la tarjeta de un proveedor): sin
/// diálogos y sin parámetros de navegación, sólo un aviso que la tira recoge en
/// cuanto tiene canales que comprobar.
final scanRequestProvider = Provider<ValueNotifier<String?>>((ref) {
  final request = ValueNotifier<String?>(null);
  ref.onDispose(request.dispose);
  return request;
});

/// El filtro «sólo los que responden»: preferencia de la app, no de una
/// pantalla, y se recuerda entre sesiones.
class OnlyWorkingChannels extends ChangeNotifier {
  static const _prefKey = 'only_working_channels';

  bool _value = false;
  bool get value => _value;

  /// La última elección del usuario, guardada.
  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getBool(_prefKey) ?? false;
    if (saved == _value) return;
    _value = saved;
    notifyListeners();
  }

  Future<void> set(bool value) async {
    if (_value == value) return;
    _value = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, value);
  }
}

final onlyWorkingChannelsProvider = Provider<OnlyWorkingChannels>((ref) {
  final only = OnlyWorkingChannels();
  unawaited(only.restore());
  ref.onDispose(only.dispose);
  return only;
});

/// El controlador con los servicios de la app: sobrevive a la pantalla que lo
/// miraba, así que cambiar de categoría, reproducir o cerrar la tira no lo
/// interrumpen.
final channelScanControllerProvider = Provider<ChannelScanController>((ref) {
  final controller = ChannelScanController(
    probe: ref.watch(channelProbeProvider),
    store: ref.watch(channelHealthStoreProvider),
    providerHealthStore: ref.watch(providerHealthStoreProvider),
    // Ocultar los muertos es cosa de la comprobación: sabe cuáles son. Las
    // pantallas se enteran por su propia suscripción a la base de datos.
    onHideDead: (ids) async {
      await ref.read(databaseProvider).setChannelsHidden(ids, hidden: true);
    },
  );
  ref.onDispose(controller.dispose);
  return controller;
});

/// Punto de entrada de la comprobación: se pide y ya. Nadie más toca el
/// controlador ni decide con qué canales se comprueba.
class ChannelCheck {
  ChannelCheck(this._ref);

  final Ref _ref;

  ChannelScanController get _controller =>
      _ref.read(channelScanControllerProvider);

  /// Los canales de [providerId] ya cargados, o null si todavía no se sabe nada
  /// de ese proveedor.
  List<db.Channel>? channelsOfProvider(String providerId) {
    final all = _controller.allChannels;
    if (all.isEmpty) return null;
    return all.where((channel) => channel.providerId == providerId).toList();
  }

  /// Comprueba lo que la pantalla tiene a la vista, o todo lo cargado si [all].
  ///
  /// Con una comprobación en marcha no empieza otra: asoma la tira, que es lo
  /// que el botón quiere decir mientras corre. Para medir otro ámbito está el
  /// CHECK de la tarjeta de un proveedor o las casillas de la tira.
  void start({bool? all}) {
    final controller = _controller;
    if (controller.visibleChannels.isEmpty && controller.allChannels.isEmpty) {
      return;
    }
    if (controller.running) {
      _ref.read(scanPanelProvider).show();
      return;
    }
    if (all != null) controller.setScope(all: all);
    controller.setScopeLabel(null);
    _run();
  }

  /// Comprueba todos los canales de un proveedor, que es lo que pide el CHECK
  /// de su tarjeta. Devuelve false si no tiene ninguno que comprobar.
  bool startProvider(String providerId) {
    final channels = channelsOfProvider(providerId);
    if (channels == null || channels.isEmpty) return false;
    final controller = _controller;
    controller.setTargets(visible: channels, all: channels);
    final name = controller.providerNames[providerId];
    controller.setScopeLabel(
      name == null || name.isEmpty ? 'this provider' : name,
    );
    _run();
    return true;
  }

  /// Comprueba exactamente los canales de una categoría, un proveedor o una
  /// lista de la barra lateral. Devuelve false si no hay nada que comprobar.
  ///
  /// El ámbito viaja con sus canales: la pantalla puede repintarse mientras se
  /// pulsa y lo medido tiene que ser lo que el usuario pidió.
  bool startCategory({
    required List<db.Channel> channels,
    required String label,
    String? key,
  }) {
    if (channels.isEmpty) return false;
    final controller = _controller;
    _showPanel();
    controller.startScope(channels, label: label, key: key);
    // Sembrar después de arrancar: `start()` limpia los recuentos y lo ya
    // medido vuelve a servir de punto de partida mientras corre la pasada.
    controller.seedCountsFromStore();
    return true;
  }

  void _run() {
    final controller = _controller;
    controller.seedCountsFromStore();
    _showPanel();
    unawaited(controller.start());
  }

  /// La tira abierta y los veredictos guardados cargados: pedir una
  /// comprobación es querer verla y sus etiquetas.
  void _showPanel() {
    _ref.read(scanPanelProvider).show();
    unawaited(
      _ref.read(channelScanControllerProvider).store.load().then((_) {
        _ref.read(groupHealthProvider).recompute();
      }),
    );
  }
}

final channelCheckProvider = Provider<ChannelCheck>(ChannelCheck.new);

/// Recuento por categoría de lo ya medido, compartido por todas las etiquetas
/// de la barra lateral: una pasada por cambio, no una por grupo en cada
/// repintado de las 13.000 filas.
class GroupHealthIndex extends ChangeNotifier {
  GroupHealthIndex(this._controller) {
    _controller.addListener(_schedule);
  }

  final ChannelScanController _controller;
  List<db.Channel> _channels = const [];
  Map<String, ({int checked, int working})> _index = const {};
  bool _scheduled = false;

  Map<String, ({int checked, int working})> get index => _index;

  /// Los canales cargados, que entrega la pantalla.
  void setChannels(List<db.Channel> channels) {
    if (identical(_channels, channels)) return;
    _channels = channels;
    _schedule();
  }

  void _schedule() {
    if (_scheduled) return;
    // Fuera del turno de construcción: los canales y los resultados llegan en
    // mitad del árbol de widgets.
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      recompute();
    });
  }

  void recompute() {
    if (!_controller.store.isLoaded) return;
    final next = _controller.groupHealth(_channels);
    _index = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _controller.removeListener(_schedule);
    super.dispose();
  }
}

final groupHealthProvider = Provider<GroupHealthIndex>((ref) {
  final index = GroupHealthIndex(ref.watch(channelScanControllerProvider));
  ref.onDispose(index.dispose);
  return index;
});

/// La tira, acoplada encima de la lista de canales.
///
/// La pantalla sólo entrega sus canales; aquí se decide con qué ámbito se
/// comprueba, se recoge lo que pida otra pantalla y se abre la tira.
class ChannelScanStripHost extends ConsumerStatefulWidget {
  final List<db.Channel> visibleChannels;
  final List<db.Channel> allChannels;
  final Map<String, String> providerNames;

  const ChannelScanStripHost({
    super.key,
    required this.visibleChannels,
    required this.allChannels,
    required this.providerNames,
  });

  @override
  ConsumerState<ChannelScanStripHost> createState() =>
      _ChannelScanStripHostState();
}

class _ChannelScanStripHostState extends ConsumerState<ChannelScanStripHost> {
  /// Guardado al montar: en `dispose` ya no se puede tocar `ref`.
  late final ValueNotifier<String?> _request;

  @override
  void initState() {
    super.initState();
    _request = ref.read(scanRequestProvider);
    _request.addListener(_serveRequest);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _handOverChannels();
    });
    // Los veredictos guardados llegan al leer la preferencia: sin esto, la
    // barra lateral aparecería sin etiquetas hasta el primer resultado.
    ref.read(channelScanControllerProvider).store.load().then((_) {
      if (mounted) ref.read(groupHealthProvider).recompute();
    });
  }

  @override
  void didUpdateWidget(covariant ChannelScanStripHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Fuera del turno de construcción: la lista de canales cambia al filtrar.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _handOverChannels();
    });
  }

  @override
  void dispose() {
    _request.removeListener(_serveRequest);
    super.dispose();
  }

  /// Los canales que la comprobación puede tocar los pone la pantalla.
  void _handOverChannels() {
    final controller = ref.read(channelScanControllerProvider);
    controller.setTargets(
      visible: widget.visibleChannels,
      all: widget.allChannels,
    );
    controller.setProviderNames(widget.providerNames);
    ref.read(groupHealthProvider).setChannels(widget.allChannels);
  }

  /// Atiende una comprobación pedida desde otra pantalla en cuanto hay canales
  /// que comprobar: hasta que la lista no se carga, el aviso espera.
  void _serveRequest() {
    final requested = ref.read(scanRequestProvider).value;
    if (requested == null || !mounted) return;
    final check = ref.read(channelCheckProvider);
    if (check.channelsOfProvider(requested) == null) return;
    ref.read(scanRequestProvider).value = null;
    if (check.startProvider(requested)) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('This provider has no channels loaded yet')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final request = ref.watch(scanRequestProvider);
    final panel = ref.watch(scanPanelProvider);
    return ListenableBuilder(
      listenable: Listenable.merge([request, panel]),
      builder: (context, _) {
        // El aviso puede estar puesto antes de que esta pantalla exista.
        if (request.value != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _serveRequest());
        }
        if (!panel.open) return const SizedBox.shrink();
        final onlyWorking = ref.watch(onlyWorkingChannelsProvider);
        // Abierta compite con la lista por el espacio que sobra: en ventanas
        // bajas las dos se ven en vez de que la tira empuje la lista fuera. Con
        // sitio de sobra se lleva lo que necesita, no la mitad.
        return Flexible(
          child: ListenableBuilder(
            listenable: onlyWorking,
            builder: (context, _) => ChannelHealthStrip(
              controller: ref.watch(channelScanControllerProvider),
              expanded: panel.expanded,
              onExpandedChanged: panel.setExpanded,
              onClose: panel.close,
              onRunScope: (all) =>
                  ref.read(channelCheckProvider).start(all: all),
              // El botón de la tira comprueba lo que se está viendo: pasa por el
              // mismo sitio que el CHECK, que además deja la etiqueta del ámbito
              // en su sitio (después de comprobar un proveedor diría su nombre).
              onRun: () => ref.read(channelCheckProvider).start(),
              onlyWorking: onlyWorking.value,
              onOnlyWorkingChanged: onlyWorking.set,
              // La tira nunca se lleva más de un tercio del alto: la lista (o la
              // guía) sigue teniendo espacio aunque esté desplegada.
              maxExpandedHeight: MediaQuery.sizeOf(context).height / 3,
            ),
          ),
        );
      },
    );
  }
}

/// El botón CHECK de la barra superior: pide la comprobación de lo que se ve y
/// nada más.
class ChannelCheckButton extends ConsumerWidget {
  const ChannelCheckButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(channelScanControllerProvider);
    final onlyWorking = ref.watch(onlyWorkingChannelsProvider);
    return ListenableBuilder(
      listenable: Listenable.merge([controller, onlyWorking]),
      builder: (context, _) {
        final running = controller.running;
        final only = onlyWorking.value;
        return IconButton(
          icon: running
              ? SizedBox(
                  width: 22,
                  height: 22,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          value: controller.progress,
                          color: const Color(0xFF6C5CE7),
                        ),
                      ),
                      const Icon(
                        Icons.network_check,
                        size: 14,
                        color: Color(0xFF6C5CE7),
                      ),
                    ],
                  ),
                )
              : Icon(
                  only ? Icons.network_check : Icons.network_check_outlined,
                  color: only ? const Color(0xFF6C5CE7) : Colors.white70,
                ),
          tooltip: running
              ? 'Checking the channels — the panel above the list shows how it '
                  'goes; you can keep watching and browsing'
              : only
                  ? 'Checking channels — only the ones that answer are shown'
                  : 'Check which channels play (the list stays usable)',
          onPressed: () => ref.read(channelCheckProvider).start(),
        );
      },
    );
  }
}

/// El icono CHECK de un nodo de la barra lateral (una categoría, un proveedor
/// o una lista de favoritos).
///
/// Aparece al pasar el ratón por la fila o al enfocarla con el mando, comprueba
/// **sólo** los canales de ese nodo y enseña un spinner mientras su pasada
/// corre. Mientras hay una comprobación en marcha, los demás se apagan: no se
/// pisa una medición con otra sin querer.
class CategoryCheckButton extends ConsumerStatefulWidget {
  const CategoryCheckButton({
    super.key,
    required this.label,
    required this.scopeKey,
    required this.channels,
    this.visible = false,
    this.canFocus = true,
    this.onFocusChange,
    this.size = 22,
  });

  /// Cómo se llama el nodo en los tooltips («Check News…»).
  final String label;

  /// Identidad del nodo: es lo que distingue el botón que pidió la pasada de
  /// los que sólo tienen que apagarse.
  final String scopeKey;

  /// Los canales del nodo, resueltos al pulsar: los proveedores que aún no se
  /// han cargado se traen en ese momento.
  final FutureOr<List<db.Channel>> Function() channels;

  /// Si la fila está bajo el ratón o tiene el foco. El spinner del ámbito
  /// activo se enseña aunque el ratón se haya ido.
  final bool visible;

  /// En el salón el foco se queda en la fila (la pulsación larga es la que
  /// comprueba): en el escritorio el icono se alcanza con Tab.
  final bool canFocus;
  final ValueChanged<bool>? onFocusChange;

  final double size;

  @override
  ConsumerState<CategoryCheckButton> createState() =>
      CategoryCheckButtonState();
}

class CategoryCheckButtonState extends ConsumerState<CategoryCheckButton> {
  bool _starting = false;

  /// Arranca la comprobación de este nodo. Es público para que la fila lo
  /// dispare con el mando (pulsación larga en CENTER) sin duplicar la lógica.
  Future<void> start() async {
    if (_starting) return;
    final controller = ref.read(channelScanControllerProvider);
    if (controller.busy) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    _starting = true;
    setState(() {});
    try {
      final channels = await widget.channels();
      if (!mounted) return;
      final started = ref.read(channelCheckProvider).startCategory(
            channels: channels,
            label: widget.label,
            key: widget.scopeKey,
          );
      if (!started) {
        messenger?.showSnackBar(
          SnackBar(
            content: Text('Nothing to check in ${widget.label}'),
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
            width: 320,
          ),
        );
      }
    } finally {
      _starting = false;
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(channelScanControllerProvider);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final busy = controller.busy;
        final mine = busy && controller.activeScopeKey == widget.scopeKey;
        final show = widget.visible || mine || _starting;
        // Escondido no se puede pulsar: si no, el hueco del icono se comería el
        // clic de la fila que hay debajo.
        final enabled = !busy && !_starting && show;
        final Widget child;
        if (!show) {
          child = const SizedBox.shrink();
        } else if (mine || _starting) {
          child = const SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(
              strokeWidth: 1.6,
              color: Color(0xFF6C5CE7),
            ),
          );
        } else {
          child = Icon(
            Icons.network_check_outlined,
            size: 13,
            color: enabled ? Colors.white38 : Colors.white12,
          );
        }
        return SizedBox(
          width: widget.size,
          height: widget.size,
          child: Tooltip(
            message: mine || _starting
                ? 'Checking ${widget.label}…'
                : busy
                    ? 'A check is already running — ${widget.label} waits its turn'
                    : 'Check the channels of ${widget.label}',
            child: InkWell(
              onTap: enabled ? start : null,
              canRequestFocus: widget.canFocus,
              onFocusChange: widget.onFocusChange,
              borderRadius: BorderRadius.circular(4),
              child: Center(child: child),
            ),
          ),
        );
      },
    );
  }
}

/// Etiqueta «9/10» de una categoría ya comprobada, o nada si no hay datos. La
/// pantalla sólo dice de qué categoría es: los números son de la comprobación.
class CategoryHealthBadge extends ConsumerWidget {
  final String healthKey;

  const CategoryHealthBadge({super.key, required this.healthKey});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final health = ref.watch(groupHealthProvider);
    return ListenableBuilder(
      listenable: health,
      builder: (context, _) {
        final tally = health.index[healthKey];
        if (tally == null || tally.checked == 0) return const SizedBox.shrink();
        final dead = tally.checked - tally.working;
        final color = dead == 0
            ? const Color(0xFF2ECC71)
            : tally.working == 0
                ? const Color(0xFFE74C3C)
                : const Color(0xFFE67E22);
        return Tooltip(
          message: 'Last check: ${tally.working} of ${tally.checked} answer',
          child: Container(
            margin: const EdgeInsets.only(left: 6),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '${tally.working}/${tally.checked}',
              style: TextStyle(fontSize: 10, color: color),
            ),
          ),
        );
      },
    );
  }
}

/// El punto de color con el veredicto del último chequeo, si lo hay. Va en la
/// fila del canal en las dos vistas (guía y lista): es donde el usuario mira
/// para saber qué canal va a abrir.
class ChannelHealthDot extends ConsumerWidget {
  final db.Channel channel;
  final double padding;

  const ChannelHealthDot({super.key, required this.channel, this.padding = 6});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(channelScanControllerProvider);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final verdict = controller.store.resultFor(channel);
        if (verdict == null) return const SizedBox.shrink();
        return Padding(
          padding: EdgeInsets.only(left: padding),
          child: Tooltip(
            message: 'Last check: ${verdict.label}\n${verdict.advice}',
            child: Icon(
              Icons.circle,
              size: 8,
              color: colorForStatus(verdict.status),
            ),
          ),
        );
      },
    );
  }
}
