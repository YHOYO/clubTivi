import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'adaptive_buffer.dart';
import 'buffer_progress.dart';
import 'stream_proxy.dart';
import '../../data/services/channel_history_service.dart';
import '../../data/services/stream_alternatives_service.dart';
import '../../data/services/stream_health_tracker.dart';

/// Manages video playback with stream failover support.
class PlayerService {
  Player? _player;
  VideoController? _videoController;
  final AdaptiveBufferManager _bufferManager = AdaptiveBufferManager();
  bool _isBuffering = false;
  DateTime? _bufferStartTime;
  /// Vigila que el flujo acabe teniendo audio real. Vive en un temporizador
  /// porque un VOD remoto grande tarda varios segundos en exponer sus pistas.
  Timer? _audioCheckTimer;

  /// Cuánto se espera antes de dar por hecho que el flujo no tiene audio. Con
  /// 3 s bastaba para cortar reproducciones que iban bien (un MKV de 4 GB en
  /// debrid tarda ~7 s en abrir el contenedor).
  static const audioProbeWindow = Duration(seconds: 12);

  /// Progreso de carga del canal actual. Se apoya en mpv para el búfer y en
  /// el estado de la app para saber si se está reconvirtiendo por ffmpeg.
  late final BufferProgressProbe _bufferProgress =
      BufferProgressProbe(readProperty: getMpvProperty);

  // Buffer health tracking (persists across info dialog opens)
  final List<bool> bufferHistory = List.filled(60, false, growable: true);
  int bufferEventCount = 0;
  int bufferingSeconds = 0;
  bool _trackingBuffering = false;
  Timer? _bufferTrackTimer;
  StreamSubscription<bool>? _bufferTrackSub;

  /// Buffer stall threshold before triggering failover.
  static const bufferStallThreshold = Duration(seconds: 3);

  // Auto-failover state
  String? _currentUrl;
  String? _currentChannelId;
  String? _currentEpgChannelId;
  String? _currentTvgId;
  String? _currentChannelName;
  String? _currentVanityName;
  String? _currentOriginalName;

  /// Extra HTTP headers the current stream needs (playlist `#EXTVLCOPT`).
  /// They follow the stream across proxy retries and failover switches.
  Map<String, String> _httpHeaders = const {};
  StreamAlternativesService? _alternatives;
  StreamHealthTracker? _healthTracker;
  Timer? _failoverCheckTimer;
  int _consecutiveLowBuffer = 0;

  /// Último `time-pos` visto y nº de muestras seguidas sin avanzar.
  /// Sirven para detectar streams colgados cuando mpv no expone la caché del
  /// demuxer (habitual en MPEG-TS/HLS en vivo: `demuxer-cache-duration` llega
  /// vacío y el monitor se quedaba sin ninguna señal).
  double? _lastTimePos;
  int _stagnantTicks = 0;
  final StreamProxy _streamProxy = StreamProxy();
  bool _proxyActive = false;

  /// Último volumen pedido por la UI. `player.state.volume` llega por el
  /// stream de mpv y puede ir un paso por detrás; una recarga necesita el
  /// valor intencional para no devolver el sonido a 100.
  double _volume = 100.0;

  /// Whether the ffmpeg fallback has already been tried for the current stream.
  bool _formatRetryDone = false;

  /// El proxy se abrió pero no entregó datos y ya se volvió a la URL original.
  /// Evita un bucle proxy → directo → proxy.
  bool _proxyFallbackReverted = false;

  // ── Warm failover: background pre-buffer player ──
  Player? _warmPlayer;
  String? _warmUrl;
  bool _warmReady = false;
  StreamSubscription<bool>? _warmBufferSub;
  Timer? _warmTimeoutTimer;

  /// Broadcast current stream URL changes (for UI like failover dialog).
  final _currentUrlController = StreamController<String?>.broadcast();
  Stream<String?> get currentUrlStream => _currentUrlController.stream;
  String? get currentUrl => _currentUrl;
  String? get currentChannelId => _currentChannelId;

  /// Callback invoked when auto-failover switches streams.
  /// Provides the provider name or URL fragment for UI toast.
  void Function(String message)? onFailover;

