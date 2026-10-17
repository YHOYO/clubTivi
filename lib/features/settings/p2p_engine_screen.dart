import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/services/p2p/p2p_providers.dart';
import '../../data/services/p2p/p2p_settings.dart';
import '../../data/services/p2p/rqbit_binary.dart';
import '../../data/services/p2p/rqbit_models.dart';
import '../../data/services/p2p/rqbit_release.dart';

/// Ajustes del motor P2P: dónde está el binario, dónde descarga, con qué
/// puerto y límites, y qué torrents hay en la sesión (con su estado actual).
///
/// Guardar recrea el motor: los cambios se aplican matando el proceso anterior,
/// por eso el botón lo avisa. «Parar» es reversible (el siguiente Play arranca)
/// y «vaciar sesión» olvida los torrents y borra el estado, sin tocar lo ya
/// descargado.
class P2pEngineScreen extends ConsumerStatefulWidget {
  /// Con Duration.zero no se refresca sola (los tests usan esto).
  final Duration refreshInterval;

  const P2pEngineScreen({
    super.key,
    this.refreshInterval = const Duration(seconds: 3),
  });

  @override
  ConsumerState<P2pEngineScreen> createState() => _P2pEngineScreenState();
}

class _P2pEngineScreenState extends ConsumerState<P2pEngineScreen> {
  final _portController = TextEditingController();
  final _downloadLimitController = TextEditingController();
  final _uploadLimitController = TextEditingController();

  Timer? _timer;
  List<RqbitTorrentDetails> _torrents = const [];
  bool _refreshing = false;
  bool _initialized = false;
  String? _portError;

  @override
  void initState() {
    super.initState();
    if (widget.refreshInterval > Duration.zero) {
      _timer = Timer.periodic(widget.refreshInterval, (_) => _refreshTorrents());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final notifier = ref.read(p2pSettingsProvider.notifier);
      await notifier.load();
      if (!mounted) return;
      _syncControllers(ref.read(p2pSettingsProvider));
      await _refreshTorrents();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _portController.dispose();
    _downloadLimitController.dispose();
    _uploadLimitController.dispose();
    super.dispose();
  }

  void _syncControllers(P2pSettings settings) {
    _portController.text = settings.port == null ? '' : '${settings.port}';
    _downloadLimitController.text =
        settings.downloadLimitKbps > 0 ? '${settings.downloadLimitKbps}' : '';
    _uploadLimitController.text =
        settings.uploadLimitKbps > 0 ? '${settings.uploadLimitKbps}' : '';
    setState(() => _initialized = true);
  }

  Future<void> _refreshTorrents() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final engine = await ref.read(rqbitEngineProvider.future);
      final torrents = await engine.listTorrents();
      if (mounted) setState(() => _torrents = torrents);
    } catch (error) {
      debugPrint('[P2P] Could not list torrents: $error');
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _save() async {
    final portText = _portController.text.trim();
    final port = portText.isEmpty ? null : int.tryParse(portText);
    if (portText.isNotEmpty &&
        (port == null || port < kMinP2pPort || port > kMaxP2pPort)) {
      setState(
        () => _portError = 'Use a port between $kMinP2pPort and $kMaxP2pPort',
      );
      return;
    }
    setState(() => _portError = null);

    final current = ref.read(p2pSettingsProvider);
    await ref.read(p2pSettingsProvider.notifier).save(
          current.copyWith(
            port: port,
            downloadLimitKbps:
                int.tryParse(_downloadLimitController.text.trim()) ?? 0,
            uploadLimitKbps:
                int.tryParse(_uploadLimitController.text.trim()) ?? 0,
          ),
        );
    if (!mounted) return;
    _snack('Saved — the engine restarts on the next P2P play');
  }

  Future<void> _chooseFolder() async {
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose where P2P downloads are saved',
    );
    if (result == null) return;
    await ref.read(p2pSettingsProvider.notifier).setDownloadDirectory(result);
    if (!mounted) return;
    _snack('Downloads folder updated');
  }

  Future<void> _useDefaultFolder() async {
    await ref.read(p2pSettingsProvider.notifier).setDownloadDirectory(null);
    if (!mounted) return;
    _snack('Back to the default downloads folder');
  }

