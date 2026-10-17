import 'dart:async';

import 'package:flutter/material.dart';

import 'buffer_progress.dart';
import 'player_service.dart';

/// Estado del canal: «OK» cuando hay imagen, y mientras carga, qué está
/// pasando de verdad (conectando, reconvirtiendo con ffmpeg, o cuánto búfer y
/// a qué velocidad).
///
/// El porcentaje es la ocupación del búfer respecto al objetivo de directo, no
/// una estimación de descarga: mpv no publica nada hasta que recibe datos, así
/// que durante la espera se muestra el tiempo transcurrido en lugar de un
/// número inventado.
class BufferStatusIndicator extends StatefulWidget {
  final PlayerService playerService;

  /// Barra de progreso bajo el texto, para sitios con espacio de sobra.
  final bool showBar;

  /// Ancho reservado para el texto, para que el panel no dé saltos.
  final double maxTextWidth;

  const BufferStatusIndicator({
    super.key,
    required this.playerService,
    this.showBar = true,
    this.maxTextWidth = 260,
  });

  @override
  State<BufferStatusIndicator> createState() => _BufferStatusIndicatorState();
}

class _BufferStatusIndicatorState extends State<BufferStatusIndicator> {
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<BufferProgress>? _progressSub;
  bool _buffering = false;
  BufferProgress? _progress;

  @override
  void initState() {
    super.initState();
    _buffering = widget.playerService.player.state.buffering;
    _progress = widget.playerService.bufferProgress;
    _bufferingSub = widget.playerService.bufferingStream.listen((buffering) {
      if (mounted) setState(() => _buffering = buffering);
    });
    _progressSub = widget.playerService.bufferProgressStream.listen((progress) {
      if (mounted) setState(() => _progress = progress);
    });
  }

  @override
  void dispose() {
    _bufferingSub?.cancel();
    _progressSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_buffering) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.signal_cellular_alt, size: 14, color: Colors.green),
          SizedBox(width: 4),
          Text('OK',
              style: TextStyle(color: Colors.green, fontSize: 11)),
        ],
      );
    }

    final progress = _progress;
    final fill = progress?.fill;
    final label = progress?.describe() ?? 'Cargando…';

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
              strokeWidth: 1.5, color: Colors.orangeAccent),
        ),
        const SizedBox(width: 6),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: widget.maxTextWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                    color: Colors.orangeAccent, fontSize: 11),
                overflow: TextOverflow.ellipsis,
              ),
              if (widget.showBar && fill != null) ...[
                const SizedBox(height: 2),
                SizedBox(
                  width: 120,
                  height: 3,
                  child: LinearProgressIndicator(
                    value: fill,
                    backgroundColor: Colors.white24,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                        Colors.orangeAccent),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
