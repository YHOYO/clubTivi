import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../datasources/local/database.dart' as db;
// `Provider` here is the IPTV provider model; it clashes with Riverpod's.
import '../models/channel.dart' hide Provider;

/// Why a stream did — or did not — answer.
///
/// A playlist can list a thousand entries and half of them point at feeds that
/// are geo-blocked, dead or already gone: opening them one by one to find out
/// takes a click and twenty seconds of buffering each time. This is the cheap
/// verdict used to tell the two apart before (or while) playing.
enum ProbeStatus {
  /// Server answered and returned what looks like playable media.
  ok,

  /// No contestó mientras se le pedían varios canales a la vez, pero sí responde
  /// cuando se le pide solo uno con paciencia. No es un canal muerto: es un
  /// servidor que ahoga las peticiones en paralelo (o un flujo muy lento).
  slow,

  /// 401/403: blocked by country, by token, or by missing headers.
  forbidden,

  /// 404/410: the entry points at something that no longer exists.
  notFound,

  /// No answer inside the timeout.
  timeout,

  /// Reached, but with an unexpected HTTP status or an empty body.
  unreachable,

  /// Answered 200 with something that is not an HLS playlist — usually a
  /// login/error page served with the wrong status.
  notAPlaylist,

  /// El certificado del servidor no se puede verificar en este equipo: falla en
  /// milisegundos y no es un canal lento. Suele ser un filtro de red o un
  /// antivirus que intercepta HTTPS, o un reloj desajustado.
  tls,

  /// La red responde con una página de bloqueo (403 con HTML, «política de
  /// seguridad»): el dominio está filtrado por el proveedor de internet,
  /// el antivirus o el filtro DNS. Ni la app ni el canal tienen la culpa.
  blocked,

  /// Anything else (DNS, TLS, malformed URL…).
  error,
}

/// De quién es la culpa cuando un canal no se ve, a grandes rasgos.
///
/// La diferencia importa: un 502 o un 403 en ráfaga habla del servidor al que
/// le estamos pidiendo demasiado, y un 404 habla de la entrada de la lista.
enum ProbeVerdict {
  /// Sirve (rápido o sólo cuando se le pide solo).
  works,

  /// El servidor falla o rechaza: 5xx, 401/403. Suele ser suyo, no del canal.
  serverSide,

  /// La red (filtro DNS, antivirus, cortafuegos) impide llegar: certificado sin
  /// verificar o página de bloqueo. No es ni el servidor ni el canal.
  blocked,

  /// Ni contesta ni rechaza: no se puede atribuir a nadie con esta medición.
  noAnswer,

  /// Responde que ahí no hay nada: 404, una página web en vez de una lista…
  dead,
}

class ProbeResult {
  final ProbeStatus status;
  final int? httpStatus;
  final int latencyMs;
  final String? detail;

  const ProbeResult({
    required this.status,
    this.httpStatus,
    this.latencyMs = 0,
    this.detail,
  });

  bool get isOk => status == ProbeStatus.ok;

  /// Whether the channel can be watched: answers quickly or, at least, answers.
  bool get works => status == ProbeStatus.ok || status == ProbeStatus.slow;

  /// Attribution used by the per-provider summary.
  ProbeVerdict get verdict => switch (status) {
        ProbeStatus.ok => ProbeVerdict.works,
        ProbeStatus.slow => ProbeVerdict.works,
        ProbeStatus.forbidden => ProbeVerdict.serverSide,
        ProbeStatus.unreachable => (httpStatus ?? 0) >= 500
            ? ProbeVerdict.serverSide
            : ProbeVerdict.dead,
        ProbeStatus.timeout => ProbeVerdict.noAnswer,
        ProbeStatus.notFound => ProbeVerdict.dead,
        ProbeStatus.notAPlaylist => ProbeVerdict.dead,
        ProbeStatus.tls => ProbeVerdict.blocked,
        ProbeStatus.blocked => ProbeVerdict.blocked,
        // DNS roto, conexión rechazada: puede ser la URL o el servidor.
        ProbeStatus.error => ProbeVerdict.noAnswer,
      };

