import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import '../../data/models/show.dart';
import '../../data/models/stremio_addon.dart';
import 'shows_providers.dart';

/// Main shows screen with poster grid organized by category
class ShowsScreen extends ConsumerStatefulWidget {
  const ShowsScreen({super.key});

  @override
  ConsumerState<ShowsScreen> createState() => _ShowsScreenState();
}

class _ShowsScreenState extends ConsumerState<ShowsScreen> {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  final _keyboardFocusNode = FocusNode();
  bool _isSearching = false;
  int _selectedCategory = 0; // 0 = Favorites (default)

  static const _categories = [
    'Favorites',
    'From addons',
    'Trending Shows',
    'Popular Shows',
    'Trending Movies',
    'Popular Movies',
  ];

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _keyboardFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final apiKeys = ref.watch(showsApiKeysProvider);
    // Un addon con catálogos ya da contenido: no hace falta Trakt ni TMDB
    // para entrar a descubrirlo.
    final hasAddonCatalogs = ref
        .watch(enabledStremioAddonsProvider)
        .any((addon) => addon.hasCatalogs);

    if (!apiKeys.hasTraktKey && !apiKeys.hasTmdbKey && !hasAddonCatalogs) {
      return _buildSetupPrompt(context);
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A1A),
      body: KeyboardListener(
        focusNode: _keyboardFocusNode,
        autofocus: !Platform.isAndroid,
        onKeyEvent: _handleKeyEvent,
        child: Column(
          children: [
            _buildHeader(context),
            if (_isSearching) _buildSearchBar(),
            _buildCategoryTabs(),
            Expanded(child: _buildContent()),
          ],
        ),
      ),
    );
  }

  Widget _buildSetupPrompt(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          Future.microtask(() {
            if (!context.mounted) return;
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/');
            }
          });
        },
      },
      child: Focus(
        autofocus: !Platform.isAndroid,
        child: Scaffold(
      backgroundColor: const Color(0xFF0A0A1A),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.movie_outlined, size: 64, color: Color(0xFF6C5CE7)),
              const SizedBox(height: 24),
              const Text(
                'Shows & Movies',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Add a Trakt or TMDB API key in Settings to browse trending '
                'shows and movies, or install a Stremio addon with catalogs '
                '(anime, Spanish movies…).',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white60, fontSize: 16),
              ),
              const SizedBox(height: 32),
              ElevatedButton.icon(
                autofocus: true,
                onPressed: () => context.go('/settings'),
                icon: const Icon(Icons.settings),
                label: const Text('Go to Settings'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6C5CE7),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                ),
              ),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: () => context.go('/stremio-addons'),
                icon: const Icon(Icons.extension_rounded),
                label: const Text('Install Stremio addons'),
                style: TextButton.styleFrom(foregroundColor: Colors.white70),
              ),
            ],
          ),
        ),
      ),
    ),
    ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => context.go('/'),
          ),
          const SizedBox(width: 12),
          const Text(
            'Shows & Movies',
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: Icon(
              _isSearching ? Icons.close : Icons.search,
              color: Colors.white70,
            ),
            onPressed: () {
              setState(() {
                _isSearching = !_isSearching;
                if (!_isSearching) {
                  _searchController.clear();
                  ref.read(showSearchQueryProvider.notifier).state = '';
                }
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: TextField(
        controller: _searchController,
        focusNode: _searchFocusNode,
        autofocus: true,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          hintText: 'Search shows & movies...',
          hintStyle: const TextStyle(color: Colors.white38),
          prefixIcon: const Icon(Icons.search, color: Colors.white38),
          filled: true,
          fillColor: const Color(0xFF1A1A2E),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
        ),
        onChanged: (query) {
          ref.read(showSearchQueryProvider.notifier).state = query;
        },
      ),
    );
  }

  Widget _buildCategoryTabs() {
    if (_isSearching) return const SizedBox.shrink();
    return SizedBox(
      height: 48,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: List.generate(_categories.length, (index) {
            final selected = index == _selectedCategory;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: ChoiceChip(
                autofocus: Platform.isAndroid && selected,
                label: Text(_categories[index]),
                selected: selected,
                selectedColor: const Color(0xFF6C5CE7),
                backgroundColor: const Color(0xFF1A1A2E),
                labelStyle: TextStyle(
                  color: selected ? Colors.white : Colors.white60,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                ),
                side: BorderSide.none,
                onSelected: (_) => setState(() => _selectedCategory = index),
              ),
            );
          }),
        ),
      ),
    );
  }

  Widget _buildContent() {
    if (_isSearching) {
      return _buildSearchResults();
    }

    switch (_selectedCategory) {
      case 0:
        return _buildFavorites();
      case 1:
        return _buildAddonCatalogs();
      case 2:
        return _buildShowGrid(ref.watch(trendingShowsProvider));
      case 3:
        return _buildShowGrid(ref.watch(popularShowsProvider));
      case 4:
        return _buildShowGrid(ref.watch(trendingMoviesProvider));
      case 5:
        return _buildShowGrid(ref.watch(popularMoviesProvider));
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildFavorites() {
    final favorites = ref.watch(favoritesProvider);
    if (favorites.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.favorite_border, size: 48, color: Colors.white24),
            SizedBox(height: 12),
            Text(
              'No favorites yet',
              style: TextStyle(color: Colors.white38, fontSize: 16),
            ),
            SizedBox(height: 4),
            Text(
              'Browse shows and tap ♥ to add them here',
              style: TextStyle(color: Colors.white24, fontSize: 13),
            ),
          ],
        ),
      );
    }
    return _buildShowGrid(AsyncValue.data(favorites));
  }

  /// Filas de los catálogos de los addons instalados: la vía para ver el
  /// contenido de AnimeFLV, Kitsu y compañía sin salir de la app.
  Widget _buildAddonCatalogs() {
    final hasAddons = ref
        .watch(enabledStremioAddonsProvider)
        .any((addon) => addon.hasCatalogs);
    if (!hasAddons) {
      return _AddonEmptyState(
        onInstall: () => context.push('/stremio-addons'),
      );
    }

    final specs = ref.watch(stremioCatalogSpecsProvider);
    if (specs.isEmpty) {
      return const Center(
        child: Text(
          'The installed addons did not return any titles',
          style: TextStyle(color: Colors.white38, fontSize: 15),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 12),
      itemCount: specs.length,
      itemBuilder: (context, index) => _CatalogRail(
        key: ValueKey('${specs[index].addon.url}/${specs[index].catalog.id}'),
        spec: specs[index],
        onOpen: (meta) => _openMeta(specs[index], meta),
      ),
    );
  }

  void _openMeta(AddonCatalogSpec spec, StremioMeta meta) {
    context.push(
      '/stremio-meta',
      extra: {'meta': meta, 'addonUrl': spec.addon.url},
    );
  }

  Widget _buildSearchResults() {
    final query = ref.watch(showSearchQueryProvider);
    if (query.isEmpty) {
      return const Center(
        child: Text(
          'Type to search...',
          style: TextStyle(color: Colors.white38, fontSize: 16),
        ),
      );
    }
    return _buildShowGrid(ref.watch(showSearchResultsProvider));
  }

  Widget _buildShowGrid(AsyncValue<List<Show>> showsAsync) {
    return showsAsync.when(
      loading: () => const Center(
        child: CircularProgressIndicator(color: Color(0xFF6C5CE7)),
      ),
      error: (error, _) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
            const SizedBox(height: 12),
            Text(
              'Failed to load: $error',
              style: const TextStyle(color: Colors.white60),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
      data: (shows) {
        if (shows.isEmpty) {
          return const Center(
            child: Text(
              'No results found',
              style: TextStyle(color: Colors.white38, fontSize: 16),
            ),
          );
        }
        return GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 180,
            childAspectRatio: 0.65,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: shows.length,
          itemBuilder: (context, index) => _ShowPosterCard(
            show: shows[index],
            onTap: () => _openShow(shows[index]),
          ),
        );
      },
    );
  }

  void _openShow(Show show) {
    context.push('/shows/${show.traktId}', extra: show);
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent) {
      // Don't intercept keys when a text field is focused
      final primaryFocus = FocusManager.instance.primaryFocus;
      if (primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() != null) {
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          primaryFocus!.unfocus();
        }
        return;
      }
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        if (_isSearching) {
          setState(() {
            _isSearching = false;
            _searchController.clear();
            ref.read(showSearchQueryProvider.notifier).state = '';
          });
        } else {
          final router = GoRouter.of(context);
          Future.microtask(() {
            if (router.canPop()) {
              router.pop();
            } else {
              router.go('/');
            }
          });
        }
      }
    }
  }
}

