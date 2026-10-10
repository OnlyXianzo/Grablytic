import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../providers/settings_provider.dart';

class SubtitleSettingsScreen extends ConsumerWidget {
  const SubtitleSettingsScreen({super.key});

  static const _availableLanguages = [
    ('English', 'en'),
    ('Spanish', 'es'),
    ('French', 'fr'),
    ('German', 'de'),
    ('Italian', 'it'),
    ('Portuguese', 'pt'),
    ('Russian', 'ru'),
    ('Japanese', 'ja'),
    ('Korean', 'ko'),
    ('Chinese (Simplified)', 'zh-Hans'),
    ('Chinese (Traditional)', 'zh-Hant'),
    ('Arabic', 'ar'),
    ('Hindi', 'hi'),
    ('Turkish', 'tr'),
    ('Dutch', 'nl'),
    ('Polish', 'pl'),
    ('Swedish', 'sv'),
    ('Danish', 'da'),
    ('Finnish', 'fi'),
    ('Norwegian', 'no'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Subtitle Settings'),
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.primary,
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SubtitleSwitch(
                icon: Icons.closed_caption_outlined,
                title: 'Download Subtitles',
                subtitle: 'Fetch subtitle tracks alongside media',
                value: settings.downloadSubtitles,
                onChanged: () =>
                    ref.read(settingsProvider.notifier).toggleDownloadSubtitles(),
                colorScheme: colorScheme,
              ),
              if (settings.downloadSubtitles) ...[
                const SizedBox(height: 16),
                Text(
                  'SUBTITLE LANGUAGES',
                  style: textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _availableLanguages.map((lang) {
                    final code = lang.$2;
                    final selected = settings.subtitleLanguages.contains(code);
                    return FilterChip(
                      label: Text(lang.$1),
                      selected: selected,
                      onSelected: (val) {
                        final notifier = ref.read(settingsProvider.notifier);
                        final current = List<String>.from(
                            settings.subtitleLanguages);
                        if (val) {
                          current.add(code);
                        } else {
                          current.remove(code);
                        }
                        notifier.setSubtitleLanguages(current);
                      },
                      selectedColor: colorScheme.primaryContainer,
                      checkmarkColor: colorScheme.onPrimaryContainer,
                      backgroundColor: colorScheme.surfaceContainer,
                      labelStyle: TextStyle(
                        color: selected
                            ? colorScheme.onPrimaryContainer
                            : colorScheme.onSurface,
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
              ],
              _SubtitleSwitch(
                icon: Icons.auto_awesome,
                title: 'Auto-generated Subtitles',
                subtitle: 'Include YouTube auto-captions when available',
                value: settings.downloadAutoSubtitles,
                onChanged: () =>
                    ref.read(settingsProvider.notifier).toggleDownloadAutoSubtitles(),
                colorScheme: colorScheme,
              ),
              _SubtitleSwitch(
                icon: Icons.merge,
                title: 'Embed Subtitles in File',
                subtitle: 'Mux subtitles into the container (e.g. MKV)',
                value: settings.embedSubtitles,
                onChanged: () =>
                    ref.read(settingsProvider.notifier).toggleEmbedSubtitles(),
                colorScheme: colorScheme,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SubtitleSwitch extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final VoidCallback onChanged;
  final ColorScheme colorScheme;

  const _SubtitleSwitch({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(icon, color: colorScheme.primary, size: 20),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  subtitle,
                  style: textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: value,
            onChanged: (_) => onChanged(),
            activeTrackColor: colorScheme.primary,
            inactiveTrackColor: colorScheme.surfaceContainerHighest,
            thumbColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.selected)) {
                return colorScheme.onPrimary;
              }
              return colorScheme.outline;
            }),
          ),
        ],
      ),
    );
  }
}
