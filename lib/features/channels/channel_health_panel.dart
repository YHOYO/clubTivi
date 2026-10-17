import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/services/channel_probe_service.dart';
import 'channel_scan_controller.dart';

/// Verde para lo que se ve, azul para lo que sólo responde solo, ámbar para lo
/// que puede responder y rojo para lo que no.
Color colorForStatus(ProbeStatus status) => switch (status) {
  ProbeStatus.ok => const Color(0xFF2ECC71),
  ProbeStatus.slow => const Color(0xFF3498DB),
  ProbeStatus.timeout => const Color(0xFFE67E22),
  ProbeStatus.notAPlaylist => const Color(0xFFE67E22),
  ProbeStatus.tls => const Color(0xFF9B59B6),
  ProbeStatus.blocked => const Color(0xFF9B59B6),
  _ => const Color(0xFFE74C3C),
};

/// Nombre legible del proveedor cuando el ámbito es uno solo.
String providerTitle(Map<String, String> providerNames) =>
    providerNames.isEmpty ? 'the provider' : providerNames.values.first;

/// Todo lo que se puede decir de una comprobación en curso o terminada.
///
/// Sólo lo pinta la tira acoplada a la lista de canales: al desaparecer el
/// diálogo quedó un único sitio donde mirar una comprobación, así que lo que
/// aquí se pinta es lo que ve el usuario, sin variantes por envoltorio.
class ChannelHealthPanel extends StatelessWidget {
  final ChannelScanController controller;

  /// Párrafo de presentación cuando aún no se ha medido nada.
  final bool showIntro;

  /// El filtro «sólo los que responden»: lo guarda la app, no el panel.
  final bool onlyWorking;
  final ValueChanged<bool>? onOnlyWorkingChanged;

  /// El usuario eligió con qué ámbito comprobar (false: lo que se ve ahora,
  /// true: todos los canales cargados). La comprobación es quien vuelve a
  /// acotar los canales y arranca: el panel no conoce los filtros.
  final ValueChanged<bool>? onRunScope;

  /// Alto máximo del desglose por proveedor y de la lista de fallos, para no
  /// comerse el espacio de la lista de canales.
  static const _detailsHeight = 160.0;

