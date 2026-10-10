import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/engine/engine_provider.dart';
import '../../../core/utils/notification_helper.dart';
import '../../../core/utils/offline_link_queue.dart';
import '../../../providers/batch_provider.dart';
import '../../../providers/preset_provider.dart';
import '../../../providers/settings_provider.dart';
import '../screens/batch_download_screen.dart';

/// Banner displayed on [HomeScreen] when links are saved in the offline queue (T19).
///
/// Provides visibility into queued links and a "one-tap send when back online"
/// button that dispatches all queued links to the download queue.
class OfflineQueueBanner extends ConsumerStatefulWidget {
  const OfflineQueueBanner({super.key});

  @override
  ConsumerState<OfflineQueueBanner> createState() => _OfflineQueueBannerState();
}

class _OfflineQueueBannerState extends ConsumerState<OfflineQueueBanner> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final queue = ref.watch(offlineQueueProvider);
    if (queue.isEmpty) return const SizedBox.shrink();

    final settings = ref.watch(settingsProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      key: const Key('offline_queue_banner'),
      margin: const EdgeInsets.only(bottom: 24),
      elevation: 0,
      color: colorScheme.tertiaryContainer.withValues(alpha: 0.35),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colorScheme.tertiary.withValues(alpha: 0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: colorScheme.tertiaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.cloud_off,
                    size: 20,
                    color: colorScheme.onTertiaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            'Offline Link Queue',
                            style: textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: colorScheme.onSurface,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: colorScheme.tertiary,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '${queue.length}',
                              style: textTheme.labelSmall?.copyWith(
                                color: colorScheme.onTertiary,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Saved while offline. Download when reconnected.',
                        style: textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  tooltip: _expanded ? 'Hide links' : 'Show links',
                  onPressed: () => setState(() => _expanded = !_expanded),
                ),
              ],
            ),
            if (_expanded) ...[
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 180),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: queue.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final item = queue[index];
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        item.source == 'share'
                            ? Icons.share_outlined
                            : item.source == 'clipboard'
                            ? Icons.content_paste_outlined
                            : Icons.link,
                        size: 18,
                        color: colorScheme.tertiary,
                      ),
                      title: Text(
                        item.title ?? item.url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      subtitle: Text(
                        '${item.source} · ${item.url}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.labelSmall?.copyWith(
                          color: colorScheme.outline,
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.delete_outline, size: 16),
                            tooltip: 'Delete',
                            onPressed: () => ref
                                .read(offlineQueueProvider.notifier)
                                .removeLink(item.url),
                          ),
                          IconButton(
                            icon: Icon(Icons.download_rounded,
                                size: 16, color: colorScheme.primary),
                            tooltip: 'Download',
                            onPressed: () async {
                              await ref
                                  .read(offlineQueueProvider.notifier)
                                  .removeLink(item.url);
                              final preset =
                                  ref.read(presetsProvider).activePreset;
                              final batchItem = BatchItem(
                                  url: item.url, title: item.title ?? item.url);
                              ref.read(batchProvider.notifier).startBatch(
                                    [batchItem],
                                    qualityCeiling: preset.qualityCeiling,
                                  );
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  styledSnackBar(
                                    context,
                                    'Downloading ${item.url}',
                                    action: SnackBarAction(
                                      label: 'View Batch',
                                      onPressed: () => Navigator.of(context,
                                              rootNavigator: true)
                                          .push(MaterialPageRoute(
                                        builder: (_) => BatchDownloadScreen(
                                          items: [batchItem],
                                          skipQualityDialog: true,
                                        ),
                                      )),
                                    ),
                                  ),
                                );
                              }
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                IconButton(
                  key: const Key('offline_queue_reminder_button'),
                  icon: Icon(
                    settings.queueReminderEnabled
                        ? Icons.notifications_active
                        : Icons.notifications_none,
                    size: 20,
                    color: settings.queueReminderEnabled
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                  ),
                  tooltip: settings.queueReminderEnabled
                      ? 'Queue reminders: ${formatQueueReminderInterval(settings.queueReminderIntervalMinutes)}'
                      : 'Enable queue reminders',
                  onPressed: () async {
                    if (!settings.queueReminderEnabled) {
                      final granted = await requestQueueReminderPermission(
                        ref.read(engineProvider),
                      );
                      if (!context.mounted) return;
                      if (!granted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          styledSnackBar(
                            context,
                            'Notification permission is required for queue reminders',
                          ),
                        );
                        return;
                      }
                      ref
                          .read(settingsProvider.notifier)
                          .setQueueReminderEnabled(true);
                      ScaffoldMessenger.of(context).showSnackBar(
                        styledSnackBar(context, 'Queue reminders enabled'),
                      );
                    } else {
                      ref
                          .read(settingsProvider.notifier)
                          .setQueueReminderEnabled(false);
                      ScaffoldMessenger.of(context).showSnackBar(
                        styledSnackBar(context, 'Queue reminders turned off'),
                      );
                    }
                  },
                ),
                const Spacer(),
                TextButton(
                  key: const Key('offline_queue_clear_button'),
                  onPressed: () =>
                      ref.read(offlineQueueProvider.notifier).clear(),
                  style: TextButton.styleFrom(
                    foregroundColor: colorScheme.error,
                  ),
                  child: const Text('Clear All'),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  key: const Key('offline_queue_send_all_button'),
                  icon: const Icon(Icons.file_download, size: 18),
                  label: const Text('Download All'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colorScheme.primary,
                    foregroundColor: colorScheme.onPrimary,
                  ),
                  onPressed: () => ref
                      .read(offlineQueueProvider.notifier)
                      .sendAll(context, ref),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