  /// Aviso de cada canal que el usuario abre, para el historial de visitados.
  ///
  /// Se avisa aquí y no en cada pantalla porque hay muchos caminos hasta el
  /// reproductor (lista, guía, siguiente/anterior, multi-view, mando web) y
  /// todos acaban en `play()` con el id del canal.
  void Function(String channelId)? onChannelVisited;

  /// Errores de reproducción ya traducidos a algo legible (403, DNS,
  /// geo-bloqueo…). Sin esto, un canal que no arranca se queda en «Buffering»
  /// para siempre y el usuario no sabe si es su red, el canal o la app.
  final _errorController = StreamController<String>.broadcast();
  Stream<String> get errors => _errorController.stream;

  /// Último error notificado, para la UI que se conecte tarde.
  String? lastError;
  StreamSubscription<String>? _errorSub;
  DateTime? _lastErrorAt;

  /// Cuándo se abrió el stream actual; sirve para detectar que nunca arranca.
  DateTime? _playStartedAt;

  /// Margen antes de declarar que un stream no va a arrancar.
  static const noStartupTimeout = Duration(seconds: 20);

  /// The channel ID that failover most recently switched to, if available.
  String? lastFailoverChannelId;

  bool _playerReady = false;
  final _playerReadyCompleter = Completer<void>();

  /// Cada apertura lleva un turno. `stop()` lo incrementa para que una
  /// apertura que aún estaba esperando no vuelva a arrancar el motor después
  /// de haberlo parado (el audio fantasma al salir mientras carga).
  int _generation = 0;

  /// ¿Otra apertura tomó el turno mientras ésta esperaba? Si además nadie
  /// reclamó el motor (fue un `stop()`), lo apaga para no dejar audio detrás.
  Future<bool> _isSuperseded(int generation) async {
    if (generation == _generation) return false;
    if (_currentUrl == null) await _player?.stop();
    return true;
  }

  Player get player {
    if (_player == null) {
      _player = Player(
        configuration: const PlayerConfiguration(
          logLevel: MPVLogLevel.warn,
        ),
      );
      _initPlayer(_player!);
    }
    return _player!;
  }

  Future<void> _initPlayer(Player p) async {
    final np = p.platform;
    if (np is NativePlayer) {
      // Downmix surround to stereo for output compatibility
      await np.setProperty('audio-channels', 'stereo');
      // Normalize volume when downmixing surround to stereo
      await np.setProperty('audio-normalize-downmix', 'yes');
      // EBU R128 loudness normalization — keeps volume consistent across streams
      await np.setProperty('af', 'loudnorm=I=-14:TP=-1:LRA=13');
      // Disable SPDIF passthrough which can cause silent output
      await np.setProperty('audio-spdif', '');
      // Volume
      await np.setProperty('volume', '100');
      await np.setProperty('mute', 'no');
      // Android TV: enable hardware decoding and optimize buffering
      if (Platform.isAndroid) {
        await np.setProperty('hwdec', 'mediacodec-copy');
        await np.setProperty('vo', 'gpu');
        await np.setProperty('framedrop', 'vo');
      }
    }
    await p.setVolume(100);
    _playerReady = true;
    _playerReadyCompleter.complete();
  }

  /// Wait for player properties to be applied before playback.
  Future<void> _ensureReady() async {
    if (!_playerReady) {
      // Access player to trigger creation if needed
      player; // ignore: unnecessary_statements
      await _playerReadyCompleter.future;
    }
  }

  VideoController get videoController {
    _videoController ??= VideoController(player);
    return _videoController!;
  }

  /// Inject services for auto-failover (call once at startup).
  ///
  /// Passing `null` disables auto-failover entirely — useful for tests that
  /// drive a single stream without wanting the monitor to switch away.
  void configureFailover(StreamAlternativesService? alternatives, StreamHealthTracker? health) {
    _alternatives = alternatives;
    _healthTracker = health;
    _failoverResolved = true;
  }

  /// Deja la conexión de failover para el primer `play()`.
  ///
  /// Construir el servicio (por ejemplo, para pararlo desde otra pantalla) no
  /// debe abrir la base de datos ni los servicios de salud de streams.
  void configureFailoverLazily(void Function() resolve) {
    _resolveFailover = resolve;
  }

  bool _failoverResolved = false;
  void Function()? _resolveFailover;

  void _ensureFailover() {
    if (_failoverResolved) return;
    _failoverResolved = true;
    try {
      _resolveFailover?.call();
    } catch (_) {
      // Sin failover se puede reproducir igual.
    }
  }

