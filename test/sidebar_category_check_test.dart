// El CHECK de un nodo de la barra lateral, sin montar la pantalla entera: lo
// que hay que garantizar es el contrato del botón. Pulsarlo mide **sólo** los
// canales de su nodo, mientras corre deja su spinner y apaga los demás, y un
// nodo vacío lo dice en vez de arrancar una pasada sin canales.
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/channel_probe_service.dart';
import 'package:clubtivi/features/channels/channel_scan_host.dart';
import 'package:clubtivi/features/providers/provider_manager.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Sonda falsa: apunta qué canales se le piden y no contesta hasta que pasa
/// [delay] (tiempo del reloj de la prueba), para poder mirar la comprobación en
/// marcha antes de que acabe.
class _SlowProbe extends ChannelProbeService {
  /// Lo que tarda en contestar: el reloj de la prueba lo hace pasar de golpe.
  static const delay = Duration(seconds: 30);

  final scans = <List<String>>[];

  @override
  Future<void> scan(
    List<db.Channel> channels, {
    int concurrency = 6,
    Duration timeout = const Duration(seconds: 8),
    bool retryTimeouts = true,
    Duration retryTimeout = const Duration(seconds: 15),
    int maxRetries = ChannelProbeService.defaultMaxRetries,
    bool adaptConcurrency = true,
    required void Function(
      db.Channel channel,
      ProbeResult result,
      int done,
      int total,
    )
    onResult,
    void Function(int pending)? onRetryStart,
    void Function(db.Channel channel, ProbeResult result, int done, int total)?
    onRetryResult,
    void Function(int limit, int maxLimit)? onConcurrencyChanged,
    bool Function()? isCancelled,
  }) async {
    scans.add([for (final channel in channels) channel.id]);
    final total = channels.length;
    await Future<void>.delayed(delay);
    if (isCancelled?.call() ?? false) return;
    var done = 0;
    for (final channel in channels) {
      done++;
      onResult(
        channel,
        const ProbeResult(status: ProbeStatus.ok, httpStatus: 200),
        done,
        total,
      );
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late db.AppDatabase database;
  late _SlowProbe probe;
  late List<db.Channel> news;
  late List<db.Channel> films;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    probe = _SlowProbe();

    await database.upsertProvider(
      db.ProvidersCompanion.insert(id: 'p1', name: 'Provider', type: 'm3u'),
    );
    await database.upsertChannels([
      for (final entry in const {
        'n1': 'News One',
        'n2': 'News Two',
        'f1': 'Film One',
        'f2': 'Film Two',
      }.entries)
        db.ChannelsCompanion.insert(
          id: entry.key,
          providerId: 'p1',
          name: entry.value,
          streamUrl: 'http://example.com/${entry.key}.m3u8',
          groupTitle: Value(entry.value.startsWith('News') ? 'News' : 'Films'),
        ),
    ]);
    final all = await database.getAllChannels();
    news = all.where((c) => c.groupTitle == 'News').toList();
    films = all.where((c) => c.groupTitle == 'Films').toList();
  });

  tearDown(() async => database.close());

  /// Los dos botones como los pinta una fila de la barra lateral: uno por nodo,
  /// ambos a la vista para poder mirar cómo se apagan entre ellos.
  Future<ProviderContainer> pumpButtons(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: <Override>[
        databaseProvider.overrideWithValue(database),
        channelProbeProvider.overrideWithValue(probe),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: Row(
              children: [
                CategoryCheckButton(
                  label: 'News',
                  scopeKey: 'group:News',
                  channels: () => news,
                  visible: true,
                ),
                CategoryCheckButton(
                  label: 'Films',
                  scopeKey: 'group:Films',
                  channels: () => films,
                  visible: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return container;
  }

  testWidgets('el CHECK mide sólo los canales de su nodo y apaga los demás',
      (tester) async {
    final container = await pumpButtons(tester);
    final controller = container.read(channelScanControllerProvider);

    expect(find.byIcon(Icons.network_check_outlined), findsNWidgets(2));
    await tester.tap(find.byTooltip('Check the channels of News'));
    await tester.pump();
    await tester.pump();

    expect(probe.scans, hasLength(1));
    expect(probe.scans.single, unorderedEquals(['n1', 'n2']),
        reason: 'se miden los canales de News, ni uno de otra categoría');
    expect(controller.activeScopeKey, 'group:News');
    expect(controller.busy, isTrue);
    expect(controller.scopeLabel, 'News');
    expect(find.byTooltip('Checking News…'), findsOneWidget,
        reason: 'el botón dice qué está midiendo');

    // El que corre deja paso a su spinner; el otro queda apagado.
    expect(find.byIcon(Icons.network_check_outlined), findsOneWidget);
    expect(
      find.byTooltip('A check is already running — Films waits its turn'),
      findsOneWidget,
      reason: 'los demás CHECK se deshabilitan mientras corre la comprobación',
    );
    await tester.tap(
      find.byTooltip('A check is already running — Films waits its turn'),
    );
    await tester.pump();
    expect(probe.scans, hasLength(1), reason: 'un CHECK apagado no arranca nada');

    // El reloj de la prueba hace pasar la sonda lenta; el spinner no para
    // nunca por sí solo, así que se bombea hasta que la pasada termina.
    await tester.pump(const Duration(seconds: 31));
    for (var i = 0; i < 10 && controller.busy; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(controller.busy, isFalse);
    expect(controller.activeScopeKey, isNull);
    expect(probe.scans, hasLength(1),
        reason: 'terminar una categoría no encola ninguna otra pasada');
    expect(find.byIcon(Icons.network_check_outlined), findsNWidgets(2),
        reason: 'al terminar, los dos CHECK vuelven a estar disponibles');

    // El guardado de los veredictos va con retardo; se deja vencer para no
    // terminar la prueba con temporizadores vivos.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('un nodo sin canales lo dice en vez de arrancar una pasada',
      (tester) async {
    final container = await pumpButtons(tester);
    final empty = CategoryCheckButton(
      label: 'Empty',
      scopeKey: 'group:Empty',
      channels: () => const <db.Channel>[],
      visible: true,
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(body: Center(child: empty)),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Check the channels of Empty'));
    await tester.pump();
    await tester.pump();

    expect(probe.scans, isEmpty);
    expect(container.read(channelScanControllerProvider).busy, isFalse);
    expect(find.text('Nothing to check in Empty'), findsOneWidget);
  });

  testWidgets('sin el ratón encima el icono no ocupa el sitio de la fila',
      (tester) async {
    final container = ProviderContainer(
      overrides: <Override>[
        databaseProvider.overrideWithValue(database),
        channelProbeProvider.overrideWithValue(probe),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: CategoryCheckButton(
              label: 'News',
              scopeKey: 'group:News',
              channels: () => news,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.network_check_outlined), findsNothing,
        reason: 'el CHECK asoma al pasar el ratón por la fila, no antes');
    final box = tester.getSize(find.byType(CategoryCheckButton));
    expect(box.width, 22, reason: 'pero su hueco está reservado: la fila no '
        'se mueve al acercarse');
  });
}
