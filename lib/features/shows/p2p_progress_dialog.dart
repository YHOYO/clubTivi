import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../data/services/p2p/rqbit_engine.dart';

/// Espera visible de la primera reproducción P2P: fase actual, progreso cuando
/// se conoce y un botón para cancelar sin dejar la app bloqueada.
class P2pProgressDialog extends StatelessWidget {
  final ValueListenable<P2pProgress> progress;
  final VoidCallback onCancel;

  const P2pProgressDialog({
    super.key,
    required this.progress,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1A2E),
      title: const Row(
        children: [
          Icon(Icons.hub_outlined, color: Color(0xFF6C5CE7)),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Preparing P2P stream',
              style: TextStyle(color: Colors.white, fontSize: 18),
            ),
          ),
        ],
      ),
      content: ValueListenableBuilder<P2pProgress>(
        valueListenable: progress,
        builder: (context, value, _) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value.message,
                key: const ValueKey('p2p-progress-message'),
                style: const TextStyle(color: Colors.white70, height: 1.4),
              ),
              const SizedBox(height: 14),
              LinearProgressIndicator(
                // Indeterminada mientras no se conozca el tamaño.
                value: value.fraction,
                backgroundColor: Colors.white12,
                color: const Color(0xFF6C5CE7),
                minHeight: 6,
              ),
              const SizedBox(height: 12),
              const Text(
                'The engine runs locally and downloads only the file you play. '
                'The first start can take a moment while peers are found.',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ],
          );
        },
      ),
      actions: [
        TextButton(
          key: const ValueKey('p2p-cancel'),
          onPressed: onCancel,
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
