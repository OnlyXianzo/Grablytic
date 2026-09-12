import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/text_styles.dart';
import '../../../providers/settings_provider.dart';

class CommandTemplatesScreen extends ConsumerWidget {
  const CommandTemplatesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final templates = ref.watch(settingsProvider).customTemplates;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Command Templates'),
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.primary,
        elevation: 0,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showTemplateDialog(context, ref, null),
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
        icon: const Icon(Icons.add),
        label: const Text('Add Template'),
      ),
      body: SafeArea(
        child: templates.isEmpty
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.terminal, size: 64, color: colorScheme.outlineVariant),
                    const SizedBox(height: 16),
                    Text(
                      'No custom templates yet',
                      style: textTheme.bodyLarge?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Add yt-dlp argument templates for quick reuse',
                      style: textTheme.labelSmall?.copyWith(
                        color: colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
                children: [
                  Text(
                    'CUSTOM TEMPLATES',
                    style: textTheme.labelSmall?.copyWith(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  for (int i = 0; i < templates.length; i++)
                    _TemplateCard(
                      index: i,
                      templateJson: templates[i],
                      colorScheme: colorScheme,
                      textTheme: textTheme,
                      onTap: () => _showTemplateDialog(context, ref, i),
                      onDelete: () => _confirmDelete(context, ref, i),
                    ),
                ],
              ),
      ),
    );
  }

  void _showTemplateDialog(BuildContext context, WidgetRef ref, int? index) {
    final templates = ref.read(settingsProvider).customTemplates;
    final existing = index != null && index < templates.length
        ? _decodeTemplate(templates[index])
        : null;

    final nameController = TextEditingController(text: existing?.name ?? '');
    final argsController = TextEditingController(text: existing?.args ?? '');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(index != null ? 'Edit Template' : 'Add Template'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Template Name',
                hintText: 'e.g. Subtitles',
              ),
              autofocus: index == null,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: argsController,
              decoration: const InputDecoration(
                labelText: 'Command-line arguments',
                hintText: 'e.g. --write-sub --sub-lang en',
              ),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final name = nameController.text.trim();
              final args = argsController.text.trim();
              if (name.isEmpty || args.isEmpty) return;

              // SEC-04: gate path escapes at input (engine confines too).
              final problem = validateTemplateArgs(args);
              if (problem != null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(problem)),
                );
                return;
              }

              final entry = jsonEncode({'name': name, 'args': args});
              final updated = [...templates];
              if (index != null && index < updated.length) {
                updated[index] = entry;
              } else {
                updated.add(entry);
              }
              ref.read(settingsProvider.notifier).setCustomTemplates(updated);
              if (templateWantsExec(args)) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                        'Warning: --exec runs shell commands on your device. Only use templates you typed yourself.'),
                    duration: Duration(seconds: 5),
                  ),
                );
              }
              Navigator.of(ctx).pop();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(BuildContext context, WidgetRef ref, int index) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Template'),
        content: const Text('Are you sure you want to delete this template?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final templates = [...ref.read(settingsProvider).customTemplates];
              templates.removeAt(index);
              ref.read(settingsProvider.notifier).setCustomTemplates(templates);
              Navigator.of(ctx).pop();
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  ({String name, String args}) _decodeTemplate(String json) {
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      return (name: map['name'] as String? ?? '', args: map['args'] as String? ?? '');
    } catch (_) {
      return (name: 'Invalid', args: json);
    }
  }
}

class _TemplateCard extends StatelessWidget {
  final int index;
  final String templateJson;
  final ColorScheme colorScheme;
  final TextTheme textTheme;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _TemplateCard({
    required this.index,
    required this.templateJson,
    required this.colorScheme,
    required this.textTheme,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final (name: name, args: args) = _decodeTemplate(templateJson);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      color: colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.3),
          width: 1.0,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Semantics(
                label: 'Template',
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer.withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.terminal, color: colorScheme.primary, size: 20),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      args,
                      style: textTheme.mono.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Semantics(
                label: 'Delete template',
                child: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: onDelete,
                  color: colorScheme.error,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  ({String name, String args}) _decodeTemplate(String json) {
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      return (name: map['name'] as String? ?? '', args: map['args'] as String? ?? '');
    } catch (_) {
      return (name: 'Invalid', args: json);
    }
  }
}
