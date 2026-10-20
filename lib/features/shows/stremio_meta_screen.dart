import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/datasources/local/playback_dao.dart';
import '../../data/models/playback_request.dart';
import '../../data/models/stremio_addon.dart';
import '../../data/models/stream_search_result.dart';
import '../../data/models/stream_source.dart';
import '../../data/services/debrid_settings.dart';
import '../../data/services/release_memory.dart';
import '../player/player_service.dart';
import '../providers/provider_manager.dart' show databaseProvider;
import 'await_provider.dart';
import 'shows_providers.dart';
import 'stream_picker.dart';

/// Ficha de un título que viene de un catálogo de addon.
///
/// Recibe lo que ya traía el catálogo (carátula, título, sinopsis) para pintar
/// algo al instante y pide `/meta` al addon para completar episodios. Si el
/// addon no publica ficha, se queda con los datos del catálogo.
class StremioMetaScreen extends ConsumerStatefulWidget {
  final StremioMeta initialMeta;
  final String addonUrl;

  const StremioMetaScreen({
    super.key,
    required this.initialMeta,
    required this.addonUrl,
  });

  @override
  ConsumerState<StremioMetaScreen> createState() => _StremioMetaScreenState();
}

class _StremioMetaScreenState extends ConsumerState<StremioMetaScreen> {
  int? _selectedSeason;
  bool _resolving = false;

  StremioMetaParams get _params => StremioMetaParams(
        addonUrl: widget.addonUrl,
        type: widget.initialMeta.type,
        id: widget.initialMeta.id,
      );

