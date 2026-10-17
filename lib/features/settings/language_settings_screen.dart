import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/language_preferences.dart';
import '../../data/services/language_preferences_store.dart';

/// Preferencias de idioma: orden de audio y subtítulos por defecto.
///
/// No guarda estado propio: escribe en [languagePreferencesProvider], que sigue
/// siendo el único dueño del orden. El ranking de fuentes y la elección de
/// pistas del reproductor leen de ahí.
class LanguageSettingsScreen extends ConsumerWidget {
  const LanguageSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preferences = ref.watch(languagePreferencesProvider);
    final notifier = ref.read(languagePreferencesProvider.notifier);
    final catalog = kLanguageCatalog.entries.toList();
    final added = preferences.audioOrder.toSet();
    final missing = [
      for (final entry in catalog)
        if (!added.contains(entry.key)) entry,
    ];

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
            title: const Text('Audio & Subtitles'),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          body: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              const _SectionHeader(title: 'Audio language order'),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  'The order is the priority: when a stream offers several audio '
                  'tracks, the first language on this list wins. A stream in a '
                  'language that is not listed keeps its own default track.',
                  style: TextStyle(color: Colors.white54, fontSize: 13, height: 1.4),
                ),
              ),
              if (preferences.audioOrder.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Text(
                    'No language has priority right now. Add the ones you want '
                    'the app to look for.',
                    style: TextStyle(color: Colors.white38, fontSize: 12, height: 1.4),
                  ),
                ),
              for (var i = 0; i < preferences.audioOrder.length; i++)
                _AudioLanguageRow(
                  code: preferences.audioOrder[i],
                  position: i,
                  total: preferences.audioOrder.length,
                  onMove: (delta) => _move(notifier, preferences, i, delta),
                  onRemove: () => _remove(notifier, preferences, i),
                ),
              if (missing.isNotEmpty) ...[
                const _SectionHeader(title: 'Add a language'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final entry in missing)
                        ActionChip(
                          key: ValueKey('add-language-${entry.key}'),
                          label: Text(entry.value),
                          backgroundColor: const Color(0xFF1A1A2E),
                          labelStyle: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                          side: BorderSide.none,
                          onPressed: () => notifier.setAudioOrder([
                            ...preferences.audioOrder,
                            entry.key,
                          ]),
                        ),
                    ],
                  ),
                ),
              ],
              const _SectionHeader(title: 'Default subtitles'),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  'When a stream carries subtitles in this language they turn '
                  'on by themselves. Pick “None” to keep them off until you '
                  'choose one.',
                  style: TextStyle(color: Colors.white54, fontSize: 13, height: 1.4),
                ),
              ),
              RadioGroup<String?>(
                groupValue: preferences.subtitleOrder.isEmpty
                    ? null
                    : preferences.subtitleOrder.first,
                onChanged: (value) => notifier.setSubtitleOrder(
                  value == null ? const [] : [value],
                ),
                child: Column(
                  children: [
                    const RadioListTile<String?>(
                      key: ValueKey('subtitle-option-none'),
                      value: null,
                      dense: true,
                      title: Text(
                        'None',
                        style: TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                    ),
                    for (final entry in catalog)
                      RadioListTile<String?>(
                        key: ValueKey('subtitle-option-${entry.key}'),
                        value: entry.key,
                        dense: true,
                        title: Text(
                          entry.value,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _move(
    LanguagePreferencesNotifier notifier,
    LanguagePreferences preferences,
    int index,
    int delta,
  ) {
    final target = index + delta;
    if (target < 0 || target >= preferences.audioOrder.length) {
      return Future<void>.value();
    }
    final order = [...preferences.audioOrder];
    final moved = order.removeAt(index);
    order.insert(target, moved);
    return notifier.setAudioOrder(order);
  }

  Future<void> _remove(
    LanguagePreferencesNotifier notifier,
    LanguagePreferences preferences,
    int index,
  ) {
    final order = [...preferences.audioOrder]..removeAt(index);
    return notifier.setAudioOrder(order);
  }
}

class _AudioLanguageRow extends StatelessWidget {
  final String code;
  final int position;
  final int total;
  final void Function(int delta) onMove;
  final VoidCallback onRemove;

  const _AudioLanguageRow({
    required this.code,
    required this.position,
    required this.total,
    required this.onMove,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: ValueKey('audio-row-$code'),
      dense: true,
      leading: CircleAvatar(
        radius: 12,
        backgroundColor: const Color(0xFF6C5CE7).withValues(alpha: 0.25),
        child: Text(
          '${position + 1}',
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
      ),
      title: Text(
        languageLabel(code),
        style: const TextStyle(color: Colors.white, fontSize: 14),
      ),
      subtitle: Text(
        code,
        style: const TextStyle(color: Colors.white38, fontSize: 11),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: ValueKey('audio-up-$code'),
            icon: const Icon(Icons.arrow_upward, size: 18),
            color: Colors.white70,
            tooltip: 'Move up',
            onPressed: position == 0 ? null : () => onMove(-1),
          ),
          IconButton(
            key: ValueKey('audio-down-$code'),
            icon: const Icon(Icons.arrow_downward, size: 18),
            color: Colors.white70,
            tooltip: 'Move down',
            onPressed: position == total - 1 ? null : () => onMove(1),
          ),
          IconButton(
            key: ValueKey('audio-remove-$code'),
            icon: const Icon(Icons.close, size: 18),
            color: Colors.white38,
            tooltip: 'Remove',
            onPressed: onRemove,
          ),
        ],
      ),
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
