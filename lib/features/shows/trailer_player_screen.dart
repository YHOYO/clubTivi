import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models/media_video.dart';
import '../../data/services/trailer_stream_resolver.dart';
import '../player/player_service.dart';

/// Abre el vídeo en YouTube. Es la salida cuando la app no puede reproducirlo
/// por dentro: mejor decirlo y llevar allí que dejar un botón que no responde.
Future<bool> openVideoExternally(MediaVideo video) async {
  final url = video.watchUrl;
  if (url.isEmpty) return false;
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// Datos con los que se abre el reproductor desde la ficha. Va como `extra`
/// del router: un objeto tipado en vez de un mapa con claves sueltas.
class TrailerRouteArgs {
  const TrailerRouteArgs({
    required this.video,
    this.videos = const [],
    this.title = '',
  });

  final MediaVideo video;
  final List<MediaVideo> videos;
  final String title;
}

/// Reproduce un vídeo promocional dentro de la app.
///
/// Se resuelve el flujo de YouTube y se abre con el mismo motor (mpv) que usa
/// el reproductor de canales, en un reproductor propio para no pisar el canal
/// que el usuario tuviera abierto. Si la resolución o el arranque fallan, la
/// pantalla lo explica y ofrece «Ver en YouTube» en vez de quedarse en negro.
class TrailerPlayerScreen extends ConsumerStatefulWidget {
  final MediaVideo video;

  /// Todos los vídeos del título, para poder cambiar sin volver a la ficha.
  final List<MediaVideo> videos;

  /// Título del título (película o serie), para la cabecera.
  final String title;

  const TrailerPlayerScreen({
    super.key,
    required this.video,
    this.videos = const [],
    this.title = '',
  });

  @override
  ConsumerState<TrailerPlayerScreen> createState() =>
      _TrailerPlayerScreenState();
}

enum _Stage { preparing, playing, degraded }

class _TrailerPlayerScreenState extends ConsumerState<TrailerPlayerScreen> {
  Player? _player;
  VideoController? _controller;
  StreamSubscription<String>? _errorSub;
  Timer? _watchdog;

  late MediaVideo _current = widget.video;
  _Stage _stage = _Stage.preparing;
  String? _problem;
  bool _sawPosition = false;

  /// Margen antes de dar por hecho que el vídeo no va a arrancar: sin esto un
  /// fallo silencioso deja la pantalla en negro para siempre.
  static const _startupTimeout = Duration(seconds: 20);

  List<MediaVideo> get _alternatives =>
      widget.videos.isEmpty ? [widget.video] : widget.videos;

  @override
  void initState() {
    super.initState();
    final player = Player();
    _player = player;
    _controller = VideoController(player);
    _errorSub = player.stream.error.listen(_onPlayerError);
    player.stream.position.listen((position) {
      if (position.inMilliseconds > 0) _sawPosition = true;
    });
    unawaited(_start(_current));
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    _errorSub?.cancel();
    _player?.dispose();
    super.dispose();
  }

  Future<void> _start(MediaVideo video) async {
    // Un solo motor a la vez: el canal en vivo que estuviera sonando se apaga
    // antes de abrir el tráiler (o de resolverlo).
    await ref.read(playerServiceProvider).stop();
    if (!mounted) return;

    if (!video.isPlayableInApp) {
      await _degrade(
        'Este vídeo no es de YouTube, así que no se puede ver dentro de la app.',
        openExternally: true,
      );
      return;
    }

    _watchdog?.cancel();
    setState(() {
      _stage = _Stage.preparing;
      _problem = null;
      _sawPosition = false;
    });

    final TrailerStream stream;
    try {
      stream = await ref.read(trailerStreamResolverProvider).resolve(video.key);
    } on TrailerUnavailable catch (e) {
      await _degrade(e.message, openExternally: false);
      return;
    } catch (e) {
      await _degrade('$e', openExternally: false);
      return;
    }
    if (!mounted || _current != video) return;

    try {
      await _player?.open(Media(stream.url));
      await _player?.play();
    } catch (e) {
      await _degrade('No se pudo abrir el vídeo: $e', openExternally: false);
      return;
    }
    if (!mounted || _current != video) return;

    setState(() => _stage = _Stage.playing);
    _watchdog?.cancel();
    _watchdog = Timer(_startupTimeout, () {
      if (!mounted || _sawPosition || _stage != _Stage.playing) return;
      unawaited(
        _degrade(
          'El vídeo no arrancó en ${_startupTimeout.inSeconds} segundos.',
          openExternally: false,
        ),
      );
    });
  }

  void _onPlayerError(String message) {
    if (!mounted || _sawPosition || _stage == _Stage.degraded) return;
    debugPrint('[Trailer] mpv error: $message');
    unawaited(
      _degrade(
        'El reproductor no pudo con el flujo de YouTube.',
        openExternally: false,
      ),
    );
  }

  /// Deja de intentar la reproducción interna y ofrece la salida al navegador.
  ///
  /// Sólo se abre el navegador solo cuando el vídeo no es de YouTube y no hay
  /// nada que intentar; si el fallo viene de la resolución o del reproductor,
  /// se explica y el botón queda a mano. Abrir una ventana sin que el usuario
  /// la pida es más molesto que un botón que funciona.
  Future<void> _degrade(String reason, {required bool openExternally}) async {
    if (!mounted) return;
    _watchdog?.cancel();
    setState(() {
      _stage = _Stage.degraded;
      _problem = reason;
    });
    if (openExternally) {
      final opened = await openVideoExternally(_current);
      if (!mounted) return;
      _snackbar(
        opened
            ? 'Se abrió en YouTube: $reason'
            : 'No se pudo abrir el navegador: $reason',
      );
    }
  }

  void _select(MediaVideo video) {
    if (video == _current) return;
    setState(() => _current = video);
    unawaited(_start(video));
  }

  void _snackbar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFF1A1A2E),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          Future.microtask(() {
            if (!context.mounted) return;
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/shows');
            }
          });
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: Text(
              widget.title.isEmpty
                  ? _current.displayName
                  : '${widget.title} · ${_current.displayName}',
              style: const TextStyle(fontSize: 16),
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              IconButton(
                tooltip: 'Ver en YouTube',
                icon: const Icon(Icons.open_in_new),
                onPressed: () async {
                  final opened = await openVideoExternally(_current);
                  if (!opened && mounted) {
                    _snackbar('No se pudo abrir el navegador.');
                  }
                },
              ),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: switch (_stage) {
                  _Stage.playing when _controller != null => Video(
                    controller: _controller!,
                  ),
                  _Stage.preparing => const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircularProgressIndicator(color: Color(0xFF6C5CE7)),
                        SizedBox(height: 16),
                        Text(
                          'Preparando el vídeo…',
                          style: TextStyle(color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                  _ => _buildDegraded(),
                },
              ),
              if (_alternatives.length > 1) _buildVideoSwitcher(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDegraded() {
    final video = _current;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.videocam_off_outlined,
              color: Colors.white38,
              size: 48,
            ),
            const SizedBox(height: 12),
            Text(
              _problem ?? 'No se pudo reproducir el vídeo.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () async {
                final opened = await openVideoExternally(video);
                if (!opened && mounted) {
                  _snackbar('No se pudo abrir el navegador.');
                }
              },
              icon: const Icon(Icons.open_in_new),
              label: const Text('Ver en YouTube'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF6C5CE7),
              ),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => unawaited(_start(video)),
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
              style: TextButton.styleFrom(foregroundColor: Colors.white60),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoSwitcher() {
    return SizedBox(
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: _alternatives.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final video = _alternatives[index];
          final selected = video == _current;
          return ChoiceChip(
            key: ValueKey('trailer-video-${video.key}-${video.name}'),
            avatar: Icon(
              selected ? Icons.play_circle : Icons.play_circle_outline,
              size: 18,
              color: selected ? Colors.white : Colors.white60,
            ),
            label: Text(
              video.displayName,
              style: TextStyle(
                color: selected ? Colors.white : Colors.white60,
                fontSize: 13,
              ),
            ),
            selected: selected,
            selectedColor: const Color(0xFF6C5CE7),
            backgroundColor: const Color(0xFF1A1A2E),
            side: BorderSide.none,
            onSelected: (_) => _select(video),
          );
        },
      ),
    );
  }
}