  @override
  Widget build(BuildContext context) {
    final detailAsync = ref.watch(stremioMetaProvider(_params));
    final meta = detailAsync.valueOrNull ?? widget.initialMeta;
    final seasons = meta.seasons;
    final season = _selectedSeason ??
        (seasons.isEmpty ? null : seasons.last);

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A1A),
      body: Stack(
        children: [
          CustomScrollView(
            slivers: [
              _buildHeader(meta),
              SliverToBoxAdapter(child: _buildInfo(meta, detailAsync)),
              if (seasons.isNotEmpty) ...[
                SliverToBoxAdapter(child: _buildSeasonTabs(seasons, season!)),
                _buildEpisodes(meta, season),
              ] else
                SliverToBoxAdapter(child: _buildPlayButton(meta)),
              const SliverToBoxAdapter(child: SizedBox(height: 32)),
            ],
          ),
          if (detailAsync.isLoading)
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(
                minHeight: 2,
                color: Color(0xFF6C5CE7),
                backgroundColor: Colors.transparent,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildHeader(StremioMeta meta) {
    final backdrop = meta.background ?? meta.poster;
    return SliverAppBar(
      expandedHeight: 240,
      pinned: true,
      backgroundColor: const Color(0xFF0A0A1A),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, color: Colors.white),
        onPressed: () {
          if (context.canPop()) {
            context.pop();
          } else {
            context.go('/shows');
          }
        },
      ),
      flexibleSpace: FlexibleSpaceBar(
        background: Stack(
          fit: StackFit.expand,
          children: [
            if (backdrop != null && backdrop.isNotEmpty)
              CachedNetworkImage(
                imageUrl: backdrop,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) =>
                    Container(color: const Color(0xFF1A1A2E)),
              )
            else
              Container(color: const Color(0xFF1A1A2E)),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x33000000),
                    Color(0x00000000),
                    Color(0xFF0A0A1A),
                  ],
                  stops: [0, 0.55, 1],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfo(StremioMeta meta, AsyncValue<StremioMeta?> detailAsync) {
    final facts = <String>[
      if (meta.year != null) '${meta.year}',
      if (meta.rating != null) '★ ${meta.rating!.toStringAsFixed(1)}',
      if (meta.runtimeMinutes != null) '${meta.runtimeMinutes} min',
      if (meta.isSeries && meta.videos.isNotEmpty)
        '${meta.videos.length} episodes',
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 108,
                  height: 160,
                  child: meta.poster != null && meta.poster!.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: meta.poster!,
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) => _posterPlaceholder(),
                        )
                      : _posterPlaceholder(),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      meta.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (facts.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        facts.join(' • '),
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 13,
                        ),
                      ),
                    ],
                    if (meta.genres.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final genre in meta.genres.take(6))
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1A1A2E),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                genre,
                                style: const TextStyle(
                                  color: Colors.white60,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (meta.description != null && meta.description!.isNotEmpty)
            Text(
              meta.description!,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          if (detailAsync.hasError) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
              decoration: BoxDecoration(
                color: Colors.orangeAccent.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Colors.orangeAccent.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.info_outline,
                    color: Colors.orangeAccent,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'No se pudo cargar la ficha completa: '
                      '${detailAsync.error}',
                      style: const TextStyle(
                        color: Colors.orangeAccent,
                        fontSize: 12,
                        height: 1.3,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        ref.invalidate(stremioMetaProvider(_params)),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _posterPlaceholder() {
    return Container(
      color: const Color(0xFF1A1A2E),
      child: const Center(
        child: Icon(Icons.movie, color: Colors.white24, size: 36),
      ),
    );
  }

  Widget _buildSeasonTabs(List<int> seasons, int selected) {
    return SizedBox(
      height: 48,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: seasons.length,
        itemBuilder: (context, index) {
          final season = seasons[index];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ChoiceChip(
              label: Text('Season $season'),
              selected: season == selected,
              selectedColor: const Color(0xFF6C5CE7),
              backgroundColor: const Color(0xFF1A1A2E),
              labelStyle: TextStyle(
                color: season == selected ? Colors.white : Colors.white60,
              ),
              side: BorderSide.none,
              onSelected: (_) => setState(() => _selectedSeason = season),
            ),
          );
        },
      ),
    );
  }

  Widget _buildEpisodes(StremioMeta meta, int season) {
    final videos = meta.videosOfSeason(season);
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final video = videos[index];
          return _EpisodeRow(
            video: video,
            onPlay: _resolving ? null : () => _play(meta, video),
          );
        },
        childCount: videos.length,
      ),
    );
  }

  Widget _buildPlayButton(StremioMeta meta) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: _resolving ? null : () => _play(meta, null),
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
            textStyle: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _play(StremioMeta meta, StremioVideo? video) async {
    final addonId = video?.id ?? meta.id;
    final imdbId =
        meta.imdbId ?? (meta.id.startsWith('tt') ? meta.id : '');
    final params = AddonStreamParams(
      addonType: meta.type,
      addonId: addonId,
      imdbId: imdbId,
      season: video?.season,
      episode: video?.episode,
    );
    final title = video == null ? meta.name : '${meta.name} ${video.code}';

    setState(() => _resolving = true);
    // Igual que en la ficha de Trakt: el canal en vivo suelta el altavoz al
    // pedir la reproducción, no medio minuto después al abrir el reproductor.
    await ref.read(playerServiceProvider).stop();
    try {
      // Si este título ya se abrió con un release que funcionó, se reabre por
      // su hash sin volver a preguntar a los addons.
      if (await _reopenRemembered(meta, video, title)) return;
      final result = await awaitProviderFuture(
        ref,
        addonStreamsProvider(params),
      );
      if (!mounted) return;
      if (result.isEmpty) {
        _snackbar(_noStreamsMessage(result));
        return;
      }
      await showStreamPicker(
        context,
        result: result,
        title: title,
        onPlay: (stream) => _playSource(stream, title, meta, video),
        onDownload: (stream) => _downloadSource(stream, meta),
      );
    } catch (e) {
      if (mounted) _snackbar('Stream error: $e');
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  Future<void> _playSource(
    StreamSource stream,
    String title,
    StremioMeta meta,
    StremioVideo? video,
  ) async {
    try {
      final repo = await ref.read(showsRepositoryProvider.future);
      final url = await resolveSourceUrl(
        repo,
        stream,
        onProgress: (label, progress) {
          if (!mounted) return;
          _snackbar(progress > 0 ? '$label ($progress%)' : label);
        },
      );
      if (url == null || url.isEmpty) {
        _snackbar('Stream unavailable — try another source');
        return;
      }
      if (!mounted) return;
      final playback = PlaybackRequest.forStremio(
        meta: meta,
        video: video,
        title: title,
        sourceId: stream.id,
      );
      context.push('/player', extra: {
        'streamUrl': url,
        'channelName': title,
        'channelLogo': meta.poster ?? '',
        // Las cabeceras del addon sólo valen para su URL directa: un enlace
        // resuelto por debrid ya no pertenece a ese CDN.
        if (stream.isDirect) 'httpHeaders': stream.headers,
        'playback': playback,
      });
      // Se guarda el fichero (hash + índice + calidad), nunca el enlace.
      if (stream.infoHash != null) {
        unawaited(
          ReleaseMemory(dao: PlaybackDao(ref.read(databaseProvider)))
              .remember(playback, stream),
        );
      }
    } on SourceUnavailableException catch (e) {
      _snackbar(e.message);
    } on DebridUnavailableException catch (e) {
      _snackbar(e.message);
    } catch (e) {
      _snackbar('$e');
    }
  }

  /// Reabre el release recordado de este título sin abrir el selector.
  ///
  /// Devuelve false si no hay memoria utilizable; un fallo del debrid suma en
  /// `fail_count` y, tras dos, ese release deja de ofrecerse.
  Future<bool> _reopenRemembered(
    StremioMeta meta,
    StremioVideo? video,
    String title,
  ) async {
    // Igual que en la ficha de Trakt: una serie sin episodio elegido no se
    // reabre, porque el pack no dice qué fichero es.
    if (meta.isSeries && video == null) return false;
    final repo = await ref.read(showsRepositoryProvider.future);
    if (!repo.hasDebrid) return false;
    final memory = ReleaseMemory(dao: PlaybackDao(ref.read(databaseProvider)));
    final reopened = await memory.reopen(
      repo,
      mediaKey: mediaKeyForStremio(meta),
      season: video?.season,
      episode: video?.episode,
      onProgress: (status, progress) {
        if (!mounted) return;
        final label = friendlyDebridStatus(status);
        _snackbar(progress > 0 ? '$label ($progress%)' : label);
      },
    );
    if (reopened == null || !mounted) return false;
    final playback = PlaybackRequest.forStremio(
      meta: meta,
      video: video,
      title: title,
      sourceId: reopened.sourceId,
    );
    context.push('/player', extra: {
      'streamUrl': reopened.url,
      'channelName': title,
      'channelLogo': meta.poster ?? '',
      'playback': playback,
    });
    return true;
  }

  Future<void> _downloadSource(StreamSource stream, StremioMeta meta) async {
    try {
      final repo = await ref.read(showsRepositoryProvider.future);
      final url = await resolveSourceUrl(
        repo,
        stream,
        onProgress: (label, progress) {
          if (!mounted) return;
          _snackbar(progress > 0 ? '$label ($progress%)' : label);
        },
      );
      if (url == null || url.isEmpty) {
        _snackbar('Download unavailable — try another source');
        return;
      }
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (mounted) _snackbar('Download started in browser');
      } else {
        _snackbar('Could not open download URL');
      }
    } on SourceUnavailableException catch (e) {
      _snackbar(e.message);
    } on DebridUnavailableException catch (e) {
      _snackbar(e.message);
    } catch (e) {
      _snackbar('$e');
    }
  }

  String _noStreamsMessage(StreamSearchResult result) {
    if (result.hasFailures) {
      final names = result.failures.map((f) => f.providerName).join(', ');
      return 'No streams found — $names no respondió';
    }
    return 'No streams found';
  }

  void _snackbar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFF1A1A2E),
      ),
    );
  }
}

class _EpisodeRow extends StatelessWidget {
  final StremioVideo video;
  final VoidCallback? onPlay;

  const _EpisodeRow({required this.video, this.onPlay});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPlay,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 120,
                height: 68,
                child: video.thumbnail != null && video.thumbnail!.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: video.thumbnail!,
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) => const _EpisodePlaceholder(),
                      )
                    : const _EpisodePlaceholder(),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${video.episode ?? '-'}. '
                    '${video.title ?? 'Episode ${video.episode ?? ''}'}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    video.code,
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
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
}

class _EpisodePlaceholder extends StatelessWidget {
  const _EpisodePlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1A1A2E),
      child: const Center(
        child: Icon(Icons.play_arrow, color: Colors.white24),
      ),
    );
  }
}
