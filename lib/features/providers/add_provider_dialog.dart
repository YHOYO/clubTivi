import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'provider_manager.dart';

/// Shows the Add Provider dialog.
/// Uses a full-screen page (navigable via D-pad) instead of a bottom sheet.
Future<bool?> showAddProviderDialog(BuildContext context) {
  return Navigator.of(context).push<bool>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => const _AddProviderPage(),
    ),
  );
}

enum _ProviderType { m3u, xtream }

class _AddProviderPage extends ConsumerStatefulWidget {
  const _AddProviderPage();

  @override
  ConsumerState<_AddProviderPage> createState() => _AddProviderPageState();
}

class _AddProviderPageState extends ConsumerState<_AddProviderPage> {
  final _formKey = GlobalKey<FormState>();
  _ProviderType _type = _ProviderType.m3u;

  // M3U fields
  final _m3uName = TextEditingController();
  final _m3uUrl = TextEditingController();

  // Xtream fields
  final _xtreamName = TextEditingController();
  final _xtreamUrl = TextEditingController();
  final _xtreamUser = TextEditingController();
  final _xtreamPass = TextEditingController();

  bool _loading = false;

  @override
  void dispose() {
    _m3uName.dispose();
    _m3uUrl.dispose();
    _xtreamName.dispose();
    _xtreamUrl.dispose();
    _xtreamUser.dispose();
    _xtreamPass.dispose();
    super.dispose();
  }

  String _slugify(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
  }

  String _generateId(String name) {
    final slug = _slugify(name);
    final ts = DateTime.now().millisecondsSinceEpoch;
    return '${slug.isEmpty ? 'provider' : slug}-$ts';
  }

  String? _validateRequired(String? value) {
    if (value == null || value.trim().isEmpty) return 'Required';
    return null;
  }

  String? _validateUrl(String? value) {
    if (value == null || value.trim().isEmpty) return 'Required';
    final input = value.trim();
    if (input.startsWith('http')) return null;
    // A playlist on this machine is just as valid as one on a server.
    if (ProviderManager.isLocalPlaylistPath(input)) return null;
    return 'Enter an http(s) URL or pick a playlist file';
  }

