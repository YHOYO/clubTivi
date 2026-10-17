import 'dart:async';

import 'package:flutter/foundation.dart';

/// En qué punto del arranque está el canal.
///
/// Existe porque un canal tarda en arrancar por motivos que la app conoce
/// (conectar, reintentar por ffmpeg) y decirlo es más útil que un porcentaje
/// inventado: mpv no publica ninguna métrica de caché hasta que empieza a
/// recibir datos, así que durante la espera lo único cierto es el tiempo
/// transcurrido y lo que la app está haciendo.
enum BufferPhase { connecting, converting, buffering }

/// Progreso de carga del canal, con datos reales de mpv cuando existen.
///
/// Nada aquí se estima: o viene del reproductor ([bufferedSeconds],
/// [speedBytesPerSecond]) o es tiempo medido por la app ([waited]).
@immutable
class BufferProgress {
  final BufferPhase phase;

  /// Tiempo esperando: desde que se pidió el canal, o desde que empezó el
  /// corte actual si ya había imagen.
  final Duration waited;

  /// Segundos de vídeo ya almacenados por delante de la posición actual
  /// (`demuxer-cache-duration`). Null mientras mpv no reciba datos.
  final double? bufferedSeconds;

  /// Velocidad de descarga en bytes por segundo (`cache-speed`).
  final double? speedBytesPerSecond;

  const BufferProgress({
    required this.phase,
    required this.waited,
    this.bufferedSeconds,
    this.speedBytesPerSecond,
  });

  /// Búfer objetivo de una emisión en directo, en segundos.
  ///
  /// No es una regla de mpv: es la referencia con la que se pinta la barra y
  /// con la que se decide si la barra está llena.
  static const targetBufferSeconds = 10.0;

  /// Ocupación del búfer respecto al objetivo, de 0 a 1. Null si aún no hay
  /// datos que lo midan.
  double? get fill {
    final buffered = bufferedSeconds;
    if (buffered == null) return null;
    return (buffered / targetBufferSeconds).clamp(0.0, 1.0);
  }

  /// Texto de estado para el usuario, siempre con lo que se sabe de verdad.
  String describe() {
    final seconds = (waited.inMilliseconds / 1000).toStringAsFixed(1);
    switch (phase) {
      case BufferPhase.connecting:
        return 'Conectando… ${seconds}s';
      case BufferPhase.converting:
        return 'Reconvirtiendo con ffmpeg… ${seconds}s';
      case BufferPhase.buffering:
        final parts = <String>[];
        final fillPercent = fill;
        if (fillPercent != null) {
          parts.add('${(fillPercent * 100).round()}%');
        }
        if (bufferedSeconds != null) {
          parts.add('${bufferedSeconds!.toStringAsFixed(1)}s en búfer');
        }
        final speed = speedBytesPerSecond;
        if (speed != null && speed > 0) {
          parts.add('${_speed(speed)}/s');
        }
        if (parts.isEmpty) return 'Cargando… ${seconds}s';
        return parts.join(' · ');
    }
  }

  static String _speed(double bytesPerSecond) {
    if (bytesPerSecond >= 1024 * 1024) {
      return '${(bytesPerSecond / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    if (bytesPerSecond >= 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(0)} KB';
    }
    return '${bytesPerSecond.toStringAsFixed(0)} B';
  }
}

/// Sondea el búfer de mpv y publica el progreso mientras un canal está en
/// marcha.
///
/// Se separa del reproductor porque así se puede probar sin libmpv: basta con
/// inyectar un [readProperty] falso.
class BufferProgressProbe {
  BufferProgressProbe({
    required this.readProperty,
    this.interval = const Duration(milliseconds: 500),
  });

  /// Lee una propiedad de mpv. Devuelve null si no está disponible.
  final Future<String?> Function(String name) readProperty;

  /// Cada cuánto se refresca el progreso.
  final Duration interval;

  final _controller = StreamController<BufferProgress>.broadcast();
  Timer? _timer;
  DateTime? _startedAt;
  bool _converting = false;
  bool _buffering = false;
  bool _disposed = false;

  /// Progreso más reciente, para quien se conecte tarde.
  BufferProgress? latest;

  Stream<BufferProgress> get stream => _controller.stream;

  bool get isRunning => _timer != null;

  /// Marca el comienzo de una espera nueva y arranca el sondeo.
  void begin({bool converting = false}) {
    if (_disposed) return;
    _startedAt = DateTime.now();
    _converting = converting;
    _buffering = true;
    _tick();
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  /// El reproductor cambió de vía (por ejemplo, pasó al proxy de ffmpeg).
  void markConverting() {
    _converting = true;
    _startedAt = DateTime.now();
  }

  /// El reproductor dejó de almacenar. Si vuelve, la espera empieza de nuevo.
  void setBuffering(bool buffering) {
    if (buffering && !_buffering) _startedAt = DateTime.now();
    _buffering = buffering;
    if (buffering) _converting = false;
  }

  /// Detiene el sondeo (al parar la reproducción).
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    if (_disposed) return;
    final buffered =
        double.tryParse(await readProperty('demuxer-cache-duration') ?? '');
    final speed = double.tryParse(await readProperty('cache-speed') ?? '');
    final position = double.tryParse(await readProperty('time-pos') ?? '');
    if (_disposed) return;

    // Con imagen ya en pantalla el aviso deja de ser «arrancando»: si el búfer
    // se queda corto más adelante, el texto vuelve solo a «Cargando».
    final started = position != null && position > 0.5;
    final converting = !started && _converting;

    final progress = BufferProgress(
      phase: converting
          ? BufferPhase.converting
          : started
              ? BufferPhase.buffering
              : BufferPhase.connecting,
      waited: _startedAt == null
          ? Duration.zero
          : DateTime.now().difference(_startedAt!),
      bufferedSeconds: buffered,
      speedBytesPerSecond: speed,
    );
    latest = progress;
    if (!_controller.isClosed) _controller.add(progress);
  }

  void dispose() {
    _disposed = true;
    stop();
    _controller.close();
  }
}