  // Failover group override: manual alternatives from user-created groups
  List<String>? _failoverGroupUrls;

  /// Start playing a stream URL with optional channel metadata for failover.
  Future<void> play(String url, {
    String? channelId,
    String? epgChannelId,
    String? tvgId,
    String? channelName,
    String? vanityName,
    String? originalName,
    List<String>? failoverGroupUrls,
    Map<String, String>? httpHeaders,
  }) async {
    final generation = ++_generation;
    _ensureFailover();
    _httpHeaders = httpHeaders ?? const {};
    _isBuffering = false;
    _bufferStartTime = null;
    _consecutiveLowBuffer = 0;
    _lastTimePos = null;
    _stagnantTicks = 0;
    _currentUrl = url;
    _currentChannelId = channelId;
    if (channelId != null && channelId.isNotEmpty) {
      onChannelVisited?.call(channelId);
    }
    _currentEpgChannelId = epgChannelId;
    _currentTvgId = tvgId;
    _currentChannelName = channelName;
    _currentVanityName = vanityName;
    _currentOriginalName = originalName;
    _failoverGroupUrls = failoverGroupUrls;
    _audioCheckTimer?.cancel();
    _failoverCheckTimer?.cancel();
    _disposeWarmPlayer();
    _proxyActive = false;
    _proxyFallbackReverted = false;
    _playStartedAt = DateTime.now();
    lastError = null;
    _lastErrorAt = null;
    _errorSub?.cancel();
    _errorSub = player.stream.error.listen(_onPlayerError);
    _formatRetryDone = false;
    _bufferProgress.begin();
    await _streamProxy.stop();
    if (generation != _generation) return;
    await _ensureReady();
    await _applyHttpHeaders();
    if (generation != _generation) return;
    await player.open(Media(url));
    // Otra pantalla pudo tomar el mando mientras se abría.
    if (await _isSuperseded(generation)) return;
    await _bufferManager.applyForStream(url, this);
    _volume = 100.0;
    await player.setVolume(100.0);

    // Check for missing audio after a brief delay and retry through
    // ffmpeg proxy if needed (fixes EAC-3 with non-standard codec tags)
    _scheduleAudioCheck(url);

    // Reset and start buffer tracking for the new stream
    bufferHistory.fillRange(0, 60, false);
    bufferEventCount = 0;
    bufferingSeconds = 0;
    startBufferTracking();
    _startFailoverMonitor();
  }

  /// Antes de dar un canal por roto, un reintento por ffmpeg.
  ///
  /// El «Failed to recognize file format» de mpv aparece con manifiestos que sí
  /// son válidos (variantes HLS raras, MPEG-TS servido como lista, protocolos
  /// que mpv no reconoce por la extensión). ffmpeg entra con `-c copy`, así que
  /// si él entiende el flujo, el canal se ve en vez de quedarse en el error.
  void _onPlayerError(String raw) {
    final lower = raw.toLowerCase();
    final unrecognised = lower.contains('recognize file format') ||
        lower.contains('unrecognized file format') ||
        lower.contains('cannot open') ||
        lower.contains('unknown protocol') ||
        lower.contains('no demuxer');

    // El proxy puede no llegar a entregar datos (VOD remoto grande): volver a
    // la URL original deja el flujo como estaba en vez de darlo por muerto.
    if (_proxyActive &&
        !_proxyFallbackReverted &&
        _currentUrl != null &&
        (lower.contains('failed to open') ||
            lower.contains('cannot open'))) {
      _proxyFallbackReverted = true;
      unawaited(_reopenDirect(_currentUrl!));
      return;
    }

    if (unrecognised &&
        !_formatRetryDone &&
        !_proxyActive &&
        _currentUrl != null) {
      _formatRetryDone = true;
      debugPrint('[Player] Format not recognised, retrying via ffmpeg: '
          '$_currentUrl');
      _retryWithProxy(_currentUrl!).then((_) {
        if (_proxyActive) {
          _reportPlaybackError(
              'Este canal envía un formato que el reproductor no reconocía; se '
              'está reintentando con ffmpeg.');
        }
      });
      return;
    }

    _reportPlaybackError(_explainPlaybackError(raw));
  }