  /// Short label for lists and badges.
  String get label => switch (status) {
        ProbeStatus.ok => 'OK',
        ProbeStatus.slow => 'Slow (${latencyMs}ms alone)',
        ProbeStatus.tls => 'Certificate not verified',
        ProbeStatus.blocked => 'Blocked by the network',
        ProbeStatus.forbidden => 'Blocked (${httpStatus ?? 403})',
        ProbeStatus.notFound => 'Gone (${httpStatus ?? 404})',
        ProbeStatus.timeout => 'No answer',
        ProbeStatus.unreachable => 'Unreachable',
        ProbeStatus.notAPlaylist => 'Not a playlist',
        ProbeStatus.error => 'Error',
      };

  /// One line explaining what to do about it.
  String get advice => switch (status) {
        ProbeStatus.ok => 'The server answers.',
        ProbeStatus.tls =>
          'The certificate of this server cannot be verified on this machine '
              '(an antivirus or proxy that inspects HTTPS, a wrong system clock '
              'or a missing root certificate). It is not a slow channel: it '
              'fails instantly.',
        ProbeStatus.blocked =>
          'Your network answered with a blocking page instead of the channel: '
              'the domain is filtered by the internet provider, the antivirus '
              'or a DNS filter. Nothing here is the app\'s or the channel\'s '
              'fault.',
        ProbeStatus.slow =>
          'It answers only when it is the only request in flight: the server '
              'throttles parallel connections, so several at once may fail. '
              'Give it time when opening it.',
        ProbeStatus.forbidden =>
          'The server refuses the connection: geo-blocked, token expired, or '
              'the playlist needs headers (referrer/user-agent).',
        ProbeStatus.notFound =>
          'The channel is no longer published at this address.',
        ProbeStatus.timeout => 'The server did not answer in time.',
        ProbeStatus.unreachable =>
          'It answered HTTP $httpStatus instead of a stream.',
        ProbeStatus.notAPlaylist =>
          'It answered with a web page instead of an .m3u8 playlist.',
        ProbeStatus.error => detail ?? 'Connection failed.',
      };

  Map<String, dynamic> toJson() => {
        's': status.name,
        'c': httpStatus,
        'l': latencyMs,
        if (detail != null) 'd': detail,
      };

  factory ProbeResult.fromJson(Map<String, dynamic> json) => ProbeResult(
        status: ProbeStatus.values.firstWhere(
          (s) => s.name == json['s'],
          orElse: () => ProbeStatus.error,
        ),
        httpStatus: json['c'] as int?,
        latencyMs: (json['l'] as int?) ?? 0,
        detail: json['d'] as String?,
      );
}

/// Contacts a stream URL the way a player would, but stops as soon as it knows
/// whether the server is willing to serve it.
/// Decide cuántas peticiones mantener en vuelo mientras se escanea.
///
/// Un 502/503/504 o un 403 en ráfaga no dice nada del canal: dice que el
/// servidor no aguanta lo que le estamos pidiendo. Bajar el ritmo no arregla un
/// canal muerto, pero recupera los que fallaban por atasco (y en la lista real
/// había doce 502 seguidos con seis peticiones en vuelo).
class AdaptiveConcurrency {
  final int maxLimit;
  final int minLimit;

  /// Resultados que se miran de golpe para decidir.
  final int window;

  /// Fallos del servidor dentro de la ventana que obligan a bajar el ritmo.
  final int failuresToBackOff;

  /// Resultados seguidos sin fallos del servidor antes de volver a subir.
  final int resultsToSpeedUp;

  final List<ProbeVerdict> _recent = [];
  int _limit;
  int _sinceChange = 0;
  int _downgrades = 0;

  AdaptiveConcurrency({
    required this.maxLimit,
    this.minLimit = 1,
    int? startLimit,
    this.window = 6,
    this.failuresToBackOff = 3,
    this.resultsToSpeedUp = 12,
  }) : _limit = (startLimit ?? maxLimit).clamp(minLimit, maxLimit);

  int get limit => _limit;
  bool get isThrottled => _limit < maxLimit;

