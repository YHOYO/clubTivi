/// Supervisor del proceso `rqbit` que sirve el motor P2P en local.
///
/// Responsabilidades: encontrar un puerto libre, arrancar el binario con la API
/// HTTP ligada a loopback, esperar a que responda, reiniciarlo si muere y
/// cerrarlo sin dejar huérfanos. No sabe nada de torrents: eso es el motor.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'rqbit_client.dart';

/// Lo mínimo que el supervisor necesita de un proceso, para poder sustituirlo
/// en tests sin lanzar un binario real.
abstract class RqbitProcessHandle {
  int get pid;
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;
  Future<int> get exitCode;
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]);
}

class _DartProcessHandle implements RqbitProcessHandle {
  final Process _process;

  _DartProcessHandle(this._process);

  @override
  int get pid => _process.pid;

  @override
  Stream<List<int>> get stdout => _process.stdout;

  @override
  Stream<List<int>> get stderr => _process.stderr;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) =>
      _process.kill(signal);
}

/// Arranca el binario. Inyectable para probar el supervisor sin procesos reales.
typedef RqbitProcessStarter =
    Future<RqbitProcessHandle> Function(String executable, List<String> arguments);

/// Devuelve un puerto TCP libre en loopback.
typedef RqbitPortAllocator = Future<int> Function();

/// Comprueba si la API ya responde en [baseUri].
typedef RqbitReadinessProbe = Future<bool> Function(Uri baseUri);

/// Dueño del ciclo de vida de un único proceso rqbit.
class RqbitSupervisor {
  /// Carpeta donde rqbit escribe lo descargado. Es la carpeta que ve el usuario.
  final String downloadDirectory;

  /// Carpeta de sesión/persistencia de rqbit (JSON) y del fichero de PID.
  final String stateDirectory;

  final RqbitProcessStarter _startProcess;
  final RqbitPortAllocator _allocatePort;
  final RqbitReadinessProbe _probe;
  final Duration startTimeout;
  final Duration probeInterval;
  final Duration restartDelay;
  final int maxRestarts;
  final void Function(String message)? onLog;

  RqbitProcessHandle? _process;
  Uri? _baseUri;
  Future<Uri>? _starting;
  Timer? _restartTimer;
  bool _stopping = false;
  bool _sweptLeftovers = false;
  int _restartsLeft;
  String? _executable;
  final List<String> _logTail = [];

  RqbitSupervisor({
    required this.downloadDirectory,
    required this.stateDirectory,
    RqbitProcessStarter? startProcess,
    RqbitPortAllocator? allocatePort,
    RqbitReadinessProbe? probe,
    this.startTimeout = const Duration(seconds: 30),
    this.probeInterval = const Duration(milliseconds: 200),
    this.restartDelay = const Duration(seconds: 1),
    this.maxRestarts = 3,
    this.onLog,
  }) : _startProcess = startProcess ?? _defaultStarter,
       _allocatePort = allocatePort ?? _defaultPortAllocator,
       _probe = probe ?? _defaultProbe,
       _restartsLeft = maxRestarts;

  /// URL base de la API cuando el proceso está listo.
  Uri? get baseUri => _baseUri;

  bool get isRunning => _process != null && _baseUri != null;

  int? get processId => _process?.pid;

  File get _pidFile => File('$stateDirectory/rqbit-sidecar.json');

  /// Arranca el motor si hace falta y devuelve su URL base.
  ///
  /// Varias reproducciones simultáneas comparten el mismo arranque: la segunda
  /// espera el futuro de la primera en vez de lanzar otro proceso.
  Future<Uri> ensureRunning(String executable) {
    if (_stopping) {
      throw const RqbitStartException(
        'The P2P engine was already stopped for this session',
      );
    }
    _executable = executable;

    final current = _baseUri;
    if (current != null && _process != null) return Future.value(current);

    final pending = _starting;
    if (pending != null) return pending;

    _restartTimer?.cancel();
    _restartTimer = null;
    final future = _startWithRetries(executable);
    _starting = future;
    // Limpiar el futuro pendiente sin crear un error sin escuchar: quien llamó
    // a ensureRunning ya recibe el fallo original.
    future.then<void>(
      (_) {
        if (identical(_starting, future)) _starting = null;
      },
      onError: (Object _) {
        if (identical(_starting, future)) _starting = null;
      },
    );
    return future;
  }

