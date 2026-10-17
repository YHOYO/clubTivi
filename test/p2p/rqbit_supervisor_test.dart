// El supervisor se prueba con un proceso falso y un sondeo inyectado: lo que
// importa es la política (puerto, espera, reinicio, cierre), no el binario.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clubtivi/data/services/p2p/rqbit_supervisor.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeProcess implements RqbitProcessHandle {
  _FakeProcess(this.pid);

  @override
  final int pid;

  final Completer<int> _exit = Completer<int>();
  bool killed = false;

  @override
  Stream<List<int>> get stdout => const Stream.empty();

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  Future<int> get exitCode => _exit.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    die(-1);
    return true;
  }

  void die(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }
}

void main() {
  late Directory root;
  late String downloads;
  late String state;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('rqbit-supervisor-');
    downloads = '${root.path}${Platform.pathSeparator}downloads';
    state = '${root.path}${Platform.pathSeparator}session';
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  RqbitSupervisor supervisor({
    required Future<RqbitProcessHandle> Function(String, List<String>) start,
    RqbitReadinessProbe? probe,
    RqbitPortAllocator? port,
    Duration startTimeout = const Duration(seconds: 2),
    int maxRestarts = 0,
    int? preferredPort,
    int? downloadLimit,
    int? uploadLimit,
  }) {
    return RqbitSupervisor(
      downloadDirectory: downloads,
      stateDirectory: state,
      startProcess: start,
      allocatePort: port ?? () async => 45678,
      preferredPort: preferredPort,
      downloadLimitBytesPerSecond: downloadLimit,
      uploadLimitBytesPerSecond: uploadLimit,
      probe: probe ?? (_) async => true,
      startTimeout: startTimeout,
      probeInterval: const Duration(milliseconds: 10),
      restartDelay: Duration.zero,
      maxRestarts: maxRestarts,
    );
  }

  test('arranca en un puerto libre y conoce el pid en disco', () async {
    final processes = <_FakeProcess>[];
    late List<String> args;
    late String executable;
    final supervisorInstance = supervisor(
      start: (exe, arguments) async {
        executable = exe;
        args = arguments;
        final process = _FakeProcess(4000 + processes.length);
        processes.add(process);
        return process;
      },
    );
    addTearDown(supervisorInstance.stop);

    final uri = await supervisorInstance.ensureRunning('C:/app/rqbit.exe');

    expect(executable, 'C:/app/rqbit.exe');
    expect(uri.toString(), 'http://127.0.0.1:45678');
    expect(
      args,
      containsAllInOrder([
        '--http-api-listen-addr',
        '127.0.0.1:45678',
        'server',
        'start',
        '--persistence-location',
        state,
        downloads,
      ]),
    );
    expect(supervisorInstance.isRunning, isTrue);
    expect(supervisorInstance.processId, 4000);

    final pidFile = File('$state/rqbit-sidecar.json');
    expect(await pidFile.exists(), isTrue);
    final pidJson = jsonDecode(await pidFile.readAsString()) as Map;
    expect(pidJson['pid'], 4000);
    expect(pidJson['port'], 45678);

    await supervisorInstance.stop();
    expect(processes.single.killed, isTrue);
    expect(await pidFile.exists(), isFalse);
  });

  test('dos reproducciones simultáneas comparten un solo arranque', () async {
    var starts = 0;
    final supervisorInstance = supervisor(
      start: (exe, args) async {
        starts++;
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return _FakeProcess(5000 + starts);
      },
    );
    addTearDown(supervisorInstance.stop);

    final uris = await Future.wait([
      supervisorInstance.ensureRunning('rqbit.exe'),
      supervisorInstance.ensureRunning('rqbit.exe'),
      supervisorInstance.ensureRunning('rqbit.exe'),
    ]);

    expect(starts, 1);
    expect(uris.map((uri) => uri.toString()).toSet(), hasLength(1));
  });

  test('si no responde a tiempo, el error es legible y mata el proceso', () async {
    final processes = <_FakeProcess>[];
    final supervisorInstance = supervisor(
      start: (exe, args) async {
        final process = _FakeProcess(6000 + processes.length);
        processes.add(process);
        return process;
      },
      probe: (_) async => false,
      startTimeout: const Duration(milliseconds: 120),
    );

    await expectLater(
      supervisorInstance.ensureRunning('rqbit.exe'),
      throwsA(
        isA<RqbitStartException>().having(
          (error) => error.message,
          'message',
          contains('did not answer'),
        ),
      ),
    );
    expect(processes.single.killed, isTrue);
    expect(supervisorInstance.isRunning, isFalse);
  });

  test('un proceso que muere al arrancar se reintenta y se reporta', () async {
    var starts = 0;
    final supervisorInstance = supervisor(
      start: (exe, args) async {
        starts++;
        final process = _FakeProcess(7000 + starts)..die(1);
        return process;
      },
      maxRestarts: 2,
    );

    await expectLater(
      supervisorInstance.ensureRunning('rqbit.exe'),
      throwsA(
        isA<RqbitStartException>().having(
          (error) => error.message,
          'message',
          contains('exited'),
        ),
      ),
    );
    expect(starts, 3, reason: 'intento inicial + maxRestarts');
  });

  test('si muere con la app abierta, se reinicia solo', () async {
    final processes = <_FakeProcess>[];
    var port = 45678;
    final supervisorInstance = supervisor(
      start: (exe, args) async {
        final process = _FakeProcess(8000 + processes.length);
        processes.add(process);
        return process;
      },
      port: () async => port++,
      maxRestarts: 2,
    );
    addTearDown(supervisorInstance.stop);

    final first = await supervisorInstance.ensureRunning('rqbit.exe');
    expect(first.port, 45678);

    processes.single.die(9);

    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (processes.length < 2 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(processes, hasLength(2));
    expect(supervisorInstance.isRunning, isTrue);
    expect(supervisorInstance.baseUri!.port, 45679);
  });

  test('stop para el motor y el siguiente arranque vuelve a funcionar',
      () async {
    final processes = <_FakeProcess>[];
    final supervisorInstance = supervisor(
      start: (exe, args) async {
        final process = _FakeProcess(9000 + processes.length);
        processes.add(process);
        return process;
      },
    );
    addTearDown(supervisorInstance.dispose);

    await supervisorInstance.ensureRunning('rqbit.exe');
    await supervisorInstance.stop();
    await supervisorInstance.stop();

    expect(supervisorInstance.isRunning, isFalse);

    final uri = await supervisorInstance.ensureRunning('rqbit.exe');
    expect(supervisorInstance.isRunning, isTrue);
    expect(uri.toString(), 'http://127.0.0.1:45678');
    expect(processes, hasLength(2));
  });

  test('dispose es definitivo: ya no arranca nada', () async {
    final supervisorInstance = supervisor(
      start: (exe, args) async => _FakeProcess(9200),
    );

    await supervisorInstance.ensureRunning('rqbit.exe');
    await supervisorInstance.dispose();

    expect(supervisorInstance.isRunning, isFalse);
    expect(
      () => supervisorInstance.ensureRunning('rqbit.exe'),
      throwsA(isA<RqbitStartException>()),
    );
  });

  test('un puerto fijo configurado se usa sin pedir puerto libre', () async {
    var askedForFreePort = false;
    late List<String> args;

    final automatic = supervisor(
      start: (exe, arguments) async {
        args = arguments;
        return _FakeProcess(9300);
      },
      port: () async {
        askedForFreePort = true;
        return 11111;
      },
    );
    addTearDown(automatic.dispose);

    await automatic.ensureRunning('rqbit.exe');
    expect(askedForFreePort, isTrue);
    expect(args, contains('127.0.0.1:11111'));

    // Con puerto fijo, el reparto automático ni se toca.
    askedForFreePort = false;
    final fixed = supervisor(
      start: (exe, arguments) async {
        args = arguments;
        return _FakeProcess(9301);
      },
      port: () async {
        askedForFreePort = true;
        return 11112;
      },
      preferredPort: 33123,
    );
    addTearDown(fixed.dispose);

    final uri = await fixed.ensureRunning('rqbit.exe');
    expect(askedForFreePort, isFalse);
    expect(uri.port, 33123);
    expect(args, contains('127.0.0.1:33123'));
  });

  test('un puerto fijo ocupado se dice antes de arrancar el proceso', () async {
    final blocker = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(blocker.close);
    var started = false;
    final supervisorInstance = supervisor(
      start: (exe, args) async {
        started = true;
        return _FakeProcess(9400);
      },
      preferredPort: blocker.port,
    );

    await expectLater(
      supervisorInstance.ensureRunning('rqbit.exe'),
      throwsA(
        isA<RqbitPortException>().having(
          (error) => error.message,
          'message',
          contains('${blocker.port}'),
        ),
      ),
    );
    expect(started, isFalse);
  });

  test('los límites de velocidad llegan como flags globales de rqbit',
      () async {
    late List<String> args;
    final supervisorInstance = supervisor(
      start: (exe, arguments) async {
        args = arguments;
        return _FakeProcess(9500);
      },
      downloadLimit: 1048576,
      uploadLimit: 262144,
    );
    addTearDown(supervisorInstance.dispose);

    await supervisorInstance.ensureRunning('rqbit.exe');

    expect(args, containsAllInOrder(['--ratelimit-download', '1048576']));
    expect(args, containsAllInOrder(['--ratelimit-upload', '262144']));
    expect(
      args.indexOf('--ratelimit-download'),
      lessThan(args.indexOf('server')),
      reason: 'son flags globales, van antes del subcomando',
    );
  });

  test('sin límites no se añaden flags', () async {
    late List<String> args;
    final supervisorInstance = supervisor(
      start: (exe, arguments) async {
        args = arguments;
        return _FakeProcess(9600);
      },
    );
    addTearDown(supervisorInstance.dispose);

    await supervisorInstance.ensureRunning('rqbit.exe');

    expect(args, isNot(contains('--ratelimit-download')));
    expect(args, isNot(contains('--ratelimit-upload')));
  });

  test('sin puerto libre el error lo dice', () async {
    var started = false;
    final supervisorInstance = supervisor(
      start: (exe, args) async {
        started = true;
        return _FakeProcess(9100);
      },
      port: () async => throw const SocketException('no ports'),
    );

    await expectLater(
      supervisorInstance.ensureRunning('rqbit.exe'),
      throwsA(isA<RqbitPortException>()),
    );
    expect(started, isFalse);
  });
}