  /// Cuántas veces hubo que bajar el ritmo.
  int get downgrades => _downgrades;

  /// Registra un resultado; devuelve el límite nuevo si cambió, o null.
  int? record(ProbeVerdict verdict) {
    _recent.add(verdict);
    if (_recent.length > window) _recent.removeAt(0);
    _sinceChange++;

    final serverFailures =
        _recent.where((v) => v == ProbeVerdict.serverSide).length;

    if (serverFailures >= failuresToBackOff && _limit > minLimit) {
      _limit = (_limit ~/ 2).clamp(minLimit, maxLimit);
      _downgrades++;
      _recent.clear();
      _sinceChange = 0;
      return _limit;
    }

    if (_sinceChange >= resultsToSpeedUp &&
        _limit < maxLimit &&
        serverFailures == 0) {
      _limit = (_limit + 1).clamp(minLimit, maxLimit);
      _recent.clear();
      _sinceChange = 0;
      return _limit;
    }

    return null;
  }
}

/// Semáforo con límite variable: deja pasar peticiones hasta [limit] y suelta
/// un hueco en cuanto una termina. Bajar el límite no cancela lo que ya está en
/// vuelo, sólo deja de admitir más.
class _ProbeGate {
  _ProbeGate(this._limit);

  int _limit;
  int _active = 0;
  final List<Completer<void>> _waiting = [];

  int get limit => _limit;

  Future<void> acquire() async {
    if (_active < _limit) {
      _active++;
      return;
    }
    final completer = Completer<void>();
    _waiting.add(completer);
    await completer.future;
  }

  void release() {
    if (_waiting.isNotEmpty) {
      // El hueco pasa al siguiente sin cambiar el número de activos.
      _waiting.removeAt(0).complete();
      return;
    }
    if (_active > 0) _active--;
  }

  void setLimit(int value) {
    _limit = value;
    while (_active < _limit && _waiting.isNotEmpty) {
      _active++;
      _waiting.removeAt(0).complete();
    }
  }
}

class ChannelProbeService {
  final Dio _dio;

  /// Segunda pasada máxima por defecto: en una lista de miles de canales, meter
  /// cada fallo en la pasada lenta convertiría el escaneo en un trabajo de horas.
  static const int defaultMaxRetries = 150;

  /// Veredictos que pueden ser un atasco pasajero (rate limit, servidor
  /// sobrecargado) y por eso merecen una segunda pasada. Un 404 o una respuesta
  /// que no es lista son respuestas definitivas: reintentarlas no aporta nada.
  static bool isWorthRetrying(ProbeStatus status) =>
      status == ProbeStatus.timeout ||
      status == ProbeStatus.unreachable ||
      status == ProbeStatus.forbidden;

  /// A ranged request is enough for both HLS playlists and raw TS/MP4: we only
  /// need the status code and a few kilobytes.
  static const int _probeBytes = 65536;