  /// Mata el proceso y espera a que termine. Idempotente.
  Future<void> stop() async {
    _stopping = true;
    _restartTimer?.cancel();
    _restartTimer = null;

    final process = _process;
    _process = null;
    _baseUri = null;
    if (process != null) {
      process.kill();
      final exited = await process.exitCode.timeout(
        const Duration(seconds: 3),
        onTimeout: () => -1,
      );
      if (exited == -1) {
        await _killTree(process.pid);
      }
    }
    await _deletePidFile();
  }

  /// Limpia un rqbit que quedó vivo de una ejecución anterior (cierre forzado,
  /// apagón…). Solo mata el PID si sigue siendo rqbit: el PID puede haberse
  /// reciclado.
  Future<void> _sweepLeftovers() async {
    if (_sweptLeftovers) return;
    _sweptLeftovers = true;
    try {
      if (!await _pidFile.exists()) return;
      final json = jsonDecode(await _pidFile.readAsString());
      final pid = json is Map ? json['pid'] : null;
      if (pid is! int || pid == pidOfCurrentProcess) return;
      if (await _looksLikeRqbit(pid)) {
        onLog?.call('Killing leftover rqbit process $pid');
        await _killTree(pid);
      }
    } catch (error) {
      onLog?.call('Could not clean up a previous rqbit process: $error');
    } finally {
      await _deletePidFile();
    }
  }

  Future<Uri> _startWithRetries(String executable) async {
    await _sweepLeftovers();
    Object? lastError;
    for (var attempt = 0; attempt <= maxRestarts; attempt++) {
      if (_stopping) {
        throw const RqbitStartException('The P2P engine was stopped');
      }
      try {
        final uri = await _startOnce(executable);
        _restartsLeft = maxRestarts;
        return uri;
      } catch (error) {
        lastError = error;
        onLog?.call('rqbit start attempt ${attempt + 1} failed: $error');
        if (attempt < maxRestarts) {
          await Future<void>.delayed(restartDelay);
        }
      }
    }
    throw lastError is RqbitException
        ? lastError
        : RqbitStartException('$lastError');
  }

  Future<Uri> _startOnce(String executable) async {
    await Directory(downloadDirectory).create(recursive: true);
    await Directory(stateDirectory).create(recursive: true);

    final int port;
    try {
      port = await _allocatePort();
    } catch (error) {
      throw RqbitPortException('No free local port for the P2P engine: $error');
    }
    final uri = Uri.parse('http://127.0.0.1:$port');

    _logTail.clear();
    final process = await _startProcess(executable, [
      '--http-api-listen-addr',
      '127.0.0.1:$port',
      '--disable-upnp-port-forward',
      'server',
      'start',
      '--persistence-location',
      stateDirectory,
      downloadDirectory,
    ]);

    var exited = false;
    int? exitCode;
    process.exitCode.then((code) {
      exited = true;
      exitCode = code;
    });
    _drain(process.stdout, 'stdout');
    _drain(process.stderr, 'stderr');

    final deadline = DateTime.now().add(startTimeout);
    while (true) {
      if (exited) {
        await _killTree(process.pid);
        throw RqbitStartException(
          'rqbit exited before answering (code $exitCode)${_tailSuffix()}',
        );
      }
      if (await _probe(uri)) {
        // El sondeo puede ganar la carrera a un proceso que acaba de morir:
        // se comprueba otra vez antes de darlo por listo.
        if (exited) {
          await _killTree(process.pid);
          throw RqbitStartException(
            'rqbit exited before answering (code $exitCode)${_tailSuffix()}',
          );
        }
        break;
      }
      if (DateTime.now().isAfter(deadline)) {
        process.kill();
        await _killTree(process.pid);
        throw RqbitStartException(
          'The P2P engine did not answer within '
          '${_durationLabel(startTimeout)}${_tailSuffix()}',
        );
      }
      await Future<void>.delayed(probeInterval);
    }

    _process = process;
    _baseUri = uri;
    await _writePidFile(process.pid, port);
    process.exitCode.then((code) => _onExit(process, code));
    onLog?.call('rqbit ready at $uri (pid ${process.pid})');
    return uri;
  }

