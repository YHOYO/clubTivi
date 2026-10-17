// El diálogo de proveedores debe aceptar una lista M3U que esté en el disco,
// no sólo una URL: es la vía para probar listas descargadas sin montar nada.
import 'dart:io';

import 'package:clubtivi/features/providers/add_provider_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late File playlist;

  setUp(() {
    playlist = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}clubtivi-dialog-test.m3u8')
      ..writeAsStringSync('#EXTM3U\n#EXTINF:-1,Canal\nhttps://example.com/c.m3u8\n');
  });

  tearDown(() {
    if (playlist.existsSync()) playlist.deleteSync();
  });

  Future<FormState> openDialog(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showAddProviderDialog(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // El nombre es obligatorio: se rellena para que la validación que se mide
    // sea la del origen (URL o fichero), no la del nombre.
    await tester.enterText(find.byType(TextFormField).at(0), 'Test provider');
    await tester.pump();
    return tester.state<FormState>(find.byType(Form));
  }

  testWidgets('valida y anuncia un fichero de lista local', (tester) async {
    final form = await openDialog(tester);

    expect(find.text('Choose playlist file…'), findsOneWidget,
        reason: 'el diálogo debe ofrecer elegir un fichero');

    // Campo 0 = nombre, campo 1 = URL/fichero.
    await tester.enterText(find.byType(TextFormField).at(1), playlist.path);
    await tester.pump();

    expect(find.textContaining('Local playlist:'), findsOneWidget);
    expect(form.validate(), isTrue,
        reason: 'una ruta existente es un origen válido');
  });

  testWidgets('rechaza una ruta que no existe y lo dice', (tester) async {
    final form = await openDialog(tester);

    await tester.enterText(
        find.byType(TextFormField).at(1), r'C:\no\existe\tv.m3u8');
    await tester.pump();

    expect(find.textContaining('File not found:'), findsOneWidget);
    expect(form.validate(), isFalse);
    await tester.pump();
    expect(find.textContaining('http(s) URL or pick a playlist file'),
        findsOneWidget);
  });

  testWidgets('sigue aceptando una URL http', (tester) async {
    final form = await openDialog(tester);

    await tester.enterText(
        find.byType(TextFormField).at(1), 'https://example.com/tv.m3u8');
    await tester.pump();

    expect(find.textContaining('Local playlist:'), findsNothing);
    expect(form.validate(), isTrue);
  });
}
