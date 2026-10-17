import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../data/models/show.dart';
import '../../data/models/stream_search_result.dart';
import '../../data/models/stream_source.dart';
import '../../data/models/language_preferences.dart';
import '../../data/services/debrid_settings.dart';
import '../../data/services/language_preferences_store.dart';
import '../../data/services/stream_playback.dart';
import '../../data/services/p2p/p2p_platform.dart';
import '../../data/services/p2p/p2p_providers.dart';
import '../../data/services/p2p/rqbit_engine.dart';
import '../../data/services/p2p/rqbit_models.dart';
import 'p2p_progress_dialog.dart';
import 'shows_providers.dart';

/// Detail screen for a show or movie — backdrop, info, seasons, episodes, play
class ShowDetailScreen extends ConsumerStatefulWidget {
  final int traktId;
  final Show? initialShow; // Passed via extra for instant display

  const ShowDetailScreen({
    super.key,
    required this.traktId,
    this.initialShow,
  });

  @override
  ConsumerState<ShowDetailScreen> createState() => _ShowDetailScreenState();
}

class _ShowDetailScreenState extends ConsumerState<ShowDetailScreen> {
  int? _selectedSeason; // null until initialized
  bool _resolving = false;
  int _lastSeasonCount = 0; // track when seasons change
  final _seasonScrollController = ScrollController();
  Color? _dominantColor; // extracted from backdrop image
  String? _lastBackdropUrl; // avoid re-extracting for the same URL

  static const _seasonPrefPrefix = 'show_last_season_';

