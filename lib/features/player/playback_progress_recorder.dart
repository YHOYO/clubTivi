import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleState;

import '../../data/datasources/local/playback_dao.dart';
import '../../data/models/playback_request.dart';
import 'resume_point.dart';

/// Escribe por dónde va lo que se está reproduciendo.
///
/// Es el único dueño de *cuándo* se escribe: como mucho una vez cada
/// [interval] y, además, siempre en los momentos en que el tiempo se perdería:
/// al pausar, al salir de la pantalla y cuando la app pasa a segundo plano (un
/// TV box que se apaga por el mando nunca llega a `dispose`).
///
/// No conoce el reproductor: recibe sus streams y el DAO, así que se puede
/// probar sin motor ni pantalla. Sin [PlaybackRequest] no existe grabador: un
/// canal en vivo no tiene progreso.
class PlaybackProgressRecorder {
  PlaybackProgressRecorder({
    required PlaybackDao dao,
    required PlaybackRequest request,
    required Stream<Duration> positions,
    required Stream<Duration> durations,
    required Stream<bool> playing,
    String? mediaTitle,
    String? mediaPoster,
    this.interval = const Duration(seconds: 10),
    DateTime Function()? now,
  })  : _dao = dao,
        _request = request,
        _positions = positions,
        _durations = durations,
        _playing = playing,
        _mediaTitle = mediaTitle,
        _mediaPoster = mediaPoster,
        _now = now ?? DateTime.now;

  final PlaybackDao _dao;
  final PlaybackRequest _request;
  final Stream<Duration> _positions;
  final Stream<Duration> _durations;
  final Stream<bool> _playing;
  final String? _mediaTitle;
  final String? _mediaPoster;
  final DateTime Function() _now;

  /// Cadencia máxima de escritura.
  final Duration interval;

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<bool>? _playingSub;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  DateTime? _lastWriteAt;
  bool _hasPlayed = false;
  bool _started = false;
  bool _disposed = false;

  /// Última posición conocida, para quien quiera comprobarla.
  Duration get position => _position;

  void start() {
    if (_started || _disposed) return;
    _started = true;
    // La primera escritura espera al intervalo: guardar 0:00 al abrir no
    // aporta nada y ensuciaría el «continuar viendo».
    _lastWriteAt = _now();
    _positionSub = _positions.listen((value) {
      _position = value;
      unawaited(_writeIfDue());
    });
    _durationSub = _durations.listen((value) {
      // Un cero al arrancar no borra la duración buena que ya se conoce.
      if (value > Duration.zero) _duration = value;
    });
    _playingSub = _playing.listen((isPlaying) {
      if (isPlaying) {
        _hasPlayed = true;
        return;
      }
      // La pausa es el momento con más probabilidad de que el usuario cierre:
      // se escribe ya, sin esperar al intervalo.
      if (_hasPlayed) unawaited(flush());
    });
  }

  /// Escribe ya con lo último conocido (pausa, salida, segundo plano).
  Future<void> flush() => _write();

  /// La app deja de estar en primer plano.
  Future<void> handleLifecycle(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      return flush();
    }
    return Future<void>.value();
  }

  Future<void> _writeIfDue() async {
    final last = _lastWriteAt;
    if (last != null && _now().difference(last) < interval) return;
    await _write();
  }

  Future<void> _write() async {
    if (_disposed) return;
    // Sin duración no hay porcentaje ni umbral de completado: se espera a que
    // el motor la publique.
    if (_position <= Duration.zero || _duration <= Duration.zero) return;
    _lastWriteAt = _now();
    final completed = resumePoint(_position, _duration).completed;
    await _dao.saveProgress(
      _request,
      position: _position,
      duration: _duration,
      completed: completed,
      mediaTitle: _mediaTitle,
      mediaPoster: _mediaPoster,
      at: _now(),
    );
  }

  /// Escribe lo último y suelta los streams.
  Future<void> dispose() async {
    if (_disposed) return;
    await _write();
    _disposed = true;
    await _positionSub?.cancel();
    await _durationSub?.cancel();
    await _playingSub?.cancel();
    _positionSub = null;
    _durationSub = null;
    _playingSub = null;
  }
}