  ChannelProbeService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              validateStatus: (_) => true,
              followRedirects: true,
              maxRedirects: 5,
            ));

  /// Probes a channel, honouring the headers its playlist demanded.
  Future<ProbeResult> probeChannel(
    db.Channel channel, {
    Duration timeout = const Duration(seconds: 8),
  }) =>
      probeUrl(
        channel.streamUrl,
        headers: Channel.decodeHttpHeaders(channel.httpHeaders),
        timeout: timeout,
      );

  /// [detectBlockPage] separa una página de bloqueo del proveedor de red de un
  /// rechazo del propio servidor. En VOD conviene desactivarlo: un CDN que
  /// exige `Referer` contesta 403 con HTML y no es el ISP.
  Future<ProbeResult> probeUrl(
    String url, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 8),
    bool detectBlockPage = true,
  }) async {
    final isHls = url.toLowerCase().contains('.m3u8') ||
        url.toLowerCase().contains('.m3u?');
    final stopwatch = Stopwatch()..start();

    try {
      final response = await _dio.get<dynamic>(
        url,
        options: Options(
          responseType: isHls ? ResponseType.plain : ResponseType.bytes,
          receiveTimeout: timeout,
          sendTimeout: timeout,
          headers: {
            ...headers,
            'Range': 'bytes=0-${_probeBytes - 1}',
            if (!headers.keys.any((k) => k.toLowerCase() == 'user-agent'))
              'User-Agent': 'clubTivi/1.0',
          },
        ),
      );
      stopwatch.stop();
      return _classify(
        response,
        isHls,
        stopwatch.elapsedMilliseconds,
        detectBlockPage: detectBlockPage,
      );
    } on DioException catch (e) {
      stopwatch.stop();
      return classifyError(e, latencyMs: stopwatch.elapsedMilliseconds);
    } catch (e) {
      stopwatch.stop();
      return ProbeResult(
        status: ProbeStatus.error,
        latencyMs: stopwatch.elapsedMilliseconds,
        detail: e.toString(),
      );
    }
  }

  /// Traduce un fallo de la petición a un veredicto con motivo.
  ///
  /// Separar el certificado del resto importa: un fallo de TLS ocurre en
  /// milisegundos y no dice nada del canal, y sin esta distinción acababa
  /// mostrándose como «Error» con un «unknown» que no explicaba nada.
  @visibleForTesting
  static ProbeResult classifyError(DioException e, {required int latencyMs}) {
    final status = e.response?.statusCode;
    if (_looksLikeCertificateFailure(e)) {
      return ProbeResult(
        status: ProbeStatus.tls,
        latencyMs: latencyMs,
        detail: _errorDetail(e),
      );
    }
    if (status == 451) {
      return ProbeResult(
          status: ProbeStatus.blocked, httpStatus: status, latencyMs: latencyMs);
    }
    if (status == 401 || status == 403) {
      return ProbeResult(
          status: ProbeStatus.forbidden, httpStatus: status, latencyMs: latencyMs);
    }
    if (status == 404 || status == 410) {
      return ProbeResult(
          status: ProbeStatus.notFound, httpStatus: status, latencyMs: latencyMs);
    }
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout) {
      return ProbeResult(
        status: ProbeStatus.timeout,
        latencyMs: latencyMs,
        detail: 'No answer in time',
      );
    }
    return ProbeResult(
      status: ProbeStatus.error,
      latencyMs: latencyMs,
      detail: _errorDetail(e),
    );
  }

  static bool _looksLikeCertificateFailure(DioException e) {
    if (e.type == DioExceptionType.badCertificate) return true;
    final text = '${e.error} ${e.message}'.toLowerCase();
    return text.contains('certificate') ||
        text.contains('handshake') ||
        text.contains('tls') ||
        text.contains('untrusted') ||
        text.contains('self signed') ||
        text.contains('self-signed');
  }

  /// Motivo legible: el mensaje de Dio sólo suele decir «unknown», y el error de
  /// debajo (handshake, DNS, conexión rechazada) es el que explica el fallo.
  static String _errorDetail(DioException e) {
    final parts = <String>[
      e.type.name,
      if (e.message != null && e.message!.isNotEmpty && e.message != 'unknown')
        e.message!,
      if (e.error != null) e.error.toString(),
    ];
    return parts.join(': ');
  }

  static bool _bodyLooksLikeWebPage(dynamic data) {
    if (data == null) return false;
    final bytes = data is List<int> ? data : utf8.encode(data.toString());
    if (bytes.isEmpty) return false;
    final head = bytes.length > 2048
        ? bytes.sublist(0, 2048)
        : bytes;
    final text = utf8.decode(head, allowMalformed: true).toLowerCase();
    return text.contains('<html') ||
        text.contains('<!doctype html') ||
        text.contains('politica de seguridad') ||
        text.contains('security policy');
  }

  ProbeResult _classify(
    Response<dynamic> response,
    bool isHls,
    int latencyMs, {
    required bool detectBlockPage,
  }) {
    final code = response.statusCode ?? 0;
    if (code == 401 || code == 403 || code == 451) {
      // Un 403 con HTML no es «el canal te rechaza»: es una página de bloqueo
      // de la red (filtro del proveedor de internet, antivirus, DNS).
      if (detectBlockPage && _bodyLooksLikeWebPage(response.data)) {
        return ProbeResult(
            status: ProbeStatus.blocked, httpStatus: code, latencyMs: latencyMs);
      }
      return ProbeResult(
          status: ProbeStatus.forbidden, httpStatus: code, latencyMs: latencyMs);
    }
    if (code == 404 || code == 410) {
      return ProbeResult(
          status: ProbeStatus.notFound, httpStatus: code, latencyMs: latencyMs);
    }
    if (code < 200 || code >= 400) {
      return ProbeResult(
          status: ProbeStatus.unreachable, httpStatus: code, latencyMs: latencyMs);
    }

    final data = response.data;
    final bytes = data is List<int>
        ? data
        : data == null
            ? const <int>[]
            : utf8.encode(data.toString());
    if (bytes.isEmpty) {
      return ProbeResult(
        status: ProbeStatus.unreachable,
        httpStatus: code,
        latencyMs: latencyMs,
        detail: 'Empty response',
      );
    }
    if (isHls) {
      // 200 with HTML is the classic "expired token" page and mpv only finds
      // out after buffering for twenty seconds.
      final text = utf8.decode(bytes, allowMalformed: true);
      if (!text.contains('#EXTM3U')) {
        return ProbeResult(
          status: ProbeStatus.notAPlaylist,
          httpStatus: code,
          latencyMs: latencyMs,
        );
      }
    }
    return ProbeResult(
        status: ProbeStatus.ok, httpStatus: code, latencyMs: latencyMs);
  }

  /// Probes [channels] with a small worker pool, reporting each verdict as it
  /// arrives so the UI can fill in live.
  ///
  /// Los que no contestan vuelven a intentarse **de uno en uno y con más
  /// paciencia** ([retryTimeout]): así se distingue el canal muerto del servidor
  /// que se ahoga cuando le pedimos seis cosas a la vez. Los que sólo responden
  /// en esa segunda pasada quedan como [ProbeStatus.slow].
  ///
  /// [onResult] vuelve a avisar de esos canales con el veredicto final, así que
  /// quien sólo escuche ahí ya recibe la verdad de cada canal; [onRetryStart] y
  /// [onRetryResult] son para pintar la segunda pasada mientras ocurre.
  Future<void> scan(
    List<db.Channel> channels, {
    int concurrency = 6,
    Duration timeout = const Duration(seconds: 8),
    bool retryTimeouts = true,
    Duration retryTimeout = const Duration(seconds: 15),
    int maxRetries = defaultMaxRetries,
    bool adaptConcurrency = true,
    required void Function(db.Channel channel, ProbeResult result, int done, int total)
        onResult,
    void Function(int pending)? onRetryStart,
    void Function(db.Channel channel, ProbeResult result, int done, int total)?
        onRetryResult,
    void Function(int limit, int maxLimit)? onConcurrencyChanged,
    bool Function()? isCancelled,
  }) async {
    bool cancelled() => isCancelled?.call() ?? false;
    final queue = List.of(channels);
    final total = channels.length;
    final unanswered = <db.Channel>[];
    var done = 0;

    final startLimit = concurrency.clamp(1, 24);
    final adaptive = adaptConcurrency
        ? AdaptiveConcurrency(maxLimit: startLimit, startLimit: startLimit)
        : null;
    final gate = _ProbeGate(adaptive?.limit ?? startLimit);

    Future<void> worker() async {
      while (true) {
        if (cancelled() || queue.isEmpty) return;
        await gate.acquire();
        if (cancelled() || queue.isEmpty) {
          gate.release();
          return;
        }
        final channel = queue.removeAt(0);
        final result = await probeChannel(channel, timeout: timeout);
        gate.release();
        if (cancelled()) return;

        done++;
        if (isWorthRetrying(result.status)) unanswered.add(channel);
        onResult(channel, result, done, total);

        if (adaptive != null) {
          final changed = adaptive.record(result.verdict);
          if (changed != null) {
            gate.setLimit(adaptive.limit);
            onConcurrencyChanged?.call(adaptive.limit, adaptive.maxLimit);
          }
        }
      }
    }

    // Se lanzan todos los trabajadores y es el semáforo quien marca el ritmo:
    // así bajarlo a mitad de escaneo tiene efecto inmediato.
    await Future.wait(List.generate(startLimit, (_) => worker()));

    if (!retryTimeouts || unanswered.isEmpty || cancelled()) return;

    final retries = unanswered.take(maxRetries.clamp(1, 5000)).toList();
    onRetryStart?.call(retries.length);
    var retried = 0;
    for (final channel in retries) {
      if (cancelled()) return;
      final result = await probeChannel(channel, timeout: retryTimeout);
      if (cancelled()) return;
      retried++;
      // Un servidor que sólo aguanta una petición a la vez no está muerto; el
      // canal tampoco está "bien", y la lista debe poder distinguirlo.
      final verdict = result.isOk
          ? ProbeResult(
              status: ProbeStatus.slow,
              httpStatus: result.httpStatus,
              latencyMs: result.latencyMs,
              detail: 'Answered with a single request in flight',
            )
          : result;
      onRetryResult?.call(channel, verdict, retried, retries.length);
      onResult(channel, verdict, done, total);
    }
  }
}

