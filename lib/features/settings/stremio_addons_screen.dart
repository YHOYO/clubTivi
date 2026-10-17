import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models/stremio_addon.dart';
import '../../data/services/stremio_addon_settings.dart';
import '../shows/shows_providers.dart';

/// Instalación y gestión de addons Stremio.
///
/// La URL se valida contra su `manifest.json` antes de aceptarla: si no es un
/// addon, el usuario ve el motivo y no queda nada guardado.
class StremioAddonsScreen extends ConsumerStatefulWidget {
  const StremioAddonsScreen({super.key});

  @override
  ConsumerState<StremioAddonsScreen> createState() =>
      _StremioAddonsScreenState();
}

class _StremioAddonsScreenState extends ConsumerState<StremioAddonsScreen> {
  final _urlController = TextEditingController();
  bool _validating = false;
  String? _error;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _install() async {
    final input = _urlController.text.trim();
    if (input.isEmpty) {
      setState(() => _error = 'Pega la URL del addon.');
      return;
    }

    setState(() {
      _validating = true;
      _error = null;
    });

    final client = ref.read(stremioAddonClientProvider);
    try {
      final manifest = await client.fetchManifest(input);
      if (!mounted) return;
      await ref
          .read(stremioAddonSettingsProvider.notifier)
          .save(manifest, input);
      if (!mounted) return;
      _urlController.clear();
      setState(() => _validating = false);
      _snackbar('${manifest.name} añadido');
    } on StremioAddonException catch (e) {
      if (!mounted) return;
      setState(() {
        _validating = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _validating = false;
        _error = 'No se pudo validar el addon: $e';
      });
    }
  }

  Future<void> _confirmRemove(InstalledAddon addon) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF12122A),
        title: const Text('Quitar addon'),
        content: Text('¿Quitar "${addon.name}"? Sus streams dejarán de aparecer.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Quitar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref
        .read(stremioAddonSettingsProvider.notifier)
        .remove(addon.url);
  }

  void _snackbar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(stremioAddonSettingsProvider);
    final addons = settings.addons;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          Future.microtask(() {
            if (!context.mounted) return;
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            } else {
              context.go('/settings');
            }
          });
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: const Color(0xFF0A0A1A),
          appBar: AppBar(
            backgroundColor: const Color(0xFF12122A),
            title: const Text('Stremio Addons'),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              const Text(
                'Pega la URL de un addon de Stremio y sus streams aparecerán '
                'junto a los de Torrentio, ordenados por tus preferencias.',
                style: TextStyle(color: Colors.white54, fontSize: 13, height: 1.3),
              ),
              const SizedBox(height: 16),
              _buildInstallCard(),
              const SizedBox(height: 16),
              _buildStatusBanner(settings),
              const SizedBox(height: 8),
              for (var i = 0; i < addons.length; i++)
                _AddonCard(
                  addon: addons[i],
                  position: i + 1,
                  canMoveUp: i > 0,
                  canMoveDown: i < addons.length - 1,
                  onToggle: (value) => ref
                      .read(stremioAddonSettingsProvider.notifier)
                      .setEnabled(addons[i].url, value),
                  onUp: () => ref
                      .read(stremioAddonSettingsProvider.notifier)
                      .move(i, i - 1),
                  onDown: () => ref
                      .read(stremioAddonSettingsProvider.notifier)
                      .move(i, i + 1),
                  onRemove: () => _confirmRemove(addons[i]),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInstallCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF12122A),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _urlController,
            enabled: !_validating,
            onSubmitted: (_) => _install(),
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: const InputDecoration(
              labelText: 'Addon URL',
              hintText: 'https://torrentio.strem.fun',
              prefixIcon: Icon(Icons.link_rounded, color: Colors.white38),
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error_outline, color: Colors.redAccent, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _validating ? null : _install,
              icon: _validating
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add_link_rounded),
              label: Text(_validating ? 'Validando manifest…' : 'Install addon'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBanner(StremioAddonSettings settings) {
    final String text;
    final Color color;
    if (!settings.hasAddons) {
      text = 'No addons installed — only Torrentio is queried';
      color = Colors.white38;
    } else if (settings.enabledCount == 0) {
      text = '${settings.count} installed • all disabled';
      color = Colors.orangeAccent;
    } else {
      text = '${settings.enabledCount} of ${settings.count} enabled';
      color = Colors.green;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.extension_rounded, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(color: color, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

class _AddonCard extends StatelessWidget {
  const _AddonCard({
    required this.addon,
    required this.position,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onToggle,
    required this.onUp,
    required this.onDown,
    required this.onRemove,
  });

  final InstalledAddon addon;
  final int position;
  final bool canMoveUp;
  final bool canMoveDown;
  final ValueChanged<bool> onToggle;
  final VoidCallback onUp;
  final VoidCallback onDown;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final enabled = addon.enabled;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: const Color(0xFF12122A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: enabled
              ? const Color(0xFF6C5CE7).withValues(alpha: 0.5)
              : Colors.white12,
        ),
      ),
      child: Row(
        children: [
          Text(
            '#$position',
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  addon.name,
                  style: TextStyle(
                    color: enabled ? Colors.white : Colors.white54,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                Text(
                  addon.version == null
                      ? addon.url
                      : '${addon.url} • v${addon.version}',
                  style: TextStyle(
                    color: enabled ? Colors.green : Colors.white38,
                    fontSize: 11,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_up, size: 20),
            color: canMoveUp ? Colors.white70 : Colors.white12,
            tooltip: 'Subir prioridad',
            onPressed: canMoveUp ? onUp : null,
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down, size: 20),
            color: canMoveDown ? Colors.white70 : Colors.white12,
            tooltip: 'Bajar prioridad',
            onPressed: canMoveDown ? onDown : null,
          ),
          Switch(
            value: enabled,
            onChanged: onToggle,
            activeThumbColor: const Color(0xFF6C5CE7),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20, color: Colors.redAccent),
            tooltip: 'Quitar',
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}
