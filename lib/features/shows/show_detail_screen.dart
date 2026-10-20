import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../data/models/media_video.dart';
import '../../data/models/show.dart';
import '../../data/models/stream_search_result.dart';
import '../../data/models/stream_source.dart';
import '../../data/services/debrid_settings.dart';
import '../player/player_service.dart';
import 'await_provider.dart';
import 'shows_providers.dart';
import 'stream_picker.dart';
import 'trailer_player_screen.dart';

/// Detail screen for a show or movie — backdrop, info, seasons, episodes, play
class ShowDetailScreen extends ConsumerStatefulWidget {
  final int traktId;
  final Show? initialShow; // Passed via extra for instant display

  const ShowDetailScreen({super.key, required this.traktId, this.initialShow});

  @override
  ConsumerState<ShowDetailScreen> createState() => _ShowDetailScreenState();
}

class _ShowDetailScreenState extends ConsumerState<ShowDetailScreen> {
  int? _selectedSeason; // null until initialized
  bool _resolving = false;

  /// Episodio cuyo enlace se está buscando. Se marca la fila pulsada para que
  /// el clic tenga respuesta visible: antes solo cambiaba el botón Play de las
  /// películas y, en una serie, pulsar un episodio no mostraba nada.
  Episode? _pendingEpisode;
  int _lastSeasonCount = 0; // track when seasons change
  final _seasonScrollController = ScrollController();
  Color? _dominantColor; // extracted from backdrop image
  String? _lastBackdropUrl; // avoid re-extracting for the same URL

  static const _seasonPrefPrefix = 'show_last_season_';

  /// Initialize season: use persisted preference, or default to latest season
  void _initSeason(ShowDetail detail) {
    // Skip if no seasons yet, or re-init if season count changed
    if (detail.seasons.isEmpty) return;
    if (_selectedSeason != null && detail.seasons.length == _lastSeasonCount) {
      return;
    }
    _lastSeasonCount = detail.seasons.length;
    _loadLastSeason(detail);
  }

