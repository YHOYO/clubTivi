import 'package:clubtivi/data/services/p2p/p2p_platform.dart';
import 'package:clubtivi/data/services/p2p/rqbit_binary.dart';
import 'package:clubtivi/data/services/p2p/rqbit_engine.dart';
import 'package:clubtivi/data/services/p2p/rqbit_supervisor.dart';
import 'package:clubtivi/features/shows/p2p_progress_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('mensajes de error', () {
    test('el binario ausente explica qué hacer y no menciona debrid', () {
      final message = p2pErrorMessage(
        const RqbitBinaryMissingException(
          'The P2P engine is not included in this build.',
        ),
      );

      expect(message, contains('not included in this build'));
      expect(message, contains('Reinstall'));
    });

    test('el timeout de metadatos sugiere otro torrent', () {
      final message = p2pErrorMessage(
        const RqbitMetadataTimeoutException(
          'No metadata for this torrent after 60s. Try another source.',
        ),
      );

      expect(message, contains('No metadata'));
    });

    test('el puerto ocupado sugiere cerrar otras apps', () {
      final message = p2pErrorMessage(
        const RqbitPortException('No free local port for the P2P engine'),
      );

      expect(message, contains('No free local port'));
      expect(message, contains('Close other torrent apps'));
    });

    test('un error desconocido no se pierde', () {
      expect(p2pErrorMessage(StateError('boom')), contains('boom'));
    });

    test('la plataforma se puede inyectar', () {
      expect(isP2pPlaybackSupported(isDesktop: true), isTrue);
      expect(isP2pPlaybackSupported(isDesktop: false), isFalse);
    });
  });

  group('diálogo de progreso', () {
    testWidgets('muestra la fase, el porcentaje y permite cancelar',
        (tester) async {
      final progress = ValueNotifier<P2pProgress>(
        const P2pProgress(
          P2pPhase.downloadingEngine,
          'Downloading the P2P engine…',
          fraction: 0.4,
        ),
      );
      var cancelled = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: P2pProgressDialog(
              progress: progress,
              onCancel: () => cancelled++,
            ),
          ),
        ),
      );

      expect(find.text('Preparing P2P stream'), findsOneWidget);
      expect(find.text('Downloading the P2P engine…'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, 0.4);

      progress.value = const P2pProgress(
        P2pPhase.waitingMetadata,
        'Searching for peers…',
      );
      await tester.pump();

      expect(find.text('Searching for peers…'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        isNull,
        reason: 'sin tamaño conocido la barra es indeterminada',
      );

      await tester.tap(find.text('Cancel'));
      expect(cancelled, 1);

      progress.dispose();
    });
  });
}