  const ChannelHealthPanel({
    super.key,
    required this.controller,
    this.showIntro = true,
    this.onlyWorking = false,
    this.onOnlyWorkingChanged,
    this.onRunScope,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          // En ventanas estrechas manda el estado, no las explicaciones.
          final narrow = constraints.maxWidth < 720;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showIntro && !controller.running && controller.doneCount == 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(_intro(), style: _bodyStyle),
                ),
              if (controller.running || controller.doneCount > 0)
                _statusLine(narrow),
              if (controller.running || controller.doneCount > 0) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: ProbeStatus.values
                      .where((s) => (controller.counts[s] ?? 0) > 0)
                      .map(
                        (s) => Chip(
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          backgroundColor: colorForStatus(
                            s,
                          ).withValues(alpha: 0.2),
                          label: Text(
                            '${s.name}: ${controller.counts[s]}',
                            style: TextStyle(
                              fontSize: 11,
                              color: colorForStatus(s),
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ],
              if (controller.throttledTo != null && controller.running) ...[
                const SizedBox(height: 6),
                Text(
                  'The server is refusing too many requests at once: the check '
                  'slowed down to ${controller.throttledTo} at a time.',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFFE67E22),
                  ),
                ),
              ],
              if (controller.doneCount > 0) ...[
                const SizedBox(height: 4),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: onlyWorking,
                  title: const Text(
                    'Show only the channels that respond',
                    style: TextStyle(fontSize: 13),
                  ),
                  subtitle: const Text(
                    'The list keeps the last verdict; scanning again refreshes it.',
                    style: TextStyle(fontSize: 11, color: Colors.white38),
                  ),
                  onChanged: onOnlyWorkingChanged,
                ),
              ],
              // El ámbito se elige siempre que haya más de uno y no esté
              // corriendo: es la manera de comprobar la lista entera del
              // proveedor sin salir de la pantalla.
              if (!controller.running && !controller.singleScope)
                _scopeChoice(),
              if (showIntro && !controller.running) _retryOption(),
              if (controller.doneCount > 2 &&
                  controller.providerBreakdown.length > 1)
                _providerSection(),
              if (controller.failures.isNotEmpty) ...[
                _failuresSection(),
                const SizedBox(height: 4),
                _actions(context, narrow),
              ],
            ],
          );
        },
      ),
    );
  }

  static const _bodyStyle = TextStyle(color: Colors.white70, fontSize: 12);
  static const _sectionTitle = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.bold,
    color: Colors.white70,
  );

  String _intro() {
    if (controller.singleScope) {
      return '${controller.visibleChannels.length} channels of '
          '${providerTitle(controller.providerNames)} will be contacted with a '
          'small ranged request — a few kilobytes that reveal a 403, a dead '
          'link or a server that never answers, without opening the player. '
          'Whatever fails is then retried one at a time and with more patience.';
    }
    return 'Each channel is contacted with a small ranged request: a few '
        'kilobytes that reveal a 403, a dead link or a server that never '
        'answers, without opening the player. Whatever fails is then retried '
        'one at a time and with more patience, to tell a dead channel apart '
        'from a server that chokes when several requests arrive at once.';
  }

  Widget _statusLine(bool narrow) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(value: controller.progress),
        const SizedBox(height: 8),
        Text(
          '${controller.doneCount} / ${controller.total} checked · '
          '${controller.okCount} working · ${controller.deadCount} failing',
          style: const TextStyle(fontSize: 13, color: Colors.white),
        ),
        if (!narrow && controller.retryTotal > 0) ...[
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: controller.retryProgress,
            color: const Color(0xFF3498DB),
            backgroundColor: const Color(0xFF16213E),
          ),
          const SizedBox(height: 4),
          Text(
            'Second pass, one at a time and with more patience: '
            '${controller.retryDone} / ${controller.retryTotal} — the ones that '
            'answer only this way are marked as slow, not as dead. Channels '
            'that answer 404 or a web page are not retried: that answer is '
            'final.',
            style: const TextStyle(fontSize: 11, color: Colors.white54),
          ),
        ],
      ],
    );
  }

  /// Ámbito de la comprobación: la lista que se ve o todo lo cargado.
  Widget _scopeChoice() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        _scopeTile(
          all: false,
          title: 'Channels shown now (${controller.visibleChannels.length})',
        ),
        _scopeTile(
          all: true,
          title: 'Every loaded channel (${controller.allChannels.length})',
          subtitle:
              'Roughly one second per channel, six at a time, plus a '
              'second pass for the ones that fail.',
        ),
      ],
    );
  }

  /// Segunda pasada: lo que conviene decidir antes de empezar.
  Widget _retryOption() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: controller.retrySecondPass,
          title: const Text(
            'Second pass for the ones that fail',
            style: TextStyle(fontSize: 13),
          ),
          subtitle: const Text(
            'One at a time and with more patience: this is what tells a dead '
            'channel from a server that chokes on parallel requests. It is the '
            'slow part of the scan.',
            style: TextStyle(fontSize: 11, color: Colors.white38),
          ),
          onChanged: controller.setRetrySecondPass,
        ),
      ],
    );
  }

  Widget _scopeTile({
    required bool all,
    required String title,
    String? subtitle,
  }) {
    final selected = controller.scanAllChannels == all;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_off,
        size: 18,
        color: selected ? const Color(0xFF6C5CE7) : Colors.white38,
      ),
      title: Text(title, style: const TextStyle(fontSize: 13)),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              style: const TextStyle(fontSize: 11, color: Colors.white38),
            ),
      onTap: () {
        controller.setScope(all: all);
        // Elegir ámbito es pedir la comprobación: se vuelve a acotar con lo que
        // hay ahora en la lista, no con lo que había al abrir la tira.
        onRunScope?.call(all);
      },
    );
  }

  Widget _providerSection() {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: _detailsHeight),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 12),
            const Text('By provider', style: _sectionTitle),
            const SizedBox(height: 4),
            ...controller.providerBreakdown.values.map(
              (summary) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      summary.providerName,
                      style: const TextStyle(fontSize: 12, color: Colors.white),
                    ),
                    Text(
                      summary.label,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.white54,
                      ),
                    ),
                    if (summary.blamesTheNetwork)
                      const Text(
                        'Your network is blocking these domains: the '
                        'certificate cannot be verified and the answer is a '
                        'blocking page. Not the app, not the channel.',
                        style: TextStyle(
                          fontSize: 11,
                          color: Color(0xFFE67E22),
                        ),
                      )
                    else if (summary.blamesTheServer)
                      const Text(
                        'Most failures are the server refusing: not the '
                        'channels.',
                        style: TextStyle(
                          fontSize: 11,
                          color: Color(0xFFE67E22),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _failuresSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        const Text('Not working', style: _sectionTitle),
        const SizedBox(height: 4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: _detailsHeight),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: controller.failures.length,
            itemBuilder: (context, i) {
              final entry = controller.failures[i];
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  Icons.circle,
                  size: 10,
                  color: colorForStatus(entry.value.status),
                ),
                title: Text(
                  entry.key.name,
                  style: const TextStyle(fontSize: 13),
                ),
                subtitle: Text(
                  '${entry.value.label} — ${entry.value.advice}',
                  style: const TextStyle(fontSize: 11, color: Colors.white54),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _actions(BuildContext context, bool narrow) {
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      alignment: WrapAlignment.end,
      children: [
        if (controller.failures.isNotEmpty)
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: controller.report()));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Report copied to the clipboard')),
              );
            },
            child: Text(narrow ? 'COPY' : 'COPY REPORT'),
          ),
        if (controller.failures.isNotEmpty && !controller.hiddenApplied)
          TextButton(
            onPressed: () async {
              final hidden = await controller.hideDead();
              if (!context.mounted || hidden == 0) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('$hidden dead channels hidden from the lists.'),
                  duration: const Duration(seconds: 6),
                ),
              );
            },
            child: Text(
              narrow
                  ? 'HIDE ${controller.failures.length}'
                  : 'HIDE ${controller.failures.length} DEAD',
            ),
          ),
      ],
    );
  }
}