class _ShowPosterCard extends ConsumerWidget {
  final Show show;
  final VoidCallback onTap;

  const _ShowPosterCard({required this.show, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isFav = ref.watch(favoritesProvider.select(
      (favs) => favs.any((s) => s.traktId == show.traktId),
    ));

    return Focus(
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
             event.logicalKey == LogicalKeyboardKey.enter ||
             event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
          onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (context) {
          final hasFocus = Focus.of(context).hasFocus;
          return GestureDetector(
            onTap: onTap,
            child: Container(
              decoration: hasFocus
                  ? BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFF6C5CE7), width: 2),
                    )
                  : null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: show.posterUrl != null && show.posterUrl!.isNotEmpty
                              ? CachedNetworkImage(
                                  imageUrl: show.posterUrl!,
                                  fit: BoxFit.cover,
                                  width: double.infinity,
                                  height: double.infinity,
                                  placeholder: (_, _) => Container(
                                    color: const Color(0xFF1A1A2E),
                                    child: const Center(
                                      child: Icon(Icons.movie, color: Colors.white24, size: 40),
                                    ),
                                  ),
                                  errorWidget: (_, _, _) => _placeholderPoster(),
                                )
                              : _placeholderPoster(),
                        ),
                        // Favorite heart button
                        Positioned(
                          top: 4,
                          right: 4,
                          child: GestureDetector(
                            onTap: () => ref.read(favoritesProvider.notifier).toggle(show),
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                isFav ? Icons.favorite : Icons.favorite_border,
                                color: isFav ? Colors.redAccent : Colors.white70,
                                size: 18,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    show.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (show.year != null)
                    Text(
                      '${show.year}${show.rating != null ? ' • ★ ${show.rating!.toStringAsFixed(1)}' : ''}',
                      style: const TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _placeholderPoster() {
    return Container(
      color: const Color(0xFF1A1A2E),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.movie, color: Colors.white24, size: 40),
            const SizedBox(height: 4),
            Text(
              show.title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white38, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }
}

/// Sin addons con catálogos, la pestaña explica cómo llegar a ellos en vez de
/// quedarse vacía.
class _AddonEmptyState extends StatelessWidget {
  final VoidCallback onInstall;

  const _AddonEmptyState({required this.onInstall});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.extension_rounded,
              size: 48,
              color: Colors.white24,
            ),
            const SizedBox(height: 12),
            const Text(
              'No addon catalogs yet',
              style: TextStyle(color: Colors.white54, fontSize: 16),
            ),
            const SizedBox(height: 6),
            const Text(
              'Install an addon with catalogs (AnimeFLV, Kitsu…) to browse '
              'its content here.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onInstall,
              icon: const Icon(Icons.add_link_rounded),
              label: const Text('Install addons'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF6C5CE7),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Una fila horizontal de un catálogo de addon. Un catálogo caído se explica
/// en su propia fila y no impide ver las demás. Cuando el addon declara
/// géneros, la propia fila deja cambiarlos sin recargar el resto.
class _CatalogRail extends ConsumerStatefulWidget {
  final AddonCatalogSpec spec;
  final void Function(StremioMeta meta) onOpen;

  const _CatalogRail({
    super.key,
    required this.spec,
    required this.onOpen,
  });

  @override
  ConsumerState<_CatalogRail> createState() => _CatalogRailState();
}

class _CatalogRailState extends ConsumerState<_CatalogRail> {
  String? _genre;

  @override
  void initState() {
    super.initState();
    _genre = widget.spec.defaultGenre;
  }

  @override
  void didUpdateWidget(covariant _CatalogRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.spec.addon.url != widget.spec.addon.url ||
        oldWidget.spec.catalog.id != widget.spec.catalog.id) {
      _genre = widget.spec.defaultGenre;
    }
  }

  AddonCatalogParams get _params => AddonCatalogParams(
        addonUrl: widget.spec.addon.url,
        catalogType: widget.spec.catalog.type,
        catalogId: widget.spec.catalog.id,
        genre: _genre,
      );

  @override
  Widget build(BuildContext context) {
    final spec = widget.spec;
    final rowAsync = ref.watch(addonCatalogRowProvider(_params));
    final options = spec.catalog.genreExtra?.options ?? const <String>[];

    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    spec.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (options.isNotEmpty) _buildGenreMenu(options),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    spec.addon.name,
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 12,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          rowAsync.when(
            loading: () => const SizedBox(
              height: 246,
              child: Center(
                child: CircularProgressIndicator(
                  color: Color(0xFF6C5CE7),
                  strokeWidth: 2,
                ),
              ),
            ),
            error: (error, _) => _buildRowError('$error'),
            data: (row) {
              if (row.hasError) return _buildRowError(row.error!);
              if (row.metas.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Text(
                    'This catalog did not return any titles',
                    style: TextStyle(color: Colors.white38, fontSize: 13),
                  ),
                );
              }
              return SizedBox(
                height: 246,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: row.metas.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 12),
                  itemBuilder: (context, index) => _CatalogPosterCard(
                    meta: row.metas[index],
                    onTap: () => widget.onOpen(row.metas[index]),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildGenreMenu(List<String> options) {
    return PopupMenuButton<String>(
      tooltip: 'Genre',
      initialValue: _genre,
      onSelected: (value) => setState(() => _genre = value),
      itemBuilder: (_) => [
        for (final option in options)
          PopupMenuItem<String>(value: option, child: Text(option)),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _genre ?? 'Genre',
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
            const Icon(
              Icons.arrow_drop_down,
              color: Colors.white38,
              size: 18,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRowError(String message) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(
        color: Colors.redAccent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.redAccent.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.cloud_off_rounded,
            color: Colors.redAccent,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: Colors.redAccent, fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: () => ref.invalidate(addonCatalogRowProvider(_params)),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

class _CatalogPosterCard extends StatelessWidget {
  final StremioMeta meta;
  final VoidCallback onTap;

  const _CatalogPosterCard({required this.meta, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
          onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (context) {
          final hasFocus = Focus.of(context).hasFocus;
          return InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: 132,
              decoration: hasFocus
                  ? BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: const Color(0xFF6C5CE7),
                        width: 2,
                      ),
                    )
                  : null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 132,
                      height: 194,
                      child: meta.poster != null && meta.poster!.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: meta.poster!,
                              fit: BoxFit.cover,
                              placeholder: (_, _) =>
                                  Container(color: const Color(0xFF1A1A2E)),
                              errorWidget: (_, _, _) => _placeholder(),
                            )
                          : _placeholder(),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    meta.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (meta.year != null)
                    Text(
                      '${meta.year}',
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _placeholder() {
    return Container(
      color: const Color(0xFF1A1A2E),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.movie, color: Colors.white24, size: 36),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                meta.name,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white38, fontSize: 10),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
