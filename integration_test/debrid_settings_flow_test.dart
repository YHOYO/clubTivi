// Ejercicio real (motor y renderizado de Windows) de la ruta de UI de Fase 0:
// migración de claves antiguas, activar, desactivar conservando el token,
// reordenar la prioridad y quedarse sin ningún servicio habilitado.
//
//   flutter test integration_test/debrid_settings_flow_test.dart -d windows
//
// A diferencia del widget test, aquí corre el engine de escritorio con el
// plugin real de shared_preferences (con store en memoria) y el árbol completo
// de la pantalla, incluidos los diálogos y el scroll.
import 'dart:convert';

import 'package:clubtivi/data/services/debrid_settings.dart';
import 'package:clubtivi/features/settings/debrid_services_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Espera a que la carga asíncrona de preferencias pinte el estado.
  Future<void> waitFor(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (finder.evaluate().isNotEmpty) return;
    }
    fail('No apareció en pantalla: $finder');
  }

  Future<void> openScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: DebridServicesScreen()),
      ),
    );
    await waitFor(tester, find.text('Debrid Services'));
  }

  testWidgets(
    'debrid: migra, activa, desactiva, reordena y funciona sin servicios',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'shows_debrid_tokens': jsonEncode({
          'realDebrid': 'rd-token',
          'allDebrid': 'ad-token',
        }),
      });

      await openScreen(tester);

      // Migración: los dos servicios aparecen y el primero resuelve.
      await waitFor(tester, find.text('Enabled ✓ · resolves first'));
      expect(find.text('Enabled ✓ · priority 2'), findsOneWidget);
      expect(find.textContaining('Resolving with Real-Debrid'), findsOneWidget);

      var prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('shows_debrid_tokens'), isNull,
          reason: 'la clave heredada se migra y se borra');
      expect(prefs.getString(debridConfigsKey), contains('rd-token'));

      // Reordenar: AllDebrid pasa a resolver primero.
      await tester.tap(find.byKey(const ValueKey('debrid-down-realDebrid')));
      await waitFor(tester, find.textContaining('Resolving with AllDebrid'));
      expect(find.text('Enabled ✓ · resolves first'), findsOneWidget);

      // Desactivar sin borrar el token: sigue configurado.
      await tester.tap(find.byKey(const ValueKey('debrid-toggle-realDebrid')));
      await waitFor(tester, find.text('Disabled — token kept'));
      prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(debridConfigsKey), contains('rd-token'));
      expect(prefs.getString(debridConfigsKey), contains('"enabled":false'));

      // Desactivar el último servicio habilitado: modo sin debrid.
      await tester.tap(find.byKey(const ValueKey('debrid-toggle-allDebrid')));
      await waitFor(tester, find.textContaining('Debrid off'));
      expect(find.textContaining('marked unavailable'), findsOneWidget);

      // Un contenedor nuevo (proceso nuevo) relee el mismo estado.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await openScreen(tester);

      await waitFor(tester, find.textContaining('Debrid off'));
      expect(find.text('Disabled — token kept'), findsNWidgets(2),
          reason: 'ambos siguen configurados, solo apagados');
      expect(find.text('#1'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('debrid-card-allDebrid')),
          matching: find.text('#1'),
        ),
        findsOneWidget,
        reason: 'AllDebrid conserva la prioridad tras reordenar',
      );
    },
  );
}