  Future<void> _loadLastSeason(ShowDetail detail) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt('$_seasonPrefPrefix${widget.traktId}');
    final latestSeason = detail.seasons.isNotEmpty
        ? detail.seasons.map((s) => s.number).reduce((a, b) => a > b ? a : b)
        : 1;
    setState(() {
      _selectedSeason = saved ?? latestSeason;
    });
    _scrollToSelectedSeason(detail);
  }

  void _scrollToSelectedSeason(ShowDetail detail) {
    if (_selectedSeason == null || detail.seasons.isEmpty) return;
    final index = detail.seasons.indexWhere((s) => s.number == _selectedSeason);
    if (index < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_seasonScrollController.hasClients) return;
      final maxScroll = _seasonScrollController.position.maxScrollExtent;
      final viewWidth = _seasonScrollController.position.viewportDimension;
      // Estimate chip position — center it in the viewport
      const chipWidth = 120.0;
      final chipCenter =
          index * chipWidth + chipWidth / 2 + 20; // +20 for padding
      final target = (chipCenter - viewWidth / 2).clamp(0.0, maxScroll);
      _seasonScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _selectSeason(int season) async {
    setState(() => _selectedSeason = season);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('$_seasonPrefPrefix${widget.traktId}', season);
  }

  /// Extract dominant color from backdrop for subtle page tint.
  void _extractDominantColor(String? url) {
    if (url == null || url.isEmpty || url == _lastBackdropUrl) return;
    _lastBackdropUrl = url;
    PaletteGenerator.fromImageProvider(
          CachedNetworkImageProvider(url),
          maximumColorCount: 8,
        )
        .then((palette) {
          if (!mounted) return;
          final color =
              palette.dominantColor?.color ??
              palette.mutedColor?.color ??
              palette.darkMutedColor?.color;
          if (color != null) {
            setState(() => _dominantColor = color);
          }
        })
        .catchError((_) {});
  }

  @override
  void dispose() {
    _seasonScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final type = widget.initialShow?.type ?? ShowType.show;
    final detailAsync = ref.watch(
      showDetailProvider(ShowDetailParams(widget.traktId, type: type)),
    );

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
          backgroundColor: _dominantColor != null
              ? Color.lerp(const Color(0xFF0A0A1A), _dominantColor!, 0.15)!
              : const Color(0xFF0A0A1A),
          body: detailAsync.when(
            loading: () => _buildWithShow(widget.initialShow, loading: true),
            error: (err, _) => _buildError(err),
            data: (detail) {
              if (detail == null) {
                // Fallback to initialShow if provider returned null
                if (widget.initialShow != null) {
                  return _buildDetail(ShowDetail(show: widget.initialShow!));
                }
                return _buildError('Show not found');
              }
              return _buildDetail(detail);
            },
          ),
        ),
      ),
    );
  }

  Widget _buildWithShow(Show? show, {bool loading = false}) {
    if (show == null) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF6C5CE7)),
      );
    }
    return _buildDetail(ShowDetail(show: show), loading: loading);
  }

  Widget _buildError(Object error) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
          const SizedBox(height: 12),
          Text('$error', style: const TextStyle(color: Colors.white60)),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () => context.go('/shows'),
            child: const Text('Go Back'),
          ),
        ],
      ),
    );
  }

  Widget _buildDetail(ShowDetail detail, {bool loading = false}) {
    // Initialize season selection (latest or last-viewed)
    _initSeason(detail);
    final effectiveSeason =
        _selectedSeason ??
        (detail.seasons.isNotEmpty
            ? detail.seasons
                  .map((s) => s.number)
                  .reduce((a, b) => a > b ? a : b)
            : 1);
    final show = detail.show;
    final videos = show.promotionalVideos;
    // Extract dominant color from backdrop for page tint
    _extractDominantColor(show.backdropUrl);
    final bgColor = _dominantColor != null
        ? Color.lerp(const Color(0xFF0A0A1A), _dominantColor!, 0.15)!
        : const Color(0xFF0A0A1A);
    return CustomScrollView(
      slivers: [
        // Backdrop + back button
        SliverAppBar(
          expandedHeight: 240,
          pinned: true,
          backgroundColor: bgColor,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => context.go('/shows'),
          ),
          flexibleSpace: FlexibleSpaceBar(
            background: Stack(
              fit: StackFit.expand,
              children: [
                if (show.backdropUrl != null && show.backdropUrl!.isNotEmpty)
                  CachedNetworkImage(
                    imageUrl: show.backdropUrl!,
                    fit: BoxFit.cover,
                    errorWidget: (_, _, _) =>
                        Container(color: const Color(0xFF1A1A2E)),
                  )
                else
                  Container(color: const Color(0xFF1A1A2E)),
                // Gradient overlay
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Color(0xDD0A0A1A)],
                      stops: [0.4, 1.0],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // Show info
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title + year
                Text(
                  show.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                // Meta row
                Wrap(
                  spacing: 12,
                  children: [
                    if (show.year != null) _chip('${show.year}'),
                    if (show.rating != null)
                      _chip('★ ${show.rating!.toStringAsFixed(1)}'),
                    if (show.runtime != null) _chip('${show.runtime} min'),
                    if (show.status != null) _chip(show.status!),
                    if (show.network != null) _chip(show.network!),
                  ],
                ),
                const SizedBox(height: 8),
                // Genres
                if (show.genres.isNotEmpty)
                  Wrap(
                    spacing: 8,
                    children: show.genres
                        .take(5)
                        .map(
                          (g) => Chip(
                            label: Text(
                              g,
                              style: const TextStyle(fontSize: 11),
                            ),
                            backgroundColor: const Color(0xFF1A1A2E),
                            labelStyle: const TextStyle(color: Colors.white60),
                            side: BorderSide.none,
                            padding: EdgeInsets.zero,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                        )
                        .toList(),
                  ),
                const SizedBox(height: 16),
                // Overview
                if (show.overview != null)
                  Text(
                    show.overview!,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 15,
                      height: 1.5,
                    ),
                  ),
                const SizedBox(height: 20),

                // Play button (for movies) and the videos the sources publish
                if (show.type == ShowType.movie) _buildPlayMovieButton(show),
                if (videos.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _buildVideosSection(show, videos),
                ],

                if (loading)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(
                      child: CircularProgressIndicator(
                        color: Color(0xFF6C5CE7),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),

        // Seasons tabs (for TV shows)
        if (show.type == ShowType.show && detail.seasons.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: SizedBox(
              height: 48,
              child: ListView.builder(
                controller: _seasonScrollController,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemCount: detail.seasons.length,
                itemBuilder: (context, index) {
                  final season = detail.seasons[index];
                  final selected = season.number == effectiveSeason;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: Text('Season ${season.number}'),
                      selected: selected,
                      selectedColor: const Color(0xFF6C5CE7),
                      backgroundColor: const Color(0xFF1A1A2E),
                      labelStyle: TextStyle(
                        color: selected ? Colors.white : Colors.white60,
                      ),
                      side: BorderSide.none,
                      onSelected: (_) => _selectSeason(season.number),
                    ),
                  );
                },
              ),
            ),
          ),
          // Episodes list
          _buildEpisodesList(show, effectiveSeason),
        ],
      ],
    );
  }

  /// Lista de vídeos del título: el botón principal abre el más relevante y
  /// debajo están todos, para elegir cualquiera. Todo se ve dentro de la app.
  Widget _buildVideosSection(Show show, List<MediaVideo> videos) {
    final first = videos.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => _openVideo(show, first, videos),
            icon: const Icon(Icons.play_circle_outline),
            label: Text(first.kindLabel),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Colors.white24),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          videos.length == 1 ? 'Vídeo' : 'Vídeos (${videos.length})',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        for (final video in videos)
          _VideoTile(
            video: video,
            onPlay: () => _openVideo(show, video, videos),
          ),
      ],
    );
  }

  /// Un vídeo de YouTube se ve en el reproductor de la app; cualquier otro
  /// (el tráiler que anota Trakt fuera de YouTube) se abre en el navegador.
  Future<void> _openVideo(
    Show show,
    MediaVideo video,
    List<MediaVideo> videos,
  ) async {
    if (!video.isPlayableInApp) {
      // El navegador reproduce fuera de la app: el canal tampoco debe seguir
      // sonando por detrás mientras se ve el vídeo.
      await ref.read(playerServiceProvider).stop();
      final opened = await openVideoExternally(video);
      if (!opened && mounted) {
        _showSnackbar('No se pudo abrir el vídeo en el navegador');
      }
      return;
    }
    if (!mounted) return;
    context.push(
      '/trailer',
      extra: TrailerRouteArgs(video: video, videos: videos, title: show.title),
    );
  }

  Widget _buildPlayMovieButton(Show show) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _resolving ? null : () => _playContent(show),
        icon: _resolving
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Icon(Icons.play_arrow),
        label: Text(_resolving ? 'Finding stream...' : 'Play'),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF6C5CE7),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 16),
          textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _buildEpisodesList(Show show, int seasonNumber) {
    final episodesAsync = ref.watch(
      episodesProvider(EpisodeParams(widget.traktId, seasonNumber)),
    );

    return episodesAsync.when(
      loading: () => const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Center(
            child: CircularProgressIndicator(color: Color(0xFF6C5CE7)),
          ),
        ),
      ),
      error: (err, _) => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Error: $err',
            style: const TextStyle(color: Colors.redAccent),
          ),
        ),
      ),
      data: (episodes) => SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => _EpisodeTile(
            episode: episodes[index],
            show: show,
            loading: _pendingEpisode == episodes[index],
            onPlay: _resolving
                ? null
                : () => _playEpisode(show, episodes[index]),
          ),
          childCount: episodes.length,
        ),
      ),
    );
  }

  Future<void> _playContent(Show show) async {
    if (show.imdbId == null) {
      _showSnackbar('No IMDB ID available for this title');
      return;
    }
    setState(() => _resolving = true);
    // La ficha y el canal en vivo comparten altavoz: pulsar Play suelta el
    // canal antes de resolver, no cuando el reproductor ya está encima.
    await ref.read(playerServiceProvider).stop();
    try {
      final result = await awaitProviderFuture(
        ref,
        resolveStreamProvider(StreamResolveParams(show.imdbId!)),
      );
      if (result.isEmpty) {
        _showSnackbar(_noStreamsMessage(result));
        return;
      }
      if (!mounted) return;
      _pickStream(result, show.title);
    } catch (e) {
      _showSnackbar('Stream error: $e');
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  Future<void> _playEpisode(Show show, Episode episode) async {
    if (show.imdbId == null) {
      _showSnackbar('No IMDB ID available');
      return;
    }
    if (_resolving) return;
    setState(() {
      _resolving = true;
      _pendingEpisode = episode;
    });
    // Igual que al reproducir la película: el canal deja de sonar al pedir el
    // episodio, aunque la fuente tarde en resolverse.
    await ref.read(playerServiceProvider).stop();
    try {
      final result = await awaitProviderFuture(
        ref,
        resolveStreamProvider(
          StreamResolveParams(
            show.imdbId!,
            season: episode.season,
            episode: episode.number,
          ),
        ),
      );
      if (result.isEmpty) {
        _showSnackbar(_noStreamsMessage(result, 'for ${episode.code}'));
        return;
      }
      if (!mounted) return;
      _pickStream(result, '${show.title} ${episode.code}');
    } catch (e) {
      _showSnackbar('Stream error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _resolving = false;
          _pendingEpisode = null;
        });
      }
    }
  }

  /// Sin fuentes, el aviso nombra al proveedor que falló en vez de culpar a
  /// Torrentio cuando el que no respondió fue un addon.
  String _noStreamsMessage(StreamSearchResult result, [String suffix = '']) {
    if (result.hasFailures) {
      final names = result.failures.map((f) => f.providerName).join(', ');
      return 'No streams found$suffix — $names no respondió';
    }
    return 'No streams found$suffix';
  }

  /// Mismo selector que la ficha de un catálogo: las fuentes, sus fallos y el
  /// motivo cuando una no se puede reproducir.
  void _pickStream(StreamSearchResult result, String title) {
    showStreamPicker(
      context,
      result: result,
      title: title,
      onPlay: (stream) => _resolveAndPlay(stream, title),
      onDownload: (stream) => _resolveAndDownload(stream, title),
    );
  }

  Future<void> _resolveAndPlay(StreamSource stream, String title) async {
    if (!stream.isDirect && !stream.isAvailable) {
      showUnavailableSourceDialog(context, stream);
      return;
    }
    _showSnackbar(
      stream.isDirect
          ? 'Opening stream…'
          : stream.isCached
          ? 'Preparing stream…'
          : 'Preparing stream — this may take a moment…',
    );
    setState(() => _resolving = true);
    try {
      final repo = await ref.read(showsRepositoryProvider.future);
      final url = await resolveSourceUrl(
        repo,
        stream,
        onProgress: (label, progress) {
          if (!mounted) return;
          _showSnackbar(
            progress > 0 ? '$label ($progress%)' : label,
            duration: const Duration(seconds: 30),
          );
        },
      );
      if (url == null || url.isEmpty) {
        _showSnackbar('Stream unavailable — try another source');
        return;
      }
      if (!mounted) return;
      // Un enlace resuelto por debrid ya no pertenece al CDN del addon, así que
      // sus cabeceras sólo viajan con la URL directa.
      _launchPlayer(
        url,
        title,
        headers: stream.isDirect ? stream.headers : const {},
      );
    } on SourceUnavailableException catch (e) {
      _showSnackbar(e.message);
    } on DebridUnavailableException catch (e) {
      _showSnackbar(e.message);
    } catch (e) {
      _showSnackbar('$e');
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  Future<void> _resolveAndDownload(StreamSource stream, String title) async {
    if (stream.isDirect) {
      await _openDownloadUrl(stream.url!);
      return;
    }
    if (!stream.isAvailable) {
      showUnavailableSourceDialog(context, stream);
      return;
    }
    _showSnackbar(
      stream.isCached
          ? 'Preparing download…'
          : 'Preparing download — this may take a moment…',
    );
    setState(() => _resolving = true);
    try {
      final repo = await ref.read(showsRepositoryProvider.future);
      final url = await resolveSourceUrl(
        repo,
        stream,
        onProgress: (label, progress) {
          if (!mounted) return;
          _showSnackbar(
            progress > 0 ? '$label ($progress%)' : label,
            duration: const Duration(seconds: 30),
          );
        },
      );
      if (url == null || url.isEmpty) {
        _showSnackbar('Download unavailable — try another source');
        return;
      }
      await _openDownloadUrl(url);
    } on SourceUnavailableException catch (e) {
      _showSnackbar(e.message);
    } on DebridUnavailableException catch (e) {
      _showSnackbar(e.message);
    } catch (e) {
      _showSnackbar('$e');
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  Future<void> _openDownloadUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (mounted) _showSnackbar('Download started in browser');
    } else {
      _showSnackbar('Could not open download URL');
    }
  }

  void _launchPlayer(
    String url,
    String title, {
    Map<String, String> headers = const {},
  }) {
    debugPrint('[Shows] Launching player: url=$url, title=$title');
    if (url.isEmpty) {
      _showSnackbar('Stream URL is empty — try another source');
      return;
    }
    // El aviso de progreso dura 30 s: no debe quedar flotando sobre el vídeo
    // cuando el enlace ya está resuelto.
    ScaffoldMessenger.of(context).clearSnackBars();
    context.push(
      '/player',
      extra: {
        'streamUrl': url,
        'channelName': title,
        'channelLogo': widget.initialShow?.posterUrl ?? '',
        if (headers.isNotEmpty) 'httpHeaders': headers,
      },
    );
  }

  /// El aviso nuevo sustituye siempre al anterior: el estado del debrid llega
  /// cada dos segundos (y se queda 30 s), así que encolar dejaría el mensaje
  /// final —el que explica por qué no hay reproducción— detrás del progreso.
  void _showSnackbar(
    String message, {
    Duration duration = const Duration(seconds: 4),
  }) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFF1A1A2E),
        duration: duration,
      ),
    );
  }

  Widget _chip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white60, fontSize: 13),
      ),
    );
  }
}

