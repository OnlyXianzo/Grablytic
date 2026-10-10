import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/utils/offline_link_queue.dart';
import '../../../core/theme/text_styles.dart';
import '../../../core/utils/notification_helper.dart';
import '../../../providers/batch_provider.dart';
import '../../../providers/preset_provider.dart';
import 'batch_download_screen.dart';

/// Dedicated Link Saver menu (Phase 3).
///
/// Shows all offline-queued links with per-link Delete / Download
/// and a Download All action. Also reachable via the Home FAB.
class LinkSaverScreen extends ConsumerWidget {
  const LinkSaverScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(offlineQueueProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Link Saver'),
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.primary,
        elevation: 0,
      ),
      body: queue.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.bookmark_outline, size: 48, color: colorScheme.outline),
                    const SizedBox(height: 12),
                    Text('No saved links',
                        style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Text('Links saved while offline appear here.',
                        textAlign: TextAlign.center,
                        style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
              itemCount: queue.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final link = queue[index];
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  leading: Icon(
                    link.source == 'share'
                        ? Icons.share_outlined
                        : link.source == 'clipboard'
                            ? Icons.content_paste_outlined
                            : Icons.link,
                    color: colorScheme.primary,
                  ),
                  title: Text(link.title ?? link.url,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: textTheme.bodyMedium),
                  subtitle: Text('${link.source} · ${link.url}',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: textTheme.labelSmall?.copyWith(color: colorScheme.outline)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        key: Key('link_saver_delete_${link.url}'),
                        icon: const Icon(Icons.delete_outline, size: 20),
                        tooltip: 'Delete',
                        onPressed: () => ref.read(offlineQueueProvider.notifier).removeLink(link.url),
                      ),
                      const SizedBox(width: 4),
                      FilledButton.tonal(
                        onPressed: () async {
                          // Single-link download: remove from queue and start as batch of 1.
                          await ref.read(offlineQueueProvider.notifier).removeLink(link.url);
                          final preset = ref.read(presetsProvider).activePreset;
                          final item = BatchItem(url: link.url, title: link.title ?? link.url);
                          ref.read(batchProvider.notifier).startBatch([item], qualityCeiling: preset.qualityCeiling);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              styledSnackBar(
                                context,
                                'Downloading ${link.url}',
                                action: SnackBarAction(
                                  label: 'View Batch',
                                  onPressed: () => Navigator.of(context, rootNavigator: true).push(
                                    MaterialPageRoute(builder: (_) => BatchDownloadScreen(items: [item], skipQualityDialog: true)),
                                  ),
                                ),
                              ),
                            );
                            Navigator.maybePop(context);
                          }
                        },
                        child: const Text('Download'),
                      ),
                    ],
                  ),
                );
              },
            ),
      floatingActionButton: queue.isEmpty
          ? null
          : FloatingActionButton.extended(
              key: const Key('link_saver_download_all_fab'),
              onPressed: () async {
                final count = await ref.read(offlineQueueProvider.notifier).sendAll(context, ref);
                if (count > 0 && context.mounted) Navigator.maybePop(context);
              },
              backgroundColor: colorScheme.primary,
              foregroundColor: colorScheme.onPrimary,
              icon: const Icon(Icons.download_rounded),
              label: Text('Download All (${queue.length})'),
            ),
    );
  }
}
