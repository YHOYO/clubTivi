import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/models/stream_search_result.dart';
import '../../data/models/stream_source.dart';
import '../../data/repositories/shows_repository.dart';
import '../../data/services/debrid_settings.dart';

/// Selector de fuentes compartido por la ficha de Trakt/TMDB y la de un
/// catálogo de addon: mismas etiquetas, mismos avisos y mismas salidas.
Future<void> showStreamPicker(
  BuildContext context, {
  required StreamSearchResult result,
  required String title,
  required Future<void> Function(StreamSource stream) onPlay,
  required Future<void> Function(StreamSource stream) onDownload,
}) {
  final streams = result.sources;
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF1A1A2E),
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetContext) => DraggableScrollableSheet(
      initialChildSize: 0.5,
      maxChildSize: 0.85,
      minChildSize: 0.3,
      expand: false,
      builder: (ctx, scrollController) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text(
                'Select Stream',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                '$title • ${streams.length} sources',
                style: const TextStyle(color: Colors.white54, fontSize: 13),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (streams.any((s) => !s.isAvailable))
              _UnavailableNotice(sheetContext: sheetContext, streams: streams),
            if (result.hasFailures)
              _FailureNotice(
                sheetContext: sheetContext,
                failures: result.failures,
              ),
            const SizedBox(height: 8),
            const Divider(color: Colors.white12, height: 1),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                itemCount: streams.length,
                itemBuilder: (ctx, index) {
                  final stream = streams[index];
                  final available = stream.isAvailable;
                  return ListTile(
                    leading: streamQualityBadge(stream.quality),
                    title: Text(
                      stream.title,
                      style: TextStyle(
                        color: available ? Colors.white : Colors.white38,
                        fontSize: 13,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      [
                        stream.providerName,
                        if (stream.seeds != null) '👤 ${stream.seeds}',
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
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (available)
                          IconButton(
                            icon: const Icon(
                              Icons.download_rounded,
                              color: Colors.white54,
                              size: 24,
                            ),
                            tooltip: 'Download via browser',
                            onPressed: () {
                              Navigator.pop(ctx);
                              onDownload(stream);
                            },
                          ),
                        IconButton(
                          icon: Icon(
                            available
                                ? Icons.play_circle_fill
                                : Icons.lock_outline,
                            color: available
                                ? (stream.isCached
                                    ? const Color(0xFF6C5CE7)
                                    : const Color(0xFF6C5CE7)
                                        .withValues(alpha: 0.6))
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
                              onPlay(stream);
                            } else {
                              showUnavailableSourceDialog(context, stream);
                            }
                          },
                        ),
                      ],
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      if (available) {
                        onPlay(stream);
                      } else {
                        showUnavailableSourceDialog(context, stream);
                      }
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Una fuente no se puede reproducir: se explica el motivo en vez de fallar.
void showUnavailableSourceDialog(BuildContext context, StreamSource stream) {
  final reason = stream.unavailableReason ?? kDebridRequiredReason;
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1A1A2E),
      title: const Text('Source unavailable'),
      content: Text(
        '$reason.\n\nEnable a debrid service in Settings → Debrid Services, '
        'or pick another source.',
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

/// URL reproducible de una fuente: directa tal cual, torrent resuelto por el
/// debrid habilitado. Lanza [SourceUnavailableException] cuando no hay salida.
Future<String?> resolveSourceUrl(
  ShowsRepository repo,
  StreamSource stream, {
  void Function(String label, int progress)? onProgress,
}) async {
  if (stream.isDirect) return stream.url;
  if (!stream.isAvailable) {
    throw SourceUnavailableException(
      stream.unavailableReason ?? kDebridRequiredReason,
    );
  }
  final magnet = stream.magnetUrl;
  if (magnet == null || magnet.isEmpty) return null;
  final resolved = await repo.resolveMagnet(
    magnet,
    onProgress: onProgress == null
        ? null
        : (status, progress) =>
            onProgress(friendlyDebridStatus(status), progress),
  );
  return resolved?.url;
}

/// Traduce el estado crudo del servicio debrid a una etiqueta corta.
String friendlyDebridStatus(String status) {
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

class SourceUnavailableException implements Exception {
  final String message;

  const SourceUnavailableException(this.message);

  @override
  String toString() => message;
}

Widget streamQualityBadge(String? quality) {
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
      style: TextStyle(
        color: color,
        fontSize: 12,
        fontWeight: FontWeight.bold,
      ),
    ),
  );
}

class _FailureNotice extends StatelessWidget {
  const _FailureNotice({required this.sheetContext, required this.failures});

  final BuildContext sheetContext;
  final List<StreamProviderFailure> failures;

  @override
  Widget build(BuildContext context) {
    final summary =
        failures.map((f) => '${f.providerName}: ${f.reason}').join('\n');
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
}

class _UnavailableNotice extends StatelessWidget {
  const _UnavailableNotice({
    required this.sheetContext,
    required this.streams,
  });

  final BuildContext sheetContext;
  final List<StreamSource> streams;

  @override
  Widget build(BuildContext context) {
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
                  ? 'None of these sources can play without debrid. '
                      'Enable a service to use them.'
                  : '$unavailable of ${streams.length} sources need a debrid '
                      'service.',
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
}