  Future<void> _removeTorrent(
    RqbitTorrentDetails torrent, {
    required bool deleteFiles,
  }) async {
    final id = torrent.id;
    if (id == null) return;
    if (deleteFiles) {
      final confirmed = await _confirm(
        title: 'Delete torrent and files?',
        message: 'The downloaded files of “${torrent.name}” will be deleted '
            'from disk. This cannot be undone.',
        confirmLabel: 'Delete',
      );
      if (confirmed != true) return;
    }
    try {
      final engine = await ref.read(rqbitEngineProvider.future);
      await engine.removeTorrent('$id', deleteFiles: deleteFiles);
      if (!mounted) return;
      _snack(deleteFiles ? 'Torrent and files deleted' : 'Torrent removed');
      await _refreshTorrents();
    } catch (error) {
      if (!mounted) return;
      _snack('Could not remove the torrent: $error');
    }
  }

  Future<void> _stopEngine() async {
    try {
      final engine = await ref.read(rqbitEngineProvider.future);
      await engine.stop();
      if (!mounted) return;
      _snack('Engine stopped — it starts again on the next P2P play');
      await _refreshTorrents();
    } catch (error) {
      if (!mounted) return;
      _snack('Could not stop the engine: $error');
    }
  }

  Future<void> _clearSession() async {
    final confirmed = await _confirm(
      title: 'Clear the P2P session?',
      message: 'Every torrent is removed from the session and its saved state '
          'is deleted. Files already downloaded stay in the downloads folder.',
      confirmLabel: 'Clear',
    );
    if (confirmed != true) return;
    try {
      final engine = await ref.read(rqbitEngineProvider.future);
      await engine.clearSession();
      if (!mounted) return;
      _snack('Session cleared — downloaded files were kept');
      await _refreshTorrents();
    } catch (error) {
      if (!mounted) return;
      _snack('Could not clear the session: $error');
    }
  }

