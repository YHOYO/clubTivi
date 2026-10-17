import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models/stremio_addon.dart';
import '../../data/services/stremio_addon_settings.dart';
import '../../data/services/stremio_recommended_addons.dart';
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
  String? _recommendedError;
  String? _installingRecommended;
  String? _refreshingUrl;

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

  /// Instala uno de los addons recomendados con el mismo camino que una URL
  /// pegada a mano: validar el manifest, guardarlo y avisar si falla.
  Future<void> _installRecommended(RecommendedAddon recommendation) async {
    if (_installingRecommended != null) return;
    setState(() {
      _installingRecommended = recommendation.url;
      _recommendedError = null;
    });
    try {
      final client = ref.read(stremioAddonClientProvider);
      final manifest = await client.fetchManifest(recommendation.url);
      if (!mounted) return;
      await ref
          .read(stremioAddonSettingsProvider.notifier)
          .save(manifest, recommendation.url);
      if (!mounted) return;
      _snackbar(manifest.configurationRequired
          ? '${manifest.name} añadido — configúralo para ver sus catálogos'
          : '${manifest.name} añadido');
    } on StremioAddonException catch (e) {
      if (!mounted) return;
      setState(() => _recommendedError = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _recommendedError = 'No se pudo validar el addon: $e');
    } finally {
      if (mounted) setState(() => _installingRecommended = null);
    }
  }

  /// Vuelve a leer el manifest. Es lo que trae los catálogos de un addon que
  /// se acaba de configurar en el navegador (`Anime Catalogs` empieza sin
  /// ninguno y no se puede rellenar de otra forma).
  Future<void> _refreshAddon(InstalledAddon addon) async {
    if (_refreshingUrl != null) return;
    setState(() => _refreshingUrl = addon.url);
    try {
      final manifest = await ref
          .read(stremioAddonClientProvider)
          .fetchManifest(addon.url);
      if (!mounted) return;
      await ref
          .read(stremioAddonSettingsProvider.notifier)
          .save(manifest, addon.url);
      if (!mounted) return;
      _snackbar(manifest.catalogs.isEmpty
          ? '${manifest.name} actualizado — aún no publica catálogos'
          : '${manifest.name}: ${manifest.catalogs.length} catálogos');
    } on StremioAddonException catch (e) {
      if (mounted) _snackbar(e.message);
    } catch (e) {
      if (mounted) _snackbar('No se pudo actualizar el addon: $e');
    } finally {
      if (mounted) setState(() => _refreshingUrl = null);
    }
  }

  /// Abre la página de configuración del addon (el protocolo la expone en
  /// `/configure`). Sin ella, un addon como Anime Catalogs no trae catálogos.
  Future<void> _openConfigure(InstalledAddon addon) async {
    final uri = Uri.parse(configureUrlFor(addon.url));
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (mounted) _snackbar('No se pudo abrir ${uri.toString()}');
    }
  }

  Future<void> _openCommunityList() async {
    final uri = Uri.parse(communityAddonsListUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (mounted) _snackbar('No se pudo abrir la lista de addons');
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
                'Instala un addon de Stremio para sumar sus streams y sus '
                'catálogos (anime, películas en español…).',
                style: TextStyle(color: Colors.white54, fontSize: 13, height: 1.3),
              ),
              const SizedBox(height: 16),
              _buildStatusBanner(settings),
              const SizedBox(height: 8),
              _buildInstallCard(),
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
                  onConfigure: addons[i].configurable ||
                          addons[i].configurationRequired
                      ? () => _openConfigure(addons[i])
                      : null,
                  onRefresh: () => _refreshAddon(addons[i]),
                  refreshing: _refreshingUrl == addons[i].url,
                ),
              const SizedBox(height: 16),
              _buildRecommended(settings),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRecommended(StremioAddonSettings settings) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF12122A),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.local_fire_department_rounded,
                  color: Color(0xFF6C5CE7), size: 18),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Recommended addons',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton(
                onPressed: _openCommunityList,
                child: const Text('More addons'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (final recommendation in recommendedStremioAddons)
            _RecommendedAddonTile(
              recommendation: recommendation,
              installed: settings.byUrl(recommendation.url),
              installing: _installingRecommended == recommendation.url,
              busy: _installingRecommended != null,
              onInstall: () => _installRecommended(recommendation),
              onConfigure: (addon) => _openConfigure(addon),
            ),
          if (_recommendedError != null) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error_outline,
                    color: Colors.redAccent, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _recommendedError!,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
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
    this.onConfigure,
    this.onRefresh,
    this.refreshing = false,
  });

  final InstalledAddon addon;
  final int position;
  final bool canMoveUp;
  final bool canMoveDown;
  final ValueChanged<bool> onToggle;
  final VoidCallback onUp;
  final VoidCallback onDown;
  final VoidCallback onRemove;
  final VoidCallback? onConfigure;
  final VoidCallback? onRefresh;
  final bool refreshing;

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
                if (addon.hasCatalogs)
                  Text(
                    '${addon.browsableCatalogs.length} catalogs',
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 11,
                    ),
                  ),
                if (addon.configurationRequired)
                  const Text(
                    'Needs configuration',
                    style: TextStyle(
                      color: Colors.orangeAccent,
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ),
          if (onConfigure != null)
            IconButton(
              icon: const Icon(Icons.tune, size: 20, color: Colors.white70),
              tooltip: 'Configure addon',
              onPressed: onConfigure,
            ),
          IconButton(
            icon: refreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(
                    Icons.refresh,
                    size: 20,
                    color: Colors.white70,
                  ),
            tooltip: 'Refresh manifest',
            onPressed: refreshing ? null : onRefresh,
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

/// Un recomendado: instalar con un clic o, si ya está, configurarlo.
class _RecommendedAddonTile extends StatelessWidget {
  const _RecommendedAddonTile({
    required this.recommendation,
    required this.installed,
    required this.installing,
    required this.busy,
    required this.onInstall,
    required this.onConfigure,
  });

  final RecommendedAddon recommendation;
  final InstalledAddon? installed;
  final bool installing;
  final bool busy;
  final VoidCallback onInstall;
  final void Function(InstalledAddon addon) onConfigure;

  @override
  Widget build(BuildContext context) {
    final addon = installed;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        recommendation.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    for (final tag in recommendation.tags)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF6C5CE7)
                                .withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            tag,
                            style: const TextStyle(
                              color: Color(0xFFB9AEFF),
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  recommendation.description,
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 11,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (installing)
            const Padding(
              padding: EdgeInsets.all(10),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (addon != null)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.check_circle,
                    color: Colors.green, size: 18),
                if (addon.configurable || addon.configurationRequired)
                  TextButton(
                    onPressed: () => onConfigure(addon),
                    child: const Text('Configure'),
                  ),
              ],
            )
          else
            FilledButton.tonal(
              onPressed: busy ? null : onInstall,
              child: const Text('Install'),
            ),
        ],
      ),
    );
  }
}