  /// Pick an .m3u/.m3u8 from disk and use it as the provider source.
  Future<void> _pickPlaylistFile() async {
    String? path;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['m3u', 'm3u8', 'txt'],
        dialogTitle: 'Choose a playlist',
      );
      path = result?.files.single.path;
    } catch (e) {
      // Si el diálogo nativo falla, el usuario debe saberlo y poder escribir la
      // ruta a mano en lugar de ver que «no pasa nada» al pulsar el botón.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Could not open the file picker ($e). Type or paste the full path instead.'),
            duration: const Duration(seconds: 8),
          ),
        );
      }
      return;
    }
    if (path == null) return;
    final picked = path;
    setState(() {
      _m3uUrl.text = ProviderManager.toPlaylistUri(picked);
      if (_m3uName.text.trim().isEmpty) {
        // Usa el nombre del fichero como nombre del proveedor.
        _m3uName.text = picked
            .split(RegExp(r'[/\\]'))
            .last
            .replaceAll(RegExp(r'\.(m3u8?|txt)$', caseSensitive: false), '');
      }
    });
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_type == _ProviderType.m3u) {
      await _addProvider(() {
        final manager = ref.read(providerManagerProvider);
        final source = _m3uUrl.text.trim();
        return manager.addM3uProvider(
          id: _generateId(_m3uName.text.trim()),
          name: _m3uName.text.trim(),
          // A path picked from disk is stored as a file:// URI so it survives
          // restarts and moves through the same code path as a URL.
          url: source.startsWith('http')
              ? source
              : ProviderManager.toPlaylistUri(
                  ProviderManager.isLocalPlaylistPath(source)
                      ? ProviderManager.localPlaylistPath(source)
                      : source,
                ),
        );
      });
    } else {
      await _addProvider(() {
        final manager = ref.read(providerManagerProvider);
        return manager.addXtreamProvider(
          id: _generateId(_xtreamName.text.trim()),
          name: _xtreamName.text.trim(),
          url: _xtreamUrl.text.trim(),
          username: _xtreamUser.text.trim(),
          password: _xtreamPass.text.trim(),
        );
      });
    }
  }

  Future<void> _addProvider(Future<void> Function() action) async {
    setState(() => _loading = true);
    try {
      await action();
      if (!mounted) return;
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Provider added successfully')),
      );
    } on ProviderLimitException catch (e) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A2E),
          title: const Text('Provider Limit Reached'),
          content: Text(e.toString()),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A2E),
          title: const Text('Error'),
          content: Text('Failed to add provider:\n$e'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pasteUrl(TextEditingController controller) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      controller.text = data!.text!;
    }
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          final pf = FocusManager.instance.primaryFocus;
          if (pf?.context?.findAncestorWidgetOfExactType<EditableText>() != null) {
            pf!.unfocus();
            return;
          }
          Future.microtask(() {
            if (!context.mounted) return;
            Navigator.of(context).pop();
          });
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Add Provider'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            // Provider type dropdown — D-pad navigable as a form field
            DropdownButtonFormField<_ProviderType>(
              initialValue: _type,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Provider Type',
                prefixIcon: Icon(Icons.live_tv),
              ),
              dropdownColor: const Color(0xFF1A1A2E),
              items: const [
                DropdownMenuItem(
                  value: _ProviderType.m3u,
                  child: Text('M3U Playlist'),
                ),
                DropdownMenuItem(
                  value: _ProviderType.xtream,
                  child: Text('Xtream Codes'),
                ),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _type = v);
              },
            ),
            const SizedBox(height: 24),
            // Fields change based on type
            if (_type == _ProviderType.m3u) ..._buildM3uFields(),
            if (_type == _ProviderType.xtream) ..._buildXtreamFields(),
            const SizedBox(height: 24),
            _buildSubmitButton(),
          ],
        ),
      ),
    ),
    ),
    );
  }

  List<Widget> _buildM3uFields() {
    return [
      TextFormField(
        controller: _m3uName,
        decoration: const InputDecoration(
          labelText: 'Provider Name',
          hintText: 'e.g. My IPTV',
        ),
        validator: _validateRequired,
        textInputAction: TextInputAction.next,
      ),
      const SizedBox(height: 16),
      TextFormField(
        controller: _m3uUrl,
        decoration: const InputDecoration(
          labelText: 'M3U URL or file path',
          hintText: 'http://... or C:\\Users\\you\\Downloads\\tv.m3u8',
          helperText: 'Paste a URL, or the full path of a playlist on this PC',
        ),
        validator: _validateUrl,
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.done,
        // Keeps the local-file hint in sync as the path is typed or pasted.
        onChanged: (_) => setState(() {}),
        onFieldSubmitted: (_) => _submit(),
      ),
      const SizedBox(height: 8),
      Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FilledButton.tonalIcon(
            onPressed: _pickPlaylistFile,
            icon: const Icon(Icons.folder_open, size: 18),
            label: const Text('Choose playlist file…'),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: () => _pasteUrl(_m3uUrl),
            icon: const Icon(Icons.paste, size: 18),
            label: const Text('Paste URL'),
          ),
        ],
      ),
      _buildLocalFileHint(),
    ];
  }

  /// Tell the user, before they submit, that the picked file exists.
  Widget _buildLocalFileHint() {
    final value = _m3uUrl.text.trim();
    if (value.isEmpty || value.startsWith('http')) {
      return const SizedBox.shrink();
    }
    final path = ProviderManager.isLocalPlaylistPath(value)
        ? ProviderManager.localPlaylistPath(value)
        : value;
    final exists = File(path).existsSync();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Icon(
            exists ? Icons.check_circle_outline : Icons.error_outline,
            size: 16,
            color: exists ? Colors.greenAccent : Colors.redAccent,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              exists ? 'Local playlist: $path' : 'File not found: $path',
              style: TextStyle(
                fontSize: 12,
                color: exists ? Colors.white60 : Colors.redAccent,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildXtreamFields() {
    return [
      TextFormField(
        controller: _xtreamName,
        decoration: const InputDecoration(
          labelText: 'Provider Name',
          hintText: 'e.g. My Xtream',
        ),
        validator: _validateRequired,
        textInputAction: TextInputAction.next,
      ),
      const SizedBox(height: 16),
      TextFormField(
        controller: _xtreamUrl,
        decoration: const InputDecoration(
          labelText: 'Server URL',
          hintText: 'http://...',
        ),
        validator: _validateUrl,
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.next,
      ),
      const SizedBox(height: 16),
      TextFormField(
        controller: _xtreamUser,
        decoration: const InputDecoration(
          labelText: 'Username',
        ),
        validator: _validateRequired,
        textInputAction: TextInputAction.next,
      ),
      const SizedBox(height: 16),
      TextFormField(
        controller: _xtreamPass,
        decoration: const InputDecoration(
          labelText: 'Password',
        ),
        obscureText: true,
        validator: _validateRequired,
        textInputAction: TextInputAction.done,
        onFieldSubmitted: (_) => _submit(),
      ),
    ];
  }

  Widget _buildSubmitButton() {
    const accent = Color(0xFF6C5CE7);
    return SizedBox(
      height: 48,
      child: FilledButton(
        onPressed: _loading ? null : _submit,
        style: FilledButton.styleFrom(backgroundColor: accent),
        child: _loading
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Text('Add Provider', style: TextStyle(fontSize: 16)),
      ),
    );
  }
}
