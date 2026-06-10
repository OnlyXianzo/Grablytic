import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/text_styles.dart';
import '../../../providers/settings_provider.dart';

class ObservedSourcesScreen extends ConsumerWidget {
  const ObservedSourcesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final sources = settings.observedSources;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Observed Sources'),
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.primary,
        elevation: 0,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddSourceDialog(context, ref),
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
        icon: const Icon(Icons.add),
        label: const Text('Add Source'),
      ),
      body: SafeArea(
        child: sources.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.visibility_outlined,
                        size: 64,
                        color: colorScheme.outlineVariant,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No sources observed',
                        style: textTheme.titleMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Add channels to auto-download new videos.',
                        style: textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
                itemCount: sources.length,
                itemBuilder: (context, index) {
                  final source = sources[index];
                  final enabled = source['enabled'] as bool? ?? true;
                  final name = source['name'] as String? ?? '';
                  final url = source['url'] as String? ?? '';
                  final quality = source['quality'] as String? ?? 'best';

                  return Dismissible(
                    key: Key('source_$index'),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 24),
                      decoration: BoxDecoration(
                        color: colorScheme.error,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.delete_outline, color: colorScheme.onError),
                    ),
                    onDismissed: (_) {
                      ref.read(settingsProvider.notifier).removeObservedSource(index);
                    },
                    child: Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      elevation: 0,
                      color: enabled
                          ? colorScheme.surfaceContainerLow
                          : colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: colorScheme.outlineVariant.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    name,
                                    style: textTheme.bodyLarge?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      color: enabled
                                          ? colorScheme.onSurface
                                          : colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    url,
                                    style: textTheme.mono.copyWith(
                                      color: colorScheme.onSurfaceVariant,
                                      fontSize: 11,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: colorScheme.tertiaryContainer.withValues(alpha: 0.3),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      quality,
                                      style: textTheme.labelSmall?.copyWith(
                                        color: colorScheme.tertiary,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Switch.adaptive(
                              value: enabled,
                              onChanged: (_) {
                                ref.read(settingsProvider.notifier).toggleObservedSource(index);
                              },
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
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }

  void _showAddSourceDialog(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    String selectedQuality = 'best';

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colorScheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Add Source'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: InputDecoration(
                  labelText: 'Channel Name',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: urlController,
                decoration: InputDecoration(
                  labelText: 'Channel URL',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: selectedQuality,
                decoration: InputDecoration(
                  labelText: 'Quality',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                items: const [
                  DropdownMenuItem(value: 'best', child: Text('Best Available')),
                  DropdownMenuItem(value: '4k', child: Text('4K')),
                  DropdownMenuItem(value: '1080p', child: Text('1080p')),
                  DropdownMenuItem(value: '720p', child: Text('720p')),
                  DropdownMenuItem(value: '480p', child: Text('480p')),
                  DropdownMenuItem(value: 'audio', child: Text('Audio Only')),
                ],
                onChanged: (val) {
                  if (val != null) selectedQuality = val;
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final name = nameController.text.trim();
              final url = urlController.text.trim();
              if (name.isNotEmpty && url.isNotEmpty) {
                ref.read(settingsProvider.notifier).addObservedSource({
                  'name': name,
                  'url': url,
                  'quality': selectedQuality,
                  'enabled': true,
                });
                Navigator.of(ctx).pop();
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }
}