  /// Initialize season: use persisted preference, or default to latest season
  void _initSeason(ShowDetail detail) {
    // Skip if no seasons yet, or re-init if season count changed
    if (detail.seasons.isEmpty) return;
    if (_selectedSeason != null && detail.seasons.length == _lastSeasonCount) return;
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
      final chipCenter = index * chipWidth + chipWidth / 2 + 20; // +20 for padding
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
    ).then((palette) {
      if (!mounted) return;
      final color = palette.dominantColor?.color ??
          palette.mutedColor?.color ??
          palette.darkMutedColor?.color;
      if (color != null) {
        setState(() => _dominantColor = color);
      }
    }).catchError((_) {});
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
    final effectiveSeason = _selectedSeason ?? (detail.seasons.isNotEmpty
        ? detail.seasons.map((s) => s.number).reduce((a, b) => a > b ? a : b)
        : 1);
    final show = detail.show;
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
                    errorWidget: (_, _, _) => Container(color: const Color(0xFF1A1A2E)),
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
                    if (show.year != null)
                      _chip('${show.year}'),
                    if (show.rating != null)
                      _chip('★ ${show.rating!.toStringAsFixed(1)}'),
                    if (show.runtime != null)
                      _chip('${show.runtime} min'),
                    if (show.status != null)
                      _chip(show.status!),
                    if (show.network != null)
                      _chip(show.network!),
                  ],
                ),
                const SizedBox(height: 8),
                // Genres
                if (show.genres.isNotEmpty)
                  Wrap(
                    spacing: 8,
                    children: show.genres
                        .take(5)
                        .map((g) => Chip(
                              label: Text(g, style: const TextStyle(fontSize: 11)),
                              backgroundColor: const Color(0xFF1A1A2E),
                              labelStyle: const TextStyle(color: Colors.white60),
                              side: BorderSide.none,
                              padding: EdgeInsets.zero,
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ))
                        .toList(),
                  ),
                const SizedBox(height: 16),
                // Overview
                if (show.overview != null)
                  Text(
                    show.overview!,
                    style: const TextStyle(color: Colors.white70, fontSize: 15, height: 1.5),
                  ),
                const SizedBox(height: 20),

                // Play button (for movies) or Season selector (for shows)
                if (show.type == ShowType.movie) _buildPlayMovieButton(show),

                if (loading)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(
                      child: CircularProgressIndicator(color: Color(0xFF6C5CE7)),
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

  Widget _buildPlayMovieButton(Show show) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _resolving ? null : () => _playContent(show),
        icon: _resolving
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
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
          child: Center(child: CircularProgressIndicator(color: Color(0xFF6C5CE7))),
        ),
      ),
      error: (err, _) => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('Error: $err', style: const TextStyle(color: Colors.redAccent)),
        ),
      ),
      data: (episodes) => SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => _EpisodeTile(
            episode: episodes[index],
            show: show,
            onPlay: () => _playEpisode(show, episodes[index]),
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
    try {
      final result = await ref.read(
        resolveStreamProvider(StreamResolveParams(show.imdbId!)).future,
      );
      if (result.isEmpty) {
        _showSnackbar(_noStreamsMessage(result));
        return;
      }
      if (!mounted) return;
      _showStreamPicker(result, show.title);
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
    setState(() => _resolving = true);
    try {
      final result = await ref.read(
        resolveStreamProvider(StreamResolveParams(
          show.imdbId!,
          season: episode.season,
          episode: episode.number,
        )).future,
      );
      if (result.isEmpty) {
        _showSnackbar(_noStreamsMessage(result, 'for ${episode.code}'));
        return;
      }
      if (!mounted) return;
      _showStreamPicker(result, '${show.title} ${episode.code}');
    } catch (e) {
      _showSnackbar('Stream error: $e');
    } finally {
      if (mounted) setState(() => _resolving = false);
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

  void _showStreamPicker(StreamSearchResult result, String title) {
    final streams = result.sources;
    final preferences = ref.read(languagePreferencesProvider);
    // Filtro local del selector: no toca el ranking —ya aplicado en `streams`—
    // ni el orden que ve el usuario.
    String? languageFilter;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        maxChildSize: 0.85,
        minChildSize: 0.3,
        expand: false,
        builder: (ctx, scrollController) => SafeArea(
          child: StatefulBuilder(
            builder: (ctx, setSheetState) {
              final languages = _languagesIn(streams, preferences);
              final visible = _filterByLanguage(streams, languageFilter);
              return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Handle bar
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(top: 12),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Text(
                  'Select Stream',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  languageFilter == null
                      ? '$title • ${streams.length} sources'
                      : '$title • ${visible.length} of ${streams.length} sources'
                          ' • ${languageLabel(languageFilter)}',
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (languages.length > 1)
                _languageFilterRow(
                  languages: languages,
                  selected: languageFilter,
                  onSelected: (code) =>
                      setSheetState(() => languageFilter = code),
                ),
              if (streams.any((s) => !s.isAvailable))
                _buildUnavailableNotice(ctx, streams),
              if (result.hasFailures) _buildFailureNotice(ctx, result.failures),
              const SizedBox(height: 8),
              const Divider(color: Colors.white12, height: 1),
              Expanded(
                child: ListView.builder(
                  controller: scrollController,
                  itemCount: visible.length,
                  itemBuilder: (ctx, index) {
                    final stream = visible[index];
                    final available = stream.isAvailable;
                    return ListTile(
                      leading: _streamQualityBadge(stream.quality),
                      title: Text(
                        stream.title,
                        style: TextStyle(
                          color: available ? Colors.white : Colors.white38,
                          fontSize: 13,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            [
                              stream.providerName,
                              if (stream.seeds != null) '👤 ${stream.seeds}',
                              // Un torrent sin debrid lo sirve el motor P2P local.
                              if (available &&
                                  stream.infoHash != null &&
                                  !stream.isCached)
                                'P2P',
                              if (!available)
                                stream.unavailableReason ?? kDebridRequiredReason,
                            ].join(' • '),
                            style: TextStyle(
                              color: available
                                  ? Colors.white38
                                  : Colors.orangeAccent.withValues(alpha: 0.85),
                              fontSize: 12,
                            ),
                          ),
                          _languageBadges(stream, preferences),
                        ],
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (available)
                            IconButton(
                              icon: const Icon(Icons.download_rounded, color: Colors.white54, size: 24),
                              tooltip: 'Download via browser',
                              onPressed: () {
                                Navigator.pop(ctx);
                                _resolveAndDownload(stream, title);
                              },
                            ),
                          IconButton(
                            icon: Icon(
                              available ? Icons.play_circle_fill : Icons.lock_outline,
                              color: available
                                  ? (stream.isCached
                                      ? const Color(0xFF6C5CE7)
                                      : const Color(0xFF6C5CE7).withValues(alpha: 0.6))
                                  : Colors.orangeAccent.withValues(alpha: 0.7),
                              size: 32,
                            ),
                            tooltip: available
                                ? 'Play'
                                : stream.unavailableReason ??
                                    kDebridRequiredReason,
                            onPressed: () {
                              Navigator.pop(ctx);
                              if (available) {
                                _resolveAndPlay(stream, title);
                              } else {
                                _showUnavailable(stream);
                              }
                            },
                          ),
                        ],
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        if (available) {
                          _resolveAndPlay(stream, title);
                        } else {
                          _showUnavailable(stream);
                        }
                      },
                    );
                  },
                ),
              ),
            ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Idiomas que aparecen en alguna fuente, con las preferencias del usuario
  /// primero (como el ranking) y el resto por código.
  List<String> _languagesIn(
    List<StreamSource> streams,
    LanguagePreferences preferences,
  ) {
    final codes = <String>{};
    for (final stream in streams) {
      codes.addAll(_streamLanguages(stream));
    }
    return _orderedLanguages(codes, preferences);
  }

  List<String> _orderedLanguages(
    Set<String> codes,
    LanguagePreferences preferences,
  ) {
    final remaining = codes.toSet();
    final ordered = <String>[];
    for (final preferred in preferences.audioOrder) {
      final normalized = normalizeLanguageCode(preferred);
      if (normalized != null && remaining.remove(normalized)) {
        ordered.add(normalized);
      }
    }
    final rest = remaining.toList()..sort();
    return [...ordered, ...rest];
  }

  Set<String> _streamLanguages(StreamSource stream) {
    final codes = <String>{};
    for (final raw in {...stream.audioLanguages, ...stream.subtitleLanguages}) {
      final normalized = normalizeLanguageCode(raw);
      if (normalized != null) codes.add(normalized);
    }
    return codes;
  }

  /// Filtra sin reordenar: una fuente entra si declara el idioma en audio o en
  /// subtítulos, que es como se busca «algo en español».
  List<StreamSource> _filterByLanguage(
    List<StreamSource> streams,
    String? language,
  ) {
    if (language == null) return streams;
    return [
      for (final stream in streams)
        if (_streamLanguages(stream).contains(language)) stream,
    ];
  }

  Widget _languageFilterRow({
    required List<String> languages,
    required String? selected,
    required ValueChanged<String?> onSelected,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          ChoiceChip(
            key: const ValueKey('language-filter-all'),
            label: const Text('All'),
            selected: selected == null,
            onSelected: (_) => onSelected(null),
            backgroundColor: const Color(0xFF12122A),
            selectedColor: const Color(0xFF6C5CE7),
            labelStyle: TextStyle(
              color: selected == null ? Colors.white : Colors.white70,
              fontSize: 12,
            ),
            side: BorderSide.none,
            visualDensity: VisualDensity.compact,
          ),
          for (final code in languages)
            ChoiceChip(
              key: ValueKey('language-filter-$code'),
              label: Text(languageLabel(code)),
              selected: selected == code,
              onSelected: (_) => onSelected(code),
              backgroundColor: const Color(0xFF12122A),
              selectedColor: const Color(0xFF6C5CE7),
              labelStyle: TextStyle(
                color: selected == code ? Colors.white : Colors.white70,
                fontSize: 12,
              ),
              side: BorderSide.none,
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }

  /// Badges de los idiomas que declara la fuente: audio y subtítulos (`CC`).
  Widget _languageBadges(
    StreamSource stream,
    LanguagePreferences preferences,
  ) {
    final audio = _orderedLanguages(stream.audioLanguages, preferences);
    final subtitles =
        _orderedLanguages(stream.subtitleLanguages, preferences);
    if (audio.isEmpty && subtitles.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final code in audio)
            _languageBadgeChip(languageBadge(code), Colors.lightBlueAccent),
          for (final code in subtitles)
            _languageBadgeChip(
              'CC ${languageBadge(code)}',
              Colors.greenAccent,
            ),
        ],
      ),
    );
  }

  Widget _languageBadgeChip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600),
      ),
    );
  }

  /// Un addon caído, lento o con basura queda fuera de la lista, pero se
  /// explica aquí para que el usuario sepa que faltan fuentes y por qué.
  Widget _buildFailureNotice(
    BuildContext sheetContext,
    List<StreamProviderFailure> failures,
  ) {
    final summary = failures
        .map((f) => '${f.providerName}: ${f.reason}')
        .join('\n');
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(
        color: Colors.redAccent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.redAccent.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.cloud_off_rounded, color: Colors.redAccent, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              failures.length == 1
                  ? 'Un addon no respondió\n$summary'
                  : '${failures.length} addons no respondieron\n$summary',
              style: const TextStyle(
                color: Colors.redAccent,
                fontSize: 12,
                height: 1.3,
              ),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(sheetContext);
              context.push('/stremio-addons');
            },
            child: const Text('Addons'),
          ),
        ],
      ),
    );
  }

  Widget _buildUnavailableNotice(BuildContext sheetContext, List<StreamSource> streams) {
    final unavailable = streams.where((s) => !s.isAvailable).length;
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: Colors.orangeAccent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.orangeAccent.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.lock_outline, color: Colors.orangeAccent, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              unavailable == streams.length
                  ? 'None of these sources can play on this device. Enable a debrid service to use them.'
                  : '$unavailable of ${streams.length} sources cannot play on this device.',
              style: const TextStyle(
                color: Colors.orangeAccent,
                fontSize: 12,
                height: 1.3,
              ),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(sheetContext);
              context.push('/debrid-services');
            },
            child: const Text('Settings'),
          ),
        ],
      ),
    );
  }

  /// Explica por qué una fuente no se puede reproducir y ofrece el atajo a
  /// Ajustes, en vez de dejar que la reproducción falle sin motivo.
  void _showUnavailable(StreamSource stream) {
    final reason = stream.unavailableReason ?? kDebridRequiredReason;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('Source unavailable'),
        content: Text(
          reason == kP2pUnavailableReason
              ? '$reason.\n\nOpen this source in the desktop app, or pick '
                  'another source.'
              : '$reason.\n\nEnable a debrid service in Settings → Debrid '
                  'Services, or pick another source.',
          style: const TextStyle(color: Colors.white70, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              context.push('/debrid-services');
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  Future<void> _resolveAndPlay(StreamSource stream, String title) async {
    // Una URL directa no depende de debrid: se reproduce tal cual, con las
    // cabeceras que exija el origen.
    if (stream.isDirect) {
      _launchPlayer(stream.url!, title, source: stream);
      return;
    }
    if (!stream.isAvailable) {
      _showUnavailable(stream);
      return;
    }

    final repo = await ref.read(showsRepositoryProvider.future);
    final infoHash = stream.infoHash;
    final hasTorrent = infoHash != null && infoHash.isNotEmpty;
    final p2pPossible = hasTorrent && isP2pPlaybackSupported();

    // Sin debrid, un torrent con hash lo reproduce el motor P2P local.
    if (p2pPossible && !repo.hasDebrid) {
      await _playP2p(stream, title);
      return;
    }

    final magnet = stream.magnetUrl;
    if (magnet == null || magnet.isEmpty) {
      _showSnackbar('This source has no playable link');
      return;
    }
    _showSnackbar(stream.isCached ? 'Preparing stream…' : 'Preparing stream — this may take a moment…');
    setState(() => _resolving = true);
    try {
      final resolved = await repo.resolveMagnet(
        magnet,
        onProgress: (status, progress) {
          if (mounted) {
            final label = _friendlyStatus(status);
            _showSnackbar(progress > 0 ? '$label ($progress%)' : label);
          }
        },
      );
      if (resolved == null || resolved.url.isEmpty) {
        if (p2pPossible) {
          _showSnackbar('Debrid could not resolve it — trying P2P…');
          await _playP2p(stream, title);
          return;
        }
        _showSnackbar('Stream unavailable — try another source');
        return;
      }
      if (!mounted) return;
      _launchPlayer(resolved.url, title);
    } on DebridUnavailableException {
      if (p2pPossible) {
        await _playP2p(stream, title);
        return;
      }
      _showSnackbar(kDebridRequiredReason);
    } catch (e) {
      // Un debrid caído no debe impedir la reproducción si hay un hash: el
      // motor P2P es la red de seguridad.
      if (p2pPossible) {
        _showSnackbar('Debrid failed — trying P2P…');
        await _playP2p(stream, title);
        return;
      }
      _showSnackbar('$e');
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  /// Arranca el motor P2P con una espera visible y errores accionables.
  Future<void> _playP2p(StreamSource stream, String title) async {
    final hash = stream.infoHash;
    if (hash == null || hash.isEmpty) {
      _showSnackbar('This source has no info hash for P2P playback');
      return;
    }
    if (!isP2pPlaybackSupported()) {
      _showSnackbar(kP2pUnavailableReason);
      return;
    }

    setState(() => _resolving = true);
    final progress = ValueNotifier<P2pProgress>(
      const P2pProgress(P2pPhase.locatingEngine, 'Looking for the P2P engine…'),
    );
    final cancelled = ValueNotifier(false);
    var dialogOpen = true;

    void closeDialog() {
      if (!dialogOpen || !mounted) return;
      dialogOpen = false;
      Navigator.of(context, rootNavigator: true).pop();
    }

    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => P2pProgressDialog(
        progress: progress,
        onCancel: () {
          cancelled.value = true;
          if (dialogOpen && mounted) {
            dialogOpen = false;
            Navigator.of(dialogContext).pop();
          }
        },
      ),
    ));

    try {
      final engine = await ref.read(rqbitEngineProvider.future);
      final playback = await engine.prepare(
        P2pStreamRequest(
          infoHash: hash,
          magnetUrl: stream.magnetUrl,
          fileIndex: stream.fileIdx,
          title: stream.title,
        ),
        onProgress: (value) => progress.value = value,
        isCancelled: () => cancelled.value,
      );
      closeDialog();
      // Si el usuario canceló justo cuando terminaba la preparación, no se
      // abre el reproductor.
      if (cancelled.value || !mounted) return;
      _launchPlayer(playback.streamUrl.toString(), title);
    } on P2pCancelledException {
      closeDialog();
    } catch (error) {
      closeDialog();
      if (!mounted) return;
      _showP2pError(error);
    } finally {
      progress.dispose();
      cancelled.dispose();
      if (mounted) setState(() => _resolving = false);
    }
  }

  void _showP2pError(Object error) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('P2P playback failed'),
        content: Text(
          p2pErrorMessage(error),
          style: const TextStyle(color: Colors.white70, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              context.push('/debrid-services');
            },
            child: const Text('Use debrid instead'),
          ),
        ],
      ),
    );
  }

  Future<void> _resolveAndDownload(StreamSource stream, String title) async {
    if (stream.isDirect) {
      await _openDownloadUrl(stream.url!);
      return;
    }
    if (!stream.isAvailable) {
      _showUnavailable(stream);
      return;
    }
    final repo = await ref.read(showsRepositoryProvider.future);
    final infoHash = stream.infoHash;
    if (!repo.hasDebrid && infoHash != null && infoHash.isNotEmpty) {
      _showSnackbar(
        'P2P sources download while you play; the file is saved in Downloads/clubTivi',
      );
      return;
    }
    final magnet = stream.magnetUrl;
    if (magnet == null || magnet.isEmpty) {
      _showSnackbar('This source has no downloadable link');
      return;
    }
    _showSnackbar(stream.isCached ? 'Preparing download…' : 'Preparing download — this may take a moment…');
    setState(() => _resolving = true);
    try {
      final resolved = await repo.resolveMagnet(
        magnet,
        onProgress: (status, progress) {
          if (mounted) {
            final label = _friendlyStatus(status);
            _showSnackbar(progress > 0 ? '$label ($progress%)' : label);
          }
        },
      );
      if (resolved == null || resolved.url.isEmpty) {
        _showSnackbar('Download unavailable — try another source');
        return;
      }
      await _openDownloadUrl(resolved.url);
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

  Widget _streamQualityBadge(String? quality) {
    final color = switch (quality) {
      '4K' => Colors.amber,
      '1080p' => Colors.greenAccent,
      '720p' => Colors.lightBlueAccent,
      _ => Colors.white38,
    };
    return Container(
      width: 52,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        quality ?? '?',
        textAlign: TextAlign.center,
        style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold),
      ),
    );
  }

  /// Abre el reproductor. [source] solo se pasa cuando la URL es la directa del
  /// addon: un enlace resuelto por debrid ya no necesita las cabeceras del
  /// origen original.
  void _launchPlayer(String url, String title, {StreamSource? source}) {
    debugPrint('[Shows] Launching player: url=$url, title=$title');
    if (url.isEmpty) {
      _showSnackbar('Stream URL is empty — try another source');
      return;
    }
    context.push('/player', extra: {
      'streamUrl': url,
      'channelName': title,
      'channelLogo': widget.initialShow?.posterUrl ?? '',
      'headers': playbackHeaders(source),
      'needsProxy': shouldProxyStream(source),
    });
  }

  String _friendlyStatus(String status) {
    switch (status) {
      case 'magnet_conversion':
        return 'Processing magnet';
      case 'waiting_files_selection':
        return 'Selecting files';
      case 'queued':
        return 'Queued';
      case 'downloading':
        return 'Downloading';
      case 'downloaded':
        return 'Preparing stream';
      case 'uploading':
        return 'Uploading';
      case 'compressing':
        return 'Compressing';
      default:
        return status.replaceAll('_', ' ');
    }
  }

  void _showSnackbar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: const Color(0xFF1A1A2E)),
    );
  }

  Widget _chip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text, style: const TextStyle(color: Colors.white60, fontSize: 13)),
    );
  }
}

class _EpisodeTile extends StatelessWidget {
  final Episode episode;
  final Show show;
  final VoidCallback onPlay;

  const _EpisodeTile({
    required this.episode,
    required this.show,
    required this.onPlay,
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
                      style: const TextStyle(color: Colors.white38, fontSize: 12),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  if (episode.runtime != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '${episode.runtime} min',
                        style: const TextStyle(color: Colors.white24, fontSize: 11),
                      ),
                    ),
                ],
              ),
            ),
            // Play icon
            const Icon(Icons.play_circle_outline, color: Color(0xFF6C5CE7), size: 32),
          ],
        ),
      ),
    );
  }

  Widget _placeholder() {
    return Container(
      color: const Color(0xFF1A1A2E),
      child: const Center(
        child: Icon(Icons.play_arrow, color: Colors.white24),
      ),
    );
  }
}