/// Remembers the last verdict per stream URL so a scan survives a restart and
/// channel rows can show a dot without re-probing.
class ChannelHealthStore {
  static const _prefsKey = 'channel_health_v1';
  static const _maxEntries = 3000;

  final Map<String, ProbeResult> _byUrl = {};
  bool _loaded = false;
  bool _saveScheduled = false;

  final Map<String, int> _checkedAt = {};

  bool get isLoaded => _loaded;

  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null) {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        for (final entry in map.entries) {
          final value = entry.value;
          if (value is Map<String, dynamic>) {
            _byUrl[entry.key] = ProbeResult.fromJson(value);
            _checkedAt[entry.key] = (value['t'] as int?) ?? 0;
          }
        }
      }
    } catch (e) {
      debugPrint('[Health] Could not read saved results: $e');
    }
    _loaded = true;
  }

  ProbeResult? resultForUrl(String url) => _byUrl[_urlKey(url)];

  ProbeResult? resultFor(db.Channel channel) => resultForUrl(channel.streamUrl);

  DateTime? checkedAt(db.Channel channel) {
    final ms = _checkedAt[_urlKey(channel.streamUrl)];
    if (ms == null || ms == 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  void record(String url, ProbeResult result) {
    final key = _urlKey(url);
    _byUrl[key] = result;
    _checkedAt[key] = DateTime.now().millisecondsSinceEpoch;
    _scheduleSave();
  }

  void recordChannel(db.Channel channel, ProbeResult result) =>
      record(channel.streamUrl, result);

  void clear() {
    _byUrl.clear();
    _checkedAt.clear();
    _scheduleSave();
  }

  String _urlKey(String url) => url.hashCode.toRadixString(36);

  void _scheduleSave() {
    if (_saveScheduled) return;
    _saveScheduled = true;
    Future.delayed(const Duration(seconds: 3), () {
      _saveScheduled = false;
      unawaited(save());
    });
  }

  Future<void> save() async {
    try {
      if (_byUrl.length > _maxEntries) {
        final keys = _checkedAt.entries.toList()
          ..sort((a, b) => a.value.compareTo(b.value));
        for (final entry in keys.take(_byUrl.length - _maxEntries)) {
          _byUrl.remove(entry.key);
          _checkedAt.remove(entry.key);
        }
      }
      final payload = <String, dynamic>{};
      for (final entry in _byUrl.entries) {
        payload[entry.key] = {
          ...entry.value.toJson(),
          't': _checkedAt[entry.key] ?? 0,
        };
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(payload));
    } catch (e) {
      debugPrint('[Health] Could not save results: $e');
    }
  }
}

final channelProbeProvider = Provider<ChannelProbeService>((ref) {
  final service = ChannelProbeService();
  return service;
});

final channelHealthStoreProvider = Provider<ChannelHealthStore>((ref) {
  final store = ChannelHealthStore();
  unawaited(store.load());
  return store;
});