  Future<bool?> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: Text(title, style: const TextStyle(color: Colors.white)),
        content: Text(
          message,
          style: const TextStyle(color: Colors.white70, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFF1A1A2E),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(p2pSettingsProvider);
    final engine = ref.watch(rqbitEngineProvider).valueOrNull;
    final running = engine?.isRunning ?? false;
    final location = ref.watch(p2pBinaryLocationProvider);
    final defaultFolder = ref.watch(p2pDefaultDownloadDirectoryProvider);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          Future.microtask(() {
            if (context.mounted) Navigator.pop(context);
          });
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: const Color(0xFF0A0A1A),
          appBar: AppBar(
            backgroundColor: const Color(0xFF12122A),
            title: const Text('P2P Engine'),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.pop(context),
            ),
            actions: [
              IconButton(
                key: const ValueKey('p2p-refresh'),
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh torrents',
                onPressed: _refreshTorrents,
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              const _SectionHeader(title: 'Status'),
              _statusCard(location, running, engine?.baseUri),
              const _SectionHeader(title: 'Downloads'),
              ListTile(
                dense: true,
                leading: const Icon(Icons.folder_rounded, color: Colors.white54),
                title: Text(
                  settings.downloadDirectory ??
                      (defaultFolder.valueOrNull ?? 'Downloads/clubTivi'),
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
                subtitle: Text(
                  settings.hasCustomDownloadDirectory
                      ? 'Custom folder'
                      : 'Default folder',
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      key: const ValueKey('p2p-choose-folder'),
                      onPressed: _chooseFolder,
                      child: const Text('Choose'),
                    ),
                    if (settings.hasCustomDownloadDirectory)
                      TextButton(
                        key: const ValueKey('p2p-use-default-folder'),
                        onPressed: _useDefaultFolder,
                        child: const Text('Default'),
                      ),
                  ],
                ),
              ),
              const _SectionHeader(title: 'Network'),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Column(
                  children: [
                    TextField(
                      key: const ValueKey('p2p-port'),
                      controller: _portController,
                      keyboardType: TextInputType.number,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Port',
                        helperText: 'Empty = a free port is chosen automatically',
                        errorText: _portError,
                        labelStyle: const TextStyle(color: Colors.white54),
                        helperStyle:
                            const TextStyle(color: Colors.white38, fontSize: 11),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            key: const ValueKey('p2p-download-limit'),
                            controller: _downloadLimitController,
                            keyboardType: TextInputType.number,
                            style: const TextStyle(color: Colors.white),
                            decoration: const InputDecoration(
                              labelText: 'Download limit',
                              suffixText: 'KB/s',
                              labelStyle: TextStyle(color: Colors.white54),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            key: const ValueKey('p2p-upload-limit'),
                            controller: _uploadLimitController,
                            keyboardType: TextInputType.number,
                            style: const TextStyle(color: Colors.white),
                            decoration: const InputDecoration(
                              labelText: 'Upload limit',
                              suffixText: 'KB/s',
                              labelStyle: TextStyle(color: Colors.white54),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Leave a limit empty (or 0) for unlimited speed. '
                          'Changes restart the engine.',
                          style: TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(
                        key: const ValueKey('p2p-save'),
                        onPressed: _initialized ? _save : null,
                        child: const Text('Save'),
                      ),
                    ),
                  ],
                ),
              ),
              const _SectionHeader(title: 'Session'),
              _sessionActions(running),
              if (_torrents.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Text(
                    running
                        ? 'No torrents in the session right now.'
                        : 'The engine is not running. It starts when you play a '
                            'P2P source.',
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                )
              else
                for (final torrent in _torrents) _torrentRow(torrent),
              const _SectionHeader(title: 'Engine'),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                child: Text(
                  'rqbit $rqbitVersion · Apache-2.0 · github.com/ikatson/rqbit',
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusCard(
    AsyncValue<RqbitBinaryLocation?> location,
    bool running,
    Uri? baseUri,
  ) {
    final binaryText = switch (location) {
      AsyncData(value: final value) when value == null =>
        'Not bundled — it downloads on the first P2P play',
      AsyncData(value: final value) => switch (value!.source) {
          RqbitBinarySource.bundled => 'Bundled with the app',
          RqbitBinarySource.cache => 'Downloaded to the local cache',
          RqbitBinarySource.downloaded => 'Just downloaded, verified',
          RqbitBinarySource.override => 'Custom binary (development override)',
        },
      AsyncError() => 'Could not check the engine',
      _ => 'Checking…',
    };
    final path = location.valueOrNull?.path;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF12122A),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  running ? Icons.play_circle_fill : Icons.pause_circle_outline,
                  color: running ? Colors.greenAccent : Colors.white38,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    running
                        ? 'Running on 127.0.0.1:${baseUri?.port ?? '—'}'
                        : 'Not running',
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Engine: $binaryText',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            if (path != null)
              Text(
                path,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
          ],
        ),
      ),
    );
  }

  Widget _sessionActions(bool running) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (running)
            OutlinedButton.icon(
              key: const ValueKey('p2p-stop'),
              onPressed: _stopEngine,
              icon: const Icon(Icons.stop_circle_outlined, size: 18),
              label: const Text('Stop engine'),
            ),
          OutlinedButton.icon(
            key: const ValueKey('p2p-clear-session'),
            onPressed: _clearSession,
            icon: const Icon(Icons.delete_sweep_outlined, size: 18),
            label: const Text('Clear session'),
          ),
        ],
      ),
    );
  }

  Widget _torrentRow(RqbitTorrentDetails torrent) {
    final stats = torrent.stats;
    final progress = stats?.progress;
    final percent = progress == null ? null : (progress * 100).round();
    final subtitleParts = [
      stats?.state ?? 'unknown',
      if (percent != null) '$percent%',
      if (torrent.totalBytes > 0) _formatBytes(torrent.totalBytes),
    ];
    return ListTile(
      key: ValueKey('p2p-torrent-${torrent.id}'),
      dense: true,
      title: Text(
        torrent.name.isEmpty ? 'Torrent ${torrent.id}' : torrent.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white, fontSize: 13),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            subtitleParts.join(' · '),
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
          if (progress != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 4,
                backgroundColor: Colors.white12,
                color: const Color(0xFF6C5CE7),
              ),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: ValueKey('p2p-torrent-delete-${torrent.id}'),
            icon: const Icon(Icons.delete_forever_outlined, size: 20),
            color: Colors.redAccent,
            tooltip: 'Delete torrent and files',
            onPressed: () => _removeTorrent(torrent, deleteFiles: true),
          ),
          IconButton(
            key: ValueKey('p2p-torrent-remove-${torrent.id}'),
            icon: const Icon(Icons.remove_circle_outline, size: 20),
            color: Colors.white54,
            tooltip: 'Remove from session (keeps files)',
            onPressed: () => _removeTorrent(torrent, deleteFiles: false),
          ),
        ],
      ),
    );
  }

  String _formatBytes(int bytes) {
    final gb = bytes / (1024 * 1024 * 1024);
    if (gb >= 1) return '${gb.toStringAsFixed(1)} GB';
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(0)} MB';
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          color: Colors.white38,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}
