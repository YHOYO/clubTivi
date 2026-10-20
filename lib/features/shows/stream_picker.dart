import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models/language_preferences.dart';
import '../../data/models/stream_search_result.dart';
import '../../data/models/stream_source.dart';
import '../../data/repositories/shows_repository.dart';
import '../../data/services/debrid_settings.dart';
import '../../data/services/language_preferences_store.dart';
import '../../data/services/stream_ranker.dart';

/// Selector de fuentes compartido por la ficha de Trakt/TMDB y la de un
/// catálogo de addon: mismas etiquetas, mismos avisos y mismas salidas.
///
/// Recibe la lista completa ya rankeada por el provider. El filtro «Solo
/// español» y el orden «Español primero» se aplican aquí, sobre todas las
/// fuentes, para no dejar fuera una fuente española que quedó en el puesto 11.
Future<void> showStreamPicker(
  BuildContext context, {
  required StreamSearchResult result,
  required String title,
  required Future<void> Function(StreamSource stream) onPlay,
  required Future<void> Function(StreamSource stream) onDownload,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF1A1A2E),
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetContext) => Consumer(
      builder: (_, ref, child) => _StreamPickerSheet(
        parentContext: context,
        result: result,
        title: title,
        preferences: ref.watch(languagePreferencesProvider),
        onPlay: onPlay,
        onDownload: onDownload,
      ),
    ),
  );
}

class _StreamPickerSheet extends StatefulWidget {
  const _StreamPickerSheet({
    required this.parentContext,
    required this.result,
    required this.title,
    required this.preferences,
    required this.onPlay,
    required this.onDownload,
  });

  /// Contexto de la pantalla que abrió el selector. Se usa para los diálogos y
  /// la navegación después de cerrar la hoja; usar el contexto de la hoja
  /// después de `Navigator.pop` deja un contexto desactivado.
  final BuildContext parentContext;
  final StreamSearchResult result;
  final String title;
  final LanguagePreferences preferences;
  final Future<void> Function(StreamSource stream) onPlay;
  final Future<void> Function(StreamSource stream) onDownload;

  @override
  State<_StreamPickerSheet> createState() => _StreamPickerSheetState();
}

class _StreamPickerSheetState extends State<_StreamPickerSheet> {
  bool _spanishOnly = false;
  bool _spanishFirst = false;

  @override
  Widget build(BuildContext context) {
    final streams = widget.result.sources;
    final selected = selectStreams(
      streams,
      preferences: widget.preferences,
      spanishOnly: _spanishOnly,
      spanishFirst: _spanishFirst,
    );
    final count = _spanishOnly && selected.length != streams.length
        ? '${selected.length} of ${streams.length} sources'
        : '${selected.length} sources';

    return DraggableScrollableSheet(
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
                '${widget.title} • $count',
                style: const TextStyle(color: Colors.white54, fontSize: 13),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  _PickerChip(
                    label: 'Solo español',
                    selected: _spanishOnly,
                    onSelected: (value) => setState(() => _spanishOnly = value),
                  ),
                  _PickerChip(
                    label: 'Español primero',
                    selected: _spanishFirst,
                    onSelected: (value) =>
                        setState(() => _spanishFirst = value),
                  ),
                ],
              ),
            ),
            if (selected.any((s) => !s.isAvailable))
              _UnavailableNotice(
                streams: selected,
                onOpenSettings: () {
                  Navigator.pop(context);
                  widget.parentContext.push('/debrid-services');
                },
              ),
            if (widget.result.hasFailures)
              _FailureNotice(
                failures: widget.result.failures,
                onOpenAddons: () {
                  Navigator.pop(context);
                  widget.parentContext.push('/stremio-addons');
                },
              ),
            const SizedBox(height: 8),
            const Divider(color: Colors.white12, height: 1),
            Expanded(
              child: selected.isEmpty
                  ? _EmptySelection(
                      spanishOnly: _spanishOnly,
                      onShowAll: () => setState(() => _spanishOnly = false),
                    )
                  : ListView.builder(
                      controller: scrollController,
                      itemCount: selected.length,
                      itemBuilder: (ctx, index) => _StreamTile(
                        stream: selected[index],
                        onPlay: () {
                          Navigator.pop(context);
                          widget.onPlay(selected[index]);
                        },
                        onDownload: () {
                          Navigator.pop(context);
                          widget.onDownload(selected[index]);
                        },
                        onUnavailable: () {
                          Navigator.pop(context);
                          showUnavailableSourceDialog(
                            widget.parentContext,
                            selected[index],
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PickerChip extends StatelessWidget {
  const _PickerChip({
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final ValueChanged<bool> onSelected;

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      label: Text(label),
      selected: selected,
      onSelected: onSelected,
      checkmarkColor: Colors.white,
      backgroundColor: const Color(0xFF1A1A2E),
      selectedColor: const Color(0xFF6C5CE7).withValues(alpha: 0.45),
      side: const BorderSide(color: Colors.white12),
      labelStyle: TextStyle(
        color: selected ? Colors.white : Colors.white70,
        fontSize: 12,
      ),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _StreamTile extends StatelessWidget {
  const _StreamTile({
    required this.stream,
    required this.onPlay,
    required this.onDownload,
    required this.onUnavailable,
  });

  final StreamSource stream;
  final VoidCallback onPlay;
  final VoidCallback onDownload;
  final VoidCallback onUnavailable;

  @override
  Widget build(BuildContext context) {
    final available = stream.isAvailable;
    final spanish = isSpanishSource(stream);
    return ListTile(
      key: ValueKey('stream-row-${stream.id}'),
      isThreeLine: true,
      leading: streamQualityBadge(stream.quality),
      title: Text(
        stream.displayName,
        style: TextStyle(
          color: available ? Colors.white : Colors.white38,
          fontSize: 13,
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _languageLine(stream),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: spanish
                  ? Colors.greenAccent.withValues(alpha: 0.9)
                  : Colors.white54,
              fontSize: 12,
              fontWeight: spanish ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            _metadataLine(stream),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
          if (!available)
            Text(
              stream.unavailableReason ?? kDebridRequiredReason,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.orangeAccent.withValues(alpha: 0.85),
                fontSize: 11,
              ),
            ),
        ],
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
              onPressed: onDownload,
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
                : stream.unavailableReason ?? kDebridRequiredReason,
            onPressed: available ? onPlay : onUnavailable,
          ),
        ],
      ),
      onTap: available ? onPlay : onUnavailable,
    );
  }
}

class _EmptySelection extends StatelessWidget {
  const _EmptySelection({required this.spanishOnly, required this.onShowAll});

  final bool spanishOnly;
  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.translate, size: 40, color: Colors.white24),
          const SizedBox(height: 10),
          Text(
            spanishOnly ? 'No Spanish sources' : 'No sources',
            style: const TextStyle(color: Colors.white54, fontSize: 14),
          ),
          if (spanishOnly)
            TextButton(onPressed: onShowAll, child: const Text('Show all')),
        ],
      ),
    );
  }
}