/// Una fila de la lista de vídeos: miniatura de YouTube, qué es y de qué
/// idioma, con el mismo aspecto que las filas de episodios.
class _VideoTile extends StatelessWidget {
  final MediaVideo video;
  final VoidCallback onPlay;

  const _VideoTile({required this.video, required this.onPlay});

  @override
  Widget build(BuildContext context) {
    final facts = [
      video.kindLabel,
      if (video.languageBadge != null) video.languageBadge!,
    ].join(' · ');

    return InkWell(
      onTap: onPlay,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 120,
                height: 68,
                child: video.thumbnailUrl.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: video.thumbnailUrl,
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) => _placeholder(),
                      )
                    : _placeholder(),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    video.displayName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    facts,
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ],
              ),
            ),
            Icon(
              video.isPlayableInApp
                  ? Icons.play_circle_outline
                  : Icons.open_in_new,
              color: const Color(0xFF6C5CE7),
              size: 32,
            ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder() {
    return Container(
      color: const Color(0xFF1A1A2E),
      child: const Center(
        child: Icon(Icons.movie_outlined, color: Colors.white24),
      ),
    );
  }
}

class _EpisodeTile extends StatelessWidget {
  final Episode episode;
  final Show show;
  final VoidCallback? onPlay;

  /// Mientras se buscan las fuentes de este episodio la fila lo dice con un
  /// spinner en lugar del icono de play.
  final bool loading;

  const _EpisodeTile({
    required this.episode,
    required this.show,
    required this.onPlay,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPlay,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        child: Row(
          children: [
            // Episode thumbnail
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 120,
                height: 68,
                child: episode.stillUrl != null && episode.stillUrl!.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: episode.stillUrl!,
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) => _placeholder(),
                      )
                    : _placeholder(),
              ),
            ),
            const SizedBox(width: 12),
            // Episode info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${episode.number}. ${episode.displayTitle}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  if (episode.overview != null)
                    Text(
                      episode.overview!,
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 12,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  if (episode.runtime != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '${episode.runtime} min',
                        style: const TextStyle(
                          color: Colors.white24,
                          fontSize: 11,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            // Play icon (spinner while the streams are being searched)
            if (loading)
              const SizedBox(
                width: 32,
                height: 32,
                child: Padding(
                  padding: EdgeInsets.all(6),
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFF6C5CE7),
                  ),
                ),
              )
            else
              const Icon(
                Icons.play_circle_outline,
                color: Color(0xFF6C5CE7),
                size: 32,
              ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder() {
    return Container(
      color: const Color(0xFF1A1A2E),
      child: const Center(child: Icon(Icons.play_arrow, color: Colors.white24)),
    );
  }
}
