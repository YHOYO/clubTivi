import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/datasources/local/playback_dao.dart';
import '../../data/models/playback_request.dart';
import '../../data/services/release_memory.dart';
import '../providers/provider_manager.dart';
import 'shows_providers.dart';

/// Lo último visto, de más reciente a más antiguo (sin lo terminado).
///
/// El DAO es el único que sabe de las tablas; aquí sólo se expone a la UI.
final recentlyWatchedProvider = FutureProvider<List<RecentlyWatched>>((
  ref,
) async {
  final dao = PlaybackDao(ref.watch(databaseProvider));
  return dao.recentlyWatched(limit: 12);
});

/// Fila de «continuar viendo».
///
/// Reabre el release recordado sin volver a buscar en addons: pulsar una
/// tarjeta reanuda el mismo fichero por donde iba. La equis olvida el título
/// (progreso y release), que es la única acción que borra filas.
class ContinueWatchingRail extends ConsumerWidget {
  const ContinueWatchingRail({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(recentlyWatchedProvider).valueOrNull ?? const [];
    if (items.isEmpty) return const SizedBox.shrink();

    return Padding(
      key: const ValueKey('continue-watching'),
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Continue watching',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          SizedBox(
            height: 148,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) => _ContinueCard(
                item: items[index],
                onResume: () => _resume(context, ref, items[index]),
                onForget: () => _forget(context, ref, items[index]),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Reabre el release recordado y entra al reproductor.
  ///
  /// Si el debrid ya no lo sirve, el aviso lo dice y no se abre nada: aquí no
  /// hay búsqueda de fuentes a la que caer, así que no se finge que funciona.
  Future<void> _resume(
    BuildContext context,
    WidgetRef ref,
    RecentlyWatched item,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('Opening remembered release…')),
    );
    final repo = await ref.read(showsRepositoryProvider.future);
    final memory = ReleaseMemory(dao: PlaybackDao(ref.read(databaseProvider)));
    final reopened = await memory.reopen(
      repo,
      mediaKey: item.media.mediaKey,
      season: item.progress.season,
      episode: item.progress.episode,
    );
    messenger.clearSnackBars();
    if (reopened == null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'That release is no longer available — open the title to pick '
            'another one',
          ),
        ),
      );
      return;
    }
    if (!context.mounted) return;
    final playback = PlaybackRequest(
      kind: item.media.kind == 'movie'
          ? PlaybackKind.movie
          : PlaybackKind.series,
      mediaKey: item.media.mediaKey,
      title: item.media.title,
      sourceId: reopened.sourceId,
      season: item.progress.season,
      episode: item.progress.episode,
    );
    await context.push(
      '/player',
      extra: {
        'streamUrl': reopened.url,
        'channelName': item.media.title,
        'channelLogo': item.media.posterUrl ?? '',
        // La fila ya guarda el título sin el código del capítulo; el
        // reproductor lo conserva al volver a escribir el progreso.
        'mediaTitle': item.media.title,
        'playback': playback,
      },
    );
    ref.invalidate(recentlyWatchedProvider);
  }

  Future<void> _forget(
    BuildContext context,
    WidgetRef ref,
    RecentlyWatched item,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove from Continue watching?'),
        content: Text(
          '“${item.media.title}” loses its progress and the remembered '
          'release. You can start it again from its page.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await PlaybackDao(ref.read(databaseProvider)).forget(item.media.mediaKey);
    ref.invalidate(recentlyWatchedProvider);
  }
}

/// Lo que se ve cuando no hay carátula (o cuando la guardada ya no carga).
class _PosterPlaceholder extends StatelessWidget {
  const _PosterPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1B1B33),
      child: const Icon(
        Icons.play_circle_outline,
        color: Colors.white38,
        size: 32,
      ),
    );
  }
}

class _ContinueCard extends StatelessWidget {
  final RecentlyWatched item;
  final VoidCallback onResume;
  final VoidCallback onForget;

  const _ContinueCard({
    required this.item,
    required this.onResume,
    required this.onForget,
  });

  @override
  Widget build(BuildContext context) {
    final progress = item.progress;
    final remaining = progress.remaining.inMinutes;
    final detail = progress.season != null && progress.episode != null
        ? 'S${progress.season} · E${progress.episode}'
        : 'Movie';
    final subtitle = remaining > 0 ? '$detail · ${remaining}m left' : detail;
    final poster = item.media.posterUrl;

    return SizedBox(
      width: 132,
      child: InkWell(
        key: ValueKey('continue-card-${item.media.mediaKey}'),
        borderRadius: BorderRadius.circular(10),
        onTap: onResume,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: 132,
                    height: 92,
                    child: poster == null || poster.isEmpty
                        ? const _PosterPlaceholder()
                        : Image.network(
                            poster,
                            fit: BoxFit.cover,
                            // Una carátula caída no deja el hueco vacío: el
                            // marcador de reproducción ocupa su sitio.
                            errorBuilder: (_, _, _) =>
                                const _PosterPlaceholder(),
                          ),
                  ),
                ),
                Positioned(
                  top: 0,
                  right: 0,
                  child: IconButton(
                    key: ValueKey('continue-remove-${item.media.mediaKey}'),
                    iconSize: 18,
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Remove from Continue watching',
                    icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed: onForget,
                  ),
                ),
                if (progress.duration > Duration.zero)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: LinearProgressIndicator(
                      value:
                          (progress.position.inSeconds /
                                  progress.duration.inSeconds)
                              .clamp(0.0, 1.0),
                      minHeight: 3,
                      backgroundColor: Colors.white12,
                      color: const Color(0xFF6C5CE7),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              item.media.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