  /// Publica un error de reproducción legible, evitando repetir el mismo
  /// mensaje en ráfaga (mpv emite varios logs por el mismo fallo).
  void _reportPlaybackError(String? message) {
    if (message == null || message.isEmpty) return;
    final now = DateTime.now();
    if (lastError == message &&
        _lastErrorAt != null &&
        now.difference(_lastErrorAt!) < const Duration(seconds: 10)) {
      return;
    }
    lastError = message;
    _lastErrorAt = now;
    debugPrint('[Player] error: $message');
    if (!_errorController.isClosed) _errorController.add(message);
  }

  /// Traduce el log de mpv/ffmpeg a algo que el usuario pueda interpretar.
  /// Devuelve null para el ruido que no explica nada.
  static String? _explainPlaybackError(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final lower = text.toLowerCase();
    if (lower.contains('403') || lower.contains('forbidden')) {
      return 'El canal rechazó la conexión (403 Forbidden). Suele estar '
          'bloqueado por país o exigir cabeceras del proveedor.';
    }
    if (lower.contains('404') || lower.contains('not found')) {
      return 'El canal ya no existe en el proveedor (404).';
    }
    if (lower.contains('timeout') || lower.contains('timed out')) {
      return 'El servidor del canal no responde (timeout).';
    }
    if (lower.contains('connection refused') ||
        lower.contains('could not connect') ||
        lower.contains('failed to connect') ||
        lower.contains('no route to host') ||
        lower.contains('could not resolve')) {
      return 'No se pudo conectar con el servidor del canal.';
    }
    if (lower.contains('recognize file format') ||
        lower.contains('unrecognized file format')) {
      return 'El canal no envía ningún flujo que el reproductor reconozca '
          '(manifiesto caducado, página de error o formato no soportado).';
    }
    if (lower.contains('failed to open') || lower.contains('cannot open')) {
      return 'No se pudo abrir el stream: $text';
    }
    return null;
  }

  /// Push [_httpHeaders] into mpv before opening a stream.
  ///
  /// mpv takes the fields as a comma-separated list. Clearing the option when
  /// the channel has none matters: without it, headers set for a previous
  /// referrer-locked channel would leak into the next one.
  Future<void> _applyHttpHeaders() async {
    final np = player.platform;
    if (np is! NativePlayer) return;
    final fields = _httpHeaders.entries
        .map((e) => '${e.key}: ${e.value}')
        .join(',');
    try {
      await np.setProperty('http-header-fields', fields);
    } catch (e) {
      debugPrint('[Player] Could not set http-header-fields: $e');
    }
  }

  /// Comprueba que el flujo tiene audio real, pero sin adelantarse.
  ///
  /// mpv sólo expone `auto`/`no` hasta que el demuxer abre el contenedor, y un
  /// VOD grande servido por debrid tarda varios segundos en hacerlo. Antes se
  /// miraba una sola vez a los 3 s y se cambiaba a ffmpeg: en un MKV de 4 GB
  /// eso mataba una reproducción que sólo necesitaba esperar.
  void _scheduleAudioCheck(String originalUrl) {
    _audioCheckTimer?.cancel();
    final started = Stopwatch()..start();
    _audioCheckTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_proxyActive || _currentUrl != originalUrl) {
        timer.cancel();
        return;
      }

      final state = player.state;
      final realAudio = state.tracks.audio
          .where((a) => a.id != 'auto' && a.id != 'no')
          .length;
      // Con pistas reales, o con imagen ya avanzando, no hay nada que arreglar.
      if (realAudio > 0 || state.position > Duration.zero) {
        timer.cancel();
        debugPrint('[Player] Audio OK: $realAudio tracks detected');
        return;
      }
      if (started.elapsed < audioProbeWindow) return;