/// Línea de idiomas: audio y subtítulos se ven antes que cualquier detalle
/// técnico, y el español se resalta en la fila.
String _languageLine(StreamSource stream) {
  final audio = _languageNames(stream.audioLanguages);
  final subtitles = _languageNames(stream.subtitleLanguages);
  final audioLabel = audio.isNotEmpty
      ? (stream.audioMode == null ? audio : '$audio (${_audioMode(stream)})')
      : (stream.audioMode == null ? 'sin datos' : _audioMode(stream));
  final subtitlesLabel = subtitles.isNotEmpty
      ? subtitles
      : (stream.hasSubtitles ? 'sí' : '—');
  return 'Audio: $audioLabel · Subs: $subtitlesLabel';
}

String _audioMode(StreamSource stream) =>
    stream.audioMode == 'MULTI' ? 'Multi' : 'Dual';

String _languageNames(Set<String> codes) {
  final sorted = codes.toList()
    ..sort((a, b) => _languageRank(a).compareTo(_languageRank(b)));
  return sorted.map(languageLabel).join(', ');
}

int _languageRank(String code) {
  switch (normalizeLanguageCode(code)) {
    case kLanguageSpanishLatin:
      return 0;
    case kLanguageSpanish:
      return 1;
    case kLanguageEnglish:
      return 2;
    default:
      return 3;
  }
}

String _metadataLine(StreamSource stream) {
  final size = stream.filesizeDisplay;
  final parts = <String>[
    // Un enlace directo sin tamaño no debe empezar la línea con «size ?»:
    // el hueco se omite y la fila arranca con la calidad y el addon.
    if (size.isNotEmpty) size,
    if (stream.qualityDetail != null && stream.qualityDetail!.isNotEmpty)
      stream.qualityDetail!,
    stream.providerName,
    if (stream.seeds != null) '👤 ${stream.seeds}',
    if (stream.isCached) stream.cachedBy == null ? '⚡' : '⚡ ${stream.cachedBy}',
  ];
  return parts.join(' · ');
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
      style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold),
    ),
  );
}

class _FailureNotice extends StatelessWidget {
  const _FailureNotice({required this.failures, required this.onOpenAddons});

  final List<StreamProviderFailure> failures;
  final VoidCallback onOpenAddons;

  @override
  Widget build(BuildContext context) {
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
          const Icon(
            Icons.cloud_off_rounded,
            color: Colors.redAccent,
            size: 18,
          ),
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
          TextButton(onPressed: onOpenAddons, child: const Text('Addons')),
        ],
      ),
    );
  }
}

class _UnavailableNotice extends StatelessWidget {
  const _UnavailableNotice({
    required this.streams,
    required this.onOpenSettings,
  });

  final List<StreamSource> streams;
  final VoidCallback onOpenSettings;

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
          TextButton(onPressed: onOpenSettings, child: const Text('Settings')),
        ],
      ),
    );
  }
}
