import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/datasources/remote/debrid_service.dart';
import '../../data/services/debrid_settings.dart';

/// Sub-screen for managing debrid service API tokens, their on/off state and
/// the resolution priority. El orden de la lista es la prioridad: el primer
/// servicio habilitado resuelve. Deshabilitar conserva el token.
class DebridServicesScreen extends ConsumerStatefulWidget {
  const DebridServicesScreen({super.key});

  @override
  ConsumerState<DebridServicesScreen> createState() =>
      _DebridServicesScreenState();
}

class _DebridServicesScreenState extends ConsumerState<DebridServicesScreen> {
  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(debridSettingsProvider);
    final loaded = ref.read(debridSettingsProvider.notifier).isLoaded;
    final configured = settings.services;
    final unconfigured = [
      for (final type in DebridType.values)
        if (!settings.isConfigured(type)) type,
    ];

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          Future.microtask(() {
            if (mounted) Navigator.pop(context);
          });
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: const Color(0xFF0A0A1A),
          appBar: AppBar(
            backgroundColor: const Color(0xFF12122A),
            title: const Text('Debrid Services'),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          body: !loaded
              ? const Center(
                  child: CircularProgressIndicator(color: Color(0xFF6C5CE7)),
                )
              : ListView(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(
                  'The list order is the priority: the first enabled service '
                  'resolves the links. Disabling a service keeps its token and '
                  'lets you turn it back on later.',
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ),
              _buildStatusBanner(settings),
              if (configured.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Text(
                    'No debrid service configured. The app keeps working: '
                    'direct sources play as usual and sources that need debrid '
                    'are shown as unavailable instead of failing.',
                    style: TextStyle(
                      color: Colors.white38,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                )
              else ...[
                const _SectionHeader(title: 'Your services'),
                for (var i = 0; i < configured.length; i++)
                  _DebridServiceCard(
                    key: ValueKey('debrid-card-${configured[i].type.name}'),
                    type: configured[i].type,
                    config: configured[i],
                    position: i,
                    configuredCount: configured.length,
                    onToggle: (enabled) =>
                        _toggle(configured[i].type, enabled),
                    onSave: (token) => _save(configured[i].type, token),
                    onRemove: () => _confirmRemove(configured[i].type),
                    onMove: (delta) => _move(configured[i].type, delta),
                  ),
              ],
              if (unconfigured.isNotEmpty) ...[
                const _SectionHeader(title: 'Add a service'),
                for (final type in unconfigured)
                  _DebridServiceCard(
                    key: ValueKey('debrid-card-${type.name}'),
                    type: type,
                    config: null,
                    position: null,
                    configuredCount: configured.length,
                    onToggle: (_) async {},
                    onSave: (token) => _save(type, token),
                    onRemove: () async {},
                    onMove: (_) async {},
                  ),
              ],
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusBanner(DebridSettings settings) {
    if (settings.configuredCount == 0) return const SizedBox.shrink();

    final enabled = settings.enabledServices;
    final isOff = enabled.isEmpty;
    final color = isOff ? Colors.orangeAccent : Colors.greenAccent;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Container(
        key: const ValueKey('debrid-status-banner'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            Icon(
              isOff ? Icons.pause_circle_outline : Icons.bolt,
              color: color,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                isOff
                    ? 'Debrid off — no service is enabled, so links that need '
                        'debrid are marked unavailable.'
                    : 'Resolving with ${enabled.first.type.displayName}'
                        '${enabled.length > 1 ? ' · ${enabled.length} enabled' : ''}.',
                style: TextStyle(color: color, fontSize: 12, height: 1.35),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save(DebridType type, String token) async {
    await ref.read(debridSettingsProvider.notifier).saveToken(type, token);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${type.displayName} token saved')),
    );
  }

  Future<void> _toggle(DebridType type, bool enabled) async {
    await ref.read(debridSettingsProvider.notifier).setEnabled(type, enabled);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          enabled
              ? '${type.displayName} enabled'
              : '${type.displayName} disabled — token kept',
        ),
      ),
    );
  }

  Future<void> _move(DebridType type, int delta) async {
    final services = ref.read(debridSettingsProvider).services;
    final from = services.indexWhere((c) => c.type == type);
    if (from < 0) return;
    await ref.read(debridSettingsProvider.notifier).move(from, from + delta);
  }

  Future<void> _confirmRemove(DebridType type) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('Remove service?'),
        content: Text(
          'The ${type.displayName} API token will be deleted from this device. '
          'If you only want to stop using it, disable it instead.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await ref.read(debridSettingsProvider.notifier).remove(type);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${type.displayName} token removed')),
    );
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

class _DebridServiceCard extends StatefulWidget {
  final DebridType type;

  /// Null cuando el servicio todavía no tiene token.
  final DebridServiceConfig? config;

  /// Posición dentro de la lista configurada (0 = máxima prioridad).
  final int? position;
  final int configuredCount;

  final Future<void> Function(bool enabled) onToggle;
  final Future<void> Function(String token) onSave;
  final Future<void> Function() onRemove;
  final Future<void> Function(int delta) onMove;

  const _DebridServiceCard({
    super.key,
    required this.type,
    required this.config,
    required this.position,
    required this.configuredCount,
    required this.onToggle,
    required this.onSave,
    required this.onRemove,
    required this.onMove,
  });

  @override
  State<_DebridServiceCard> createState() => _DebridServiceCardState();
}

class _DebridServiceCardState extends State<_DebridServiceCard> {
  late final TextEditingController _controller;
  late bool _expanded;
  bool _verifying = false;
  bool? _verified;
  bool _obscure = true;

  bool get _configured => widget.config != null;
  bool get _enabled => widget.config?.enabled ?? false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.config?.token ?? '');
    _expanded = !_configured;
  }

  @override
  void didUpdateWidget(covariant _DebridServiceCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final token = widget.config?.token;
    if (token != null &&
        token != oldWidget.config?.token &&
        _controller.text != token) {
      _controller.text = token;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final type = widget.type;
    final hasToken = _controller.text.trim().isNotEmpty;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: const Color(0xFF16213E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        children: [
          ListTile(
            leading: Icon(
              Icons.cloud_download_rounded,
              color: !_configured
                  ? Colors.white30
                  : _enabled
                      ? const Color(0xFF6C5CE7)
                      : Colors.white38,
            ),
            title: Row(
              children: [
                Flexible(
                  child: Text(
                    type.displayName,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: !_configured
                          ? Colors.white70
                          : _enabled
                              ? Colors.white
                              : Colors.white54,
                    ),
                  ),
                ),
                if (widget.position != null) ...[
                  const SizedBox(width: 8),
                  _PriorityChip(position: widget.position!),
                ],
              ],
            ),
            subtitle: Text(
              _statusLabel(),
              style: TextStyle(
                fontSize: 12,
                color: !_configured
                    ? Colors.white38
                    : _enabled
                        ? Colors.green
                        : Colors.orangeAccent,
              ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_configured) ...[
                  IconButton(
                    key: ValueKey('debrid-up-${type.name}'),
                    visualDensity: VisualDensity.compact,
                    iconSize: 20,
                    tooltip: 'Move up (higher priority)',
                    icon: const Icon(Icons.arrow_upward),
                    onPressed: widget.position == null || widget.position == 0
                        ? null
                        : () => widget.onMove(-1),
                  ),
                  IconButton(
                    key: ValueKey('debrid-down-${type.name}'),
                    visualDensity: VisualDensity.compact,
                    iconSize: 20,
                    tooltip: 'Move down (lower priority)',
                    icon: const Icon(Icons.arrow_downward),
                    onPressed: widget.position == null ||
                            widget.position! >= widget.configuredCount - 1
                        ? null
                        : () => widget.onMove(1),
                  ),
                  Semantics(
                    label: _enabled
                        ? 'Disable ${type.displayName}'
                        : 'Enable ${type.displayName}',
                    child: Switch(
                      key: ValueKey('debrid-toggle-${type.name}'),
                      value: _enabled,
                      onChanged: (value) => widget.onToggle(value),
                    ),
                  ),
                ],
                IconButton(
                  key: ValueKey('debrid-expand-${type.name}'),
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    color: Colors.white38,
                  ),
                  onPressed: () => setState(() => _expanded = !_expanded),
                ),
              ],
            ),
            onTap: () => setState(() => _expanded = !_expanded),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextFormField(
                    key: ValueKey('debrid-token-${type.name}'),
                    controller: _controller,
                    obscureText: _obscure,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: 'API Token',
                      hintText: type.tokenUrl,
                      prefixIcon: const Icon(Icons.vpn_key, size: 20),
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_verifying)
                            const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            )
                          else if (_verified == true)
                            const Icon(Icons.check_circle,
                                color: Colors.green, size: 20)
                          else if (_verified == false)
                            const Icon(Icons.error,
                                color: Colors.redAccent, size: 20),
                          IconButton(
                            tooltip: _obscure ? 'Show token' : 'Hide token',
                            icon: Icon(
                              _obscure ? Icons.visibility : Icons.visibility_off,
                              size: 18,
                            ),
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                          ),
                        ],
                      ),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        key: ValueKey('debrid-save-${type.name}'),
                        onPressed: hasToken ? () => _save() : null,
                        icon: const Icon(Icons.save, size: 18),
                        label: const Text('Save'),
                      ),
                      OutlinedButton.icon(
                        key: ValueKey('debrid-verify-${type.name}'),
                        onPressed: hasToken && !_verifying ? _verify : null,
                        icon: const Icon(Icons.verified_outlined, size: 18),
                        label: const Text('Verify'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () {
                          final url = Uri.parse('https://${type.tokenUrl}');
                          launchUrl(url, mode: LaunchMode.externalApplication);
                        },
                        icon: const Icon(Icons.open_in_new, size: 16),
                        label: const Text('Get Key'),
                      ),
                      if (_configured)
                        TextButton.icon(
                          key: ValueKey('debrid-remove-${type.name}'),
                          onPressed: widget.onRemove,
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.redAccent,
                          ),
                          icon: const Icon(Icons.delete_outline, size: 18),
                          label: const Text('Remove'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _statusLabel() {
    if (!_configured) return 'Not configured';
    if (!_enabled) return 'Disabled — token kept';
    if (widget.position == 0) return 'Enabled ✓ · resolves first';
    return 'Enabled ✓ · priority ${widget.position! + 1}';
  }

  Future<void> _save() async {
    await widget.onSave(_controller.text.trim());
    if (!mounted) return;
    setState(() => _verified = null);
  }

  Future<void> _verify() async {
    final token = _controller.text.trim();
    if (token.isEmpty) return;
    setState(() {
      _verifying = true;
      _verified = null;
    });
    try {
      final service = createDebridService(widget.type, token);
      final ok = await service.verifyToken();
      if (mounted) setState(() => _verified = ok);
    } catch (_) {
      if (mounted) setState(() => _verified = false);
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }
}

class _PriorityChip extends StatelessWidget {
  final int position;

  const _PriorityChip({required this.position});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: position == 0
            ? const Color(0xFF6C5CE7).withValues(alpha: 0.25)
            : Colors.white10,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '#${position + 1}',
        style: TextStyle(
          color: position == 0 ? Colors.white : Colors.white54,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