      timer.cancel();
      debugPrint(
        '[Player] No audio tracks after ${audioProbeWindow.inSeconds}s, '
        'trying ffmpeg proxy for $originalUrl',
      );
      _retryWithProxy(originalUrl);
    });
  }

  /// Vuelve a la URL directa cuando el proxy no consiguió abrir el flujo.
  Future<void> _reopenDirect(String originalUrl) async {
    debugPrint('[Player] El proxy no abrió el flujo; vuelvo a la URL directa');
    _proxyActive = false;
    _formatRetryDone = true;
    await _streamProxy.stop();
    if (_currentUrl != originalUrl) return;
    await player.open(Media(originalUrl));
    await player.setVolume(_volume);
  }

  /// Re-open the stream through the local ffmpeg proxy.
  Future<void> _retryWithProxy(String originalUrl) async {
    if (_proxyActive) return; // Avoid recursive retry
    // El reintento tarda (arrancar ffmpeg) y puede quedar obsoleto mientras
    // espera: si otra apertura tomó el turno, no debe reabrir el flujo.
    final generation = _generation;
    final proxyUrl =
        await _streamProxy.start(originalUrl, headers: _httpHeaders);
    if (proxyUrl == null) {
      debugPrint('[Player] ffmpeg proxy unavailable, keeping direct playback');
      return;
    }
    if (generation != _generation || _currentUrl != originalUrl) {
      await _streamProxy.stop();
      return;
    }
    _proxyActive = true;
    // La espera cambia de motivo: ahora es ffmpeg quien prepara el flujo, y
    // el indicador lo dice en vez de quedarse en «Conectando».
    _bufferProgress.markConverting();
    debugPrint('[Player] Switching to proxied stream: $proxyUrl');
    await player.open(Media(proxyUrl));
    if (await _isSuperseded(generation)) return;
    await _bufferManager.applyForStream(originalUrl, this);
    await player.setVolume(100.0);
  }

  /// Whether audio tracks are available on the current stream.
  Stream<bool> get hasAudioStream =>
      player.stream.tracks.map((t) => t.audio.length > 1);

  /// Number of audio tracks.
  Stream<int> get audioTrackCountStream =>
      player.stream.tracks.map((t) => t.audio.length);

  /// Reabre el flujo actual sin salir del reproductor: señal perdida, imagen
  /// congelada o audio parado.
  ///
  /// Conserva canal, cabeceras, grupo de failover y volumen; `play()` vuelve a
  /// montar el resto (búfer, proxy, errores) como si se hubiera elegido el
  /// canal otra vez.
  Future<void> reload() async {
    final url = _currentUrl;
    if (url == null || url.isEmpty) return;
    final volume = _volume;
    final generation = _generation;
    await play(
      url,
      channelId: _currentChannelId,
      epgChannelId: _currentEpgChannelId,
      tvgId: _currentTvgId,
      channelName: _currentChannelName,
      vanityName: _currentVanityName,
      originalName: _currentOriginalName,
      failoverGroupUrls: _failoverGroupUrls,
      httpHeaders: _httpHeaders,
    );
    // `play()` deja el volumen a 100; recargar no debe subirlo de golpe.
    if (_generation == generation + 1) {
      _volume = volume;
      await _player?.setVolume(volume);
    }
  }

  /// Detiene la reproducción y suelta el canal: no queda ningún motor sonando
  /// ni metadatos de un canal que ya no se está viendo.
  ///
  /// Es el punto que usan las demás pantallas antes de abrir otro vídeo, para
  /// que el canal en vivo no siga detrás del tráiler o de una serie.
  Future<void> stop() async {
    final generation = ++_generation;
    _failoverCheckTimer?.cancel();
    _failoverCheckTimer = null;
    _disposeWarmPlayer();
    _bufferManager.stop();
    _bufferProgress.stop();
    _audioCheckTimer?.cancel();
    _errorSub?.cancel();
    // Sin reiniciar la bandera, el siguiente `play()` no volvería a enganchar
    // el tracking de búfer (startBufferTracking sale antes si ya está activo).
    _bufferTrackSub?.cancel();
    _bufferTrackSub = null;
    _bufferTrackTimer?.cancel();
    _bufferTrackTimer = null;
    _trackingBuffering = false;
    _isBuffering = false;
    _bufferStartTime = null;
    _playStartedAt = null;
    _consecutiveLowBuffer = 0;
    _lastTimePos = null;
    _stagnantTicks = 0;
    _failoverGroupUrls = null;
    _proxyActive = false;
    _currentUrl = null;
    _currentChannelId = null;
    _currentEpgChannelId = null;
    _currentTvgId = null;
    _currentChannelName = null;
    _currentVanityName = null;
    _currentOriginalName = null;
    _currentUrlController.add(null);
    await _streamProxy.stop();
    // Otra reproducción pudo empezar mientras ffmpeg se apagaba: su motor
    // manda y no se toca.
    if (generation != _generation) return;
    // `player` se crea bajo demanda: no se instancia un motor sólo para pararlo.
    await _player?.stop();
  }

  /// Pause playback.
  Future<void> pause() async {
    await player.pause();
  }

  /// Resume playback.
  Future<void> resume() async {
    await player.play();
  }

  /// Set volume (0.0 - 100.0).
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 100.0);
    await player.setVolume(_volume);
  }

  /// Stream of buffering state changes.
  Stream<bool> get bufferingStream => player.stream.buffering;

  /// Progreso de carga con datos reales de mpv (búfer, velocidad) y la fase
  /// en la que está la app. Ver [BufferProgress].
  Stream<BufferProgress> get bufferProgressStream => _bufferProgress.stream;

  /// Último progreso conocido, para quien se conecte tarde.
  BufferProgress? get bufferProgress => _bufferProgress.latest;

  /// Stream of playback position.
  Stream<Duration> get positionStream => player.stream.position;

  /// Stream of duration.
  Stream<Duration> get durationStream => player.stream.duration;

  /// Stream of whether playback is playing.
  Stream<bool> get playingStream => player.stream.playing;

  /// Check if buffer stall exceeds threshold (for failover trigger).
  bool get shouldFailover {
    if (!_isBuffering || _bufferStartTime == null) return false;
    return DateTime.now().difference(_bufferStartTime!) > bufferStallThreshold;
  }

  /// Called when buffering state changes — used by failover engine.
  void onBufferingChanged(bool buffering) {
    _bufferProgress.setBuffering(buffering);
    if (buffering && !_isBuffering) {
      _isBuffering = true;
      _bufferStartTime = DateTime.now();
    } else if (!buffering) {
      _isBuffering = false;
      _bufferStartTime = null;
    }
  }

  /// Read an mpv property from the underlying native player.
  /// Returns null if unavailable (e.g. on web or before player init).
  Future<String?> getMpvProperty(String name) async {
    final np = player.platform;
    if (np is NativePlayer) {
      try {
        return await np.getProperty(name);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// Take a screenshot via mpv's screenshot-to-file command.
  Future<String?> takeScreenshot(String path) async {
    final np = player.platform;
    if (np is NativePlayer) {
      try {
        await np.setProperty('screenshot-format', 'png');
        await np.command(['screenshot-to-file', path, 'video']);
        return path;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// Current adaptive buffer manager for UI access.
  AdaptiveBufferManager get bufferManager => _bufferManager;

  /// Start tracking buffer events and accumulating buffering time.
  void startBufferTracking() {
    if (_trackingBuffering) return;
    _trackingBuffering = true;

    _bufferTrackSub?.cancel();
    _bufferTrackSub = player.stream.buffering.listen((isBuffering) {
      bufferHistory.removeAt(0);
      bufferHistory.add(isBuffering);
      if (isBuffering && !_isBuffering) bufferEventCount++;
    });

    _bufferTrackTimer?.cancel();
    _bufferTrackTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (player.state.buffering) bufferingSeconds++;
    });
  }

  // ── Auto-failover monitor ──────────────────────────────────────────────

  void _startFailoverMonitor() {
    _failoverCheckTimer?.cancel();
    _failoverCheckTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_currentUrl == null) return;
      if (_alternatives == null && (_failoverGroupUrls == null || _failoverGroupUrls!.isEmpty)) return;

      final raw = await getMpvProperty('demuxer-cache-duration');
      final cacheSecs = double.tryParse(raw ?? '');
      final timePos = double.tryParse(await getMpvProperty('time-pos') ?? '');
      final paused = await getMpvProperty('pause') == 'yes';
      final idleActive = await getMpvProperty('idle-active') == 'yes';

      // Señal 3: el stream nunca llegó a arrancar. Con las otras dos no basta,
      // porque sin `time-pos` no hay estancamiento que detectar y la UI se
      // queda en «Buffering» indefinidamente sin explicar el motivo.
      if (_playStartedAt != null) {
        if (timePos != null && timePos > 0.5) {
          _playStartedAt = null;
        } else if (DateTime.now().difference(_playStartedAt!) >
            noStartupTimeout) {
          _playStartedAt = null;
          _reportPlaybackError('El canal no responde (ni vídeo ni audio en '
              '${noStartupTimeout.inSeconds} s). Comprueba que el stream '
              'funcione fuera de la app.');
        }
      }

      // Señal 1: la caché del demuxer se queda sin datos.
      final bufferStalled = cacheSecs != null && cacheSecs < 1.0;

      // Señal 2: el tiempo de reproducción no avanza. Es la única señal
      // disponible cuando mpv no publica `demuxer-cache-duration` (TS/HLS en
      // vivo), y sin ella el monitor no detectaba nada y nunca saltaba.
      final stalled = timePos != null &&
          _lastTimePos != null &&
          (timePos - _lastTimePos!).abs() < 0.05 &&
          !paused &&
          !idleActive;
      _lastTimePos = timePos;
      _stagnantTicks = stalled ? _stagnantTicks + 1 : 0;

      if (cacheSecs != null) {
        _healthTracker?.recordBufferSample(_currentUrl!, cacheSecs);
      }

      if (bufferStalled || _stagnantTicks >= 2) {
        _consecutiveLowBuffer++;
        if (_consecutiveLowBuffer >= 2 && !_warmReady && _warmPlayer == null) {
          // 4+ seconds of low buffer → start pre-buffering alternative (warm)
          _startWarmPreload();
        }
        if (_consecutiveLowBuffer >= 3) {
          // 6+ seconds of critically low buffer → failover
          _healthTracker?.recordStall(_currentUrl!);
          await _autoFailover();
        }
      } else {
        _consecutiveLowBuffer = 0;
        // Buffer recovered — dispose warm player if not yet used
        if (_warmPlayer != null && !_warmReady) {
          _disposeWarmPlayer();
        }
      }
    });
  }

  /// Get failover alternative URLs, preferring manual group URLs over auto-detected.
  List<String> _getFailoverAlternatives() {
    if (_currentUrl == null) return [];

    // Prefer manually-defined failover group URLs
    if (_failoverGroupUrls != null && _failoverGroupUrls!.isNotEmpty) {
      return _failoverGroupUrls!
          .where((u) => u != _currentUrl)
          .toList();
    }

    // Fall back to auto-detected alternatives
    if (_alternatives == null) return [];
    return _alternatives!.getAlternatives(
      channelId: _currentChannelId ?? '',
      epgChannelId: _currentEpgChannelId,
      tvgId: _currentTvgId,
      channelName: _currentChannelName,
      vanityName: _currentVanityName,
      originalName: _currentOriginalName,
      excludeUrl: _currentUrl!,
    );
  }

  /// Start pre-buffering the best alternative stream in a hidden player.
  void _startWarmPreload() {
    if (_currentUrl == null) return;

    final alts = _getFailoverAlternatives();
    if (alts.isEmpty) return;

    final warmUrl = alts.first;
    debugPrint('[Failover] Warm pre-buffering: $warmUrl');
    _warmUrl = warmUrl;
    _warmReady = false;

    _warmPlayer = Player(
      configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn),
    );

    // Configure warm player: muted, with loudnorm, no video output
    final np = _warmPlayer!.platform;
    if (np is NativePlayer) {
      np.setProperty('vid', 'no'); // disable video decoding
      np.setProperty('audio-channels', 'stereo');
      np.setProperty('audio-normalize-downmix', 'yes');
      np.setProperty('af', 'loudnorm=I=-14:TP=-1:LRA=13');
      np.setProperty('volume', '0'); // silent
      // The alternative belongs to the same channel, so it needs the same
      // headers; without them a referrer-locked stream would never buffer.
      if (_httpHeaders.isNotEmpty) {
        np.setProperty(
          'http-header-fields',
          _httpHeaders.entries
              .map((e) => '${e.key}: ${e.value}')
              .join(','),
        );
      }
    }

    // Listen for buffering state — when it stops buffering, stream is ready
    _warmBufferSub?.cancel();
    bool initialBuffering = true;
    _warmBufferSub = _warmPlayer!.stream.buffering.listen((buffering) {
      if (initialBuffering && buffering) return; // still loading
      if (initialBuffering && !buffering) {
        initialBuffering = false;
        _warmReady = true;
        _warmTimeoutTimer?.cancel();
        debugPrint('[Failover] Warm player ready: $_warmUrl');
      }
    });

    _warmPlayer!.open(Media(warmUrl));

    // Timeout: if warm player doesn't become ready in 10s, dispose it
    _warmTimeoutTimer?.cancel();
    _warmTimeoutTimer = Timer(const Duration(seconds: 10), () {
      if (!_warmReady) {
        debugPrint('[Failover] Warm pre-buffer timed out');
        _disposeWarmPlayer();
      }
    });
  }

  /// Dispose the warm pre-buffer player and clean up.
  void _disposeWarmPlayer() {
    _warmBufferSub?.cancel();
    _warmBufferSub = null;
    _warmTimeoutTimer?.cancel();
    _warmTimeoutTimer = null;
    _warmPlayer?.dispose();
    _warmPlayer = null;
    _warmUrl = null;
    _warmReady = false;
  }

  Future<void> _autoFailover() async {
    if (_currentUrl == null) return;
    final generation = _generation;
    if (_alternatives == null && (_failoverGroupUrls == null || _failoverGroupUrls!.isEmpty)) return;

    // If warm player is ready, do an instant switch
    if (_warmReady && _warmPlayer != null && _warmUrl != null) {
      debugPrint('[Failover] Instant switch to warm-buffered: $_warmUrl');
      final newUrl = _warmUrl!;
      _consecutiveLowBuffer = 0;
      _lastTimePos = null;
      _stagnantTicks = 0;
      _failoverCheckTimer?.cancel();

      // Dispose warm player (we'll re-open on main player)
      _disposeWarmPlayer();

      // Switch main player to the pre-buffered URL
      _currentUrl = newUrl;
      _proxyActive = false;
      await _streamProxy.stop();
      if (generation != _generation) return;
      await player.open(Media(newUrl));
      if (await _isSuperseded(generation)) return;
      await _bufferManager.applyForStream(newUrl, this);
      _startFailoverMonitor();

      _currentUrlController.add(newUrl);
      lastFailoverChannelId = _alternatives?.channelIdForUrl(newUrl);
      onFailover?.call('⚡ Switched stream (warm)');
      return;
    }

    // Cold failover: find best alternative and switch directly
    final alts = _getFailoverAlternatives();

    if (alts.isEmpty) return;

    final newUrl = alts.first;
    _consecutiveLowBuffer = 0;
    _lastTimePos = null;
    _stagnantTicks = 0;

    // Switch stream (keep channel metadata — it's the same content)
    _failoverCheckTimer?.cancel();
    _disposeWarmPlayer();
    _currentUrl = newUrl;
    _proxyActive = false;
    await _streamProxy.stop();
    if (generation != _generation) return;
    await player.open(Media(newUrl));
    if (await _isSuperseded(generation)) return;
    await _bufferManager.applyForStream(newUrl, this);
    _startFailoverMonitor();

    _currentUrlController.add(newUrl);
    lastFailoverChannelId = _alternatives?.channelIdForUrl(newUrl);
    onFailover?.call('⚡ Switched stream');
  }

  void dispose() {
    // Cualquier apertura en vuelo queda invalidada antes de soltar el motor.
    _generation++;
    _bufferManager.stop();
    _bufferProgress.dispose();
    _audioCheckTimer?.cancel();
    _errorSub?.cancel();
    _errorController.close();
    _bufferTrackSub?.cancel();
    _bufferTrackTimer?.cancel();
    _failoverCheckTimer?.cancel();
    _disposeWarmPlayer();
    _healthTracker?.save();
    _streamProxy.stop();
    _player?.dispose();
  }
}

/// Riverpod provider for the player service (singleton).
final playerServiceProvider = Provider<PlayerService>((ref) {
  final service = PlayerService();
  // Historial de canales: cualquier apertura deja la visita apuntada, y el
  // último visitado es el que la app vuelve a cargar al arrancar.
  service.onChannelVisited = (channelId) {
    try {
      unawaited(ref.read(channelHistoryProvider).record(channelId));
    } catch (_) {
      // El historial es un extra: que no tumbe la reproducción.
    }
  };
  // El failover se conecta en el primer `play()`, no al construir el
  // servicio: abrir la ficha o pararlo no debe tocar base de datos ni red.
  service.configureFailoverLazily(() {
    service.configureFailover(
      ref.read(streamAlternativesProvider),
      ref.read(streamHealthTrackerProvider),
    );
  });
  ref.onDispose(() => service.dispose());
  return service;
});
