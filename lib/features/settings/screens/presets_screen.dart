import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/text_styles.dart';
import '../../../providers/preset_provider.dart';
import 'profile_editor_screen.dart';

class PresetsScreen extends ConsumerWidget {
  const PresetsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final presetsState = ref.watch(presetsProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final predefined = presetsState.presets.where((p) => p.isPredefined).toList();
    final custom = presetsState.presets.where((p) => !p.isPredefined).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Download Presets'),
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.primary,
        elevation: 0,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const ProfileEditorScreen(),
            ),
          );
        },
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
        icon: const Icon(Icons.add),
        label: const Text('Create Preset'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
          children: [
            if (custom.isNotEmpty) ...[
              Text(
                'CUSTOM PRESETS',
                style: textTheme.labelSmall?.copyWith(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(height: 12),
              ...custom.map((preset) => _PresetCard(
                    preset: preset,
                    isActive: preset.id == presetsState.activePresetId,
                    colorScheme: colorScheme,
                    textTheme: textTheme,
                  )),
              const SizedBox(height: 24),
            ],
            Text(
              'BUILT-IN PRESETS',
              style: textTheme.labelSmall?.copyWith(
                color: colorScheme.primary,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            ...predefined.map((preset) => _PresetCard(
                  preset: preset,
                  isActive: preset.id == presetsState.activePresetId,
                  colorScheme: colorScheme,
                  textTheme: textTheme,
                )),
          ],
        ),
      ),
    );
  }
}

class _PresetCard extends ConsumerWidget {
  final DownloadPreset preset;
  final bool isActive;
  final ColorScheme colorScheme;
  final TextTheme textTheme;

  const _PresetCard({
    required this.preset,
    required this.isActive,
    required this.colorScheme,
    required this.textTheme,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      color: isActive
          ? colorScheme.primaryContainer.withValues(alpha: 0.15)
          : colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: isActive
              ? colorScheme.primary.withValues(alpha: 0.5)
              : colorScheme.outlineVariant.withValues(alpha: 0.3),
          width: isActive ? 1.5 : 1.0,
        ),
      ),
      child: InkWell(
        onTap: () {
          ref.read(presetsProvider.notifier).setActivePreset(preset.id);
        },
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          preset.name,
                          style: textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: isActive ? colorScheme.primary : colorScheme.onSurface,
                          ),
                        ),
                        if (preset.isPredefined) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'Built-in',
                              style: textTheme.labelSmall?.copyWith(fontSize: 9),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      preset.audioOnly
                          ? 'Audio Only · ${preset.preferredContainer.toUpperCase()}'
                          : 'Video · Max ${preset.qualityCeiling.toUpperCase()} · ${preset.preferredCodec.toUpperCase()} · ${preset.preferredContainer.toUpperCase()}',
                      style: textTheme.mono.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              if (isActive)
                Semantics(
                  label: 'Active preset',
                  child: Icon(
                    Icons.check_circle,
                    color: colorScheme.primary,
                    size: 24,
                  ),
                ),
              if (!preset.isPredefined) ...[
                const SizedBox(width: 12),
                IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ProfileEditorScreen(profileId: preset.id),
                      ),
                    );
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