  void _onExit(RqbitProcessHandle process, int code) {
    if (!identical(_process, process)) return;
    _process = null;
    _baseUri = null;
    unawaited(_deletePidFile());
    if (_stopping) return;
    onLog?.call('rqbit exited unexpectedly (code $code)');
    if (_restartsLeft <= 0) {
      onLog?.call('rqbit restart budget exhausted');
      return;
    }
    _restartsLeft--;
    final executable = _executable;
    if (executable == null) return;
    _restartTimer?.cancel();
    _restartTimer = Timer(restartDelay, () async {
      try {
        await ensureRunning(executable);
        onLog?.call('rqbit restarted after an unexpected exit');
      } catch (error) {
        onLog?.call('rqbit could not be restarted: $error');
      }
    });
  }

  void _drain(Stream<List<int>> stream, String label) {
    stream.transform(utf8.decoder).transform(const LineSplitter()).listen((
      line,
    ) {
      if (line.trim().isEmpty) return;
      _logTail.add('$label: $line');
      if (_logTail.length > 8) _logTail.removeAt(0);
      onLog?.call(line);
    }, onError: (Object error) => onLog?.call('$label error: $error'));
  }

  String _durationLabel(Duration duration) {
    if (duration.inSeconds >= 1) return '${duration.inSeconds}s';
    return '${duration.inMilliseconds}ms';
  }

  String _tailSuffix() {
    if (_logTail.isEmpty) return '';
    return '\n${_logTail.join('\n')}';
  }

  Future<void> _writePidFile(int pid, int port) async {
    try {
      await _pidFile.writeAsString(
        jsonEncode({
          'pid': pid,
          'port': port,
          'startedAt': DateTime.now().toIso8601String(),
        }),
        flush: true,
      );
    } catch (error) {
      onLog?.call('Could not write the rqbit pid file: $error');
    }
  }

  Future<void> _deletePidFile() async {
    try {
      if (await _pidFile.exists()) await _pidFile.delete();
    } catch (_) {
      // Un fichero de PID que no se puede borrar no debe tumbar el cierre.
    }
  }

  Future<bool> _looksLikeRqbit(int pid) async {
    try {
      if (Platform.isWindows) {
        final result = await Process.run('tasklist', [
          '/FI',
          'PID eq $pid',
          '/NH',
          '/FO',
          'CSV',
        ]);
        return result.stdout.toString().toLowerCase().contains('rqbit');
      }
      final result = await Process.run('ps', ['-p', '$pid', '-o', 'comm=']);
      return result.stdout.toString().toLowerCase().contains('rqbit');
    } catch (_) {
      return false;
    }
  }

  Future<void> _killTree(int pid) async {
    if (pid <= 0) return;
    if (Platform.isWindows) {
      try {
        await Process.run('taskkill', ['/PID', '$pid', '/T', '/F']);
      } catch (_) {
        // Si ya no existe, no hay nada que hacer.
      }
      return;
    }
    try {
      Process.killPid(pid, ProcessSignal.sigkill);
    } catch (_) {
      // Proceso ya terminado.
    }
  }

  static Future<RqbitProcessHandle> _defaultStarter(
    String executable,
    List<String> arguments,
  ) async {
    final process = await Process.start(
      executable,
      arguments,
      runInShell: false,
    );
    return _DartProcessHandle(process);
  }

  static Future<int> _defaultPortAllocator() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  static Future<bool> _defaultProbe(Uri baseUri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    try {
      final request = await client
          .getUrl(baseUri.replace(path: '/'))
          .timeout(const Duration(seconds: 1));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(
        const Duration(seconds: 1),
      );
      await response.drain<void>();
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// En Windows `pid` es la identidad estable del proceso actual.
  static int get pidOfCurrentProcess => pid;
}

/// El motor no llegó a estar listo.
class RqbitStartException extends RqbitException {
  const RqbitStartException(super.message);
}

/// No hay puerto libre en loopback.
class RqbitPortException extends RqbitException {
  const RqbitPortException(super.message);
}
