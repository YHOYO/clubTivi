// Ejercita la ruta de UI real de Ajustes → Debrid Services: activar,
// desactivar sin perder el token, reordenar y quedarse sin ningún servicio
// habilitado (modo sin debrid). La pantalla no se prueba aislada del estado:
// usa el mismo notifier que la app.
import 'dart:convert';

import 'package:clubtivi/data/datasources/remote/debrid_service.dart';
import 'package:clubtivi/data/services/debrid_settings.dart';
import 'package:clubtivi/features/settings/debrid_services_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<DebridSettingsNotifier> pumpScreen(WidgetTester tester) async {
    // Mismo camino que la app: se persiste y se lee, no se inyecta estado.
    SharedPreferences.setMockInitialValues({
      debridConfigsKey: jsonEncode({
        'version': 2,
        'services': [
          {'type': 'realDebrid', 'token': 'rd-token', 'enabled': true},
          {'type': 'allDebrid', 'token': 'ad-token', 'enabled': true},
        ],
      }),
    });
    final notifier = DebridSettingsNotifier();
    await notifier.load();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [debridSettingsProvider.overrideWith((ref) => notifier)],
        child: const MaterialApp(home: DebridServicesScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return notifier;
  }

  testWidgets('la lista arranca en orden de prioridad', (tester) async {
    await pumpScreen(tester);

    expect(find.text('Debrid Services'), findsOneWidget);
    expect(find.text('Enabled ✓ · resolves first'), findsOneWidget);
    expect(find.text('Enabled ✓ · priority 2'), findsOneWidget);
    expect(find.textContaining('Resolving with Real-Debrid'), findsOneWidget);
    expect(find.text('#1'), findsOneWidget);
    expect(find.text('#2'), findsOneWidget);
  });

  testWidgets('desactivar un servicio conserva su token', (tester) async {
    final notifier = await pumpScreen(tester);

    await tester.tap(find.byKey(const ValueKey('debrid-toggle-realDebrid')));
    await tester.pumpAndSettle();

    expect(
      notifier.state.configFor(DebridType.realDebrid)!.enabled,
      isFalse,
    );
    expect(
      notifier.state.configFor(DebridType.realDebrid)!.token,
      'rd-token',
      reason: 'el token no se borra al desactivar',
    );
    expect(find.text('Disabled — token kept'), findsOneWidget);
    expect(find.textContaining('Resolving with AllDebrid'), findsOneWidget);
  });

  testWidgets('reordenar cambia quién resuelve', (tester) async {
    final notifier = await pumpScreen(tester);

    await tester.tap(find.byKey(const ValueKey('debrid-down-realDebrid')));
    await tester.pumpAndSettle();

    expect(
      notifier.state.services.map((s) => s.type),
      [DebridType.allDebrid, DebridType.realDebrid],
    );
    expect(find.textContaining('Resolving with AllDebrid'), findsOneWidget);
  });

  testWidgets('sin ningún servicio habilitado muestra el modo sin debrid',
      (tester) async {
    final notifier = await pumpScreen(tester);

    await tester.tap(find.byKey(const ValueKey('debrid-toggle-realDebrid')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('debrid-toggle-allDebrid')));
    await tester.pumpAndSettle();

    expect(notifier.state.hasEnabledService, isFalse);
    expect(notifier.state.configuredCount, 2, reason: 'nada se borró');
    expect(find.textContaining('Debrid off'), findsOneWidget);
    expect(
      find.textContaining('marked unavailable'),
      findsOneWidget,
      reason: 'la app avisa de que las fuentes con debrid no se podrán abrir',
    );
  });
}