/// La comprobación, acoplada a la lista de canales en vez de taparla.
///
/// Plegada ocupa una línea con el avance; desplegada añade el detalle. En
/// ningún estado bloquea la lista ni el reproductor: se puede cambiar de
/// categoría y seguir viendo el canal mientras corre.
class ChannelHealthStrip extends StatelessWidget {
  final ChannelScanController controller;
  final bool expanded;
  final ValueChanged<bool> onExpandedChanged;

  /// Cierra la tira (la comprobación, si sigue, termina igualmente).
  final VoidCallback onClose;

  /// Alto máximo que puede ocupar desplegada, para no comerse la lista.
  final double maxExpandedHeight;

  /// El usuario eligió ámbito en las casillas del panel: se vuelven a acotar
  /// los canales con lo que hay en ese momento y se relanza la comprobación.
  final ValueChanged<bool>? onRunScope;

  /// El filtro «sólo los que responden», que guarda la app.
  final bool onlyWorking;
  final ValueChanged<bool>? onOnlyWorkingChanged;

  /// START / CHECK AGAIN. Si no lo da nadie, comprobar directamente.
  final VoidCallback? onRun;

  const ChannelHealthStrip({
    super.key,
    required this.controller,
    required this.expanded,
    required this.onExpandedChanged,
    required this.onClose,
    this.onRunScope,
    this.onRun,
    this.onlyWorking = false,
    this.onOnlyWorkingChanged,
    this.maxExpandedHeight = 320,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final running = controller.running;
        final measured = controller.doneCount > 0;
        return Material(
          color: const Color(0xFF16213E),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                onTap: () => onExpandedChanged(!expanded),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      // En ventanas estrechas manda el estado: fuera los recuentos
                      // y la barra, que es lo que desbordaba la fila.
                      final narrow = constraints.maxWidth < 760;
                      return Row(
                        children: [
                          if (running)
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.8,
                                color: Color(0xFF6C5CE7),
                              ),
                            )
                          else
                            Icon(
                              measured
                                  ? Icons.fact_check_rounded
                                  : Icons.network_check,
                              size: 16,
                              color: const Color(0xFF6C5CE7),
                            ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              _headline(running, measured),
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.white70,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (measured && !narrow) ...[
                            const SizedBox(width: 8),
                            _miniCounts(),
                          ],
                          if (!narrow) ...[
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 120,
                              child: LinearProgressIndicator(
                                value: controller.progress,
                              ),
                            ),
                          ],
                          const Spacer(),
                          if (running)
                            TextButton(
                              onPressed: controller.stop,
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                              ),
                              child: const Text(
                                'STOP',
                                style: TextStyle(fontSize: 11),
                              ),
                            )
                          else
                            TextButton(
                              onPressed: onRun ?? controller.start,
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                              ),
                              child: Text(
                                measured ? 'CHECK AGAIN' : 'START',
                                style: const TextStyle(fontSize: 11),
                              ),
                            ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: expanded ? 'Collapse' : 'Expand',
                            icon: Icon(
                              expanded
                                  ? Icons.keyboard_arrow_up_rounded
                                  : Icons.keyboard_arrow_down_rounded,
                              size: 18,
                              color: Colors.white54,
                            ),
                            onPressed: () => onExpandedChanged(!expanded),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: 'Close the check panel',
                            icon: const Icon(
                              Icons.close_rounded,
                              size: 16,
                              color: Colors.white54,
                            ),
                            onPressed: onClose,
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
              if (expanded)
                // Flexible: si la ventana es baja, la tira se encoge y el resto
                // se desplaza dentro, en vez de empujar la lista fuera de la
                // pantalla.
                Flexible(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: maxExpandedHeight),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: ChannelHealthPanel(
                        controller: controller,
                        showIntro: !running && !measured,
                        onlyWorking: onlyWorking,
                        onOnlyWorkingChanged: onOnlyWorkingChanged,
                        onRunScope: onRunScope,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  String _headline(bool running, bool measured) {
    if (!running && !measured) {
      return 'Checking the channels tells you which ones actually answer, '
          'before you click them.';
    }
    return '${running ? 'Checking' : 'Checked'} ${controller.scopeLabel} '
        'while you keep watching. The list stays usable.';
  }

  Widget _miniCounts() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, size: 8, color: colorForStatus(ProbeStatus.ok)),
        const SizedBox(width: 4),
        Text(
          '${controller.okCount}',
          style: const TextStyle(fontSize: 11, color: Colors.white70),
        ),
        const SizedBox(width: 8),
        Icon(
          Icons.circle,
          size: 8,
          color: colorForStatus(ProbeStatus.notFound),
        ),
        const SizedBox(width: 4),
        Text(
          '${controller.deadCount}',
          style: const TextStyle(fontSize: 11, color: Colors.white70),
        ),
      ],
    );
  }
}
