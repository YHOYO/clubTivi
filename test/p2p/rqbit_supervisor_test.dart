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
  }) {
    return RqbitSupervisor(
      downloadDirectory: downloads,
      stateDirectory: state,
      startProcess: start,
      allocatePort: port ?? () async => 45678,
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

  test('stop es idempotente y deja de aceptar arranques', () async {
    final supervisorInstance = supervisor(
      start: (exe, args) async => _FakeProcess(9000),
    );

    await supervisorInstance.ensureRunning('rqbit.exe');
    await supervisorInstance.stop();
    await supervisorInstance.stop();

    expect(supervisorInstance.isRunning, isFalse);
    expect(
      () => supervisorInstance.ensureRunning('rqbit.exe'),
      throwsA(isA<RqbitStartException>()),
    );
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
