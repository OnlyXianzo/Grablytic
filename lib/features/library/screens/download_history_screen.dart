import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/database/download_history_db.dart';
import '../../../core/theme/text_styles.dart';
import '../../../providers/download_history_provider.dart';

class DownloadHistoryScreen extends ConsumerStatefulWidget {
  const DownloadHistoryScreen({super.key});

  @override
  ConsumerState<DownloadHistoryScreen> createState() =>
      _DownloadHistoryScreenState();
}

class _DownloadHistoryScreenState
    extends ConsumerState<DownloadHistoryScreen> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _formatSize(int? bytes) {
    if (bytes == null || bytes <= 0) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1073741824) {
      return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
  }

  String _formatDate(String iso) {
    try {
      final dt = DateTime.parse(iso);
      final now = DateTime.now();
      final diff = now.difference(dt);
      if (diff.inMinutes < 1) return 'Just now';
      if (diff.inHours < 1) return '${diff.inMinutes}m ago';
      if (diff.inDays < 1) return '${diff.inHours}h ago';
      if (diff.inDays < 7) return '${diff.inDays}d ago';
      return '${dt.month}/${dt.day}/${dt.year}';
    } catch (_) {
      return iso;
    }
  }

  Future<void> _deleteRecord(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete record'),
        content: const Text('Remove this download from history?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await DownloadHistoryDb.instance.delete(id);
      ref.invalidate(downloadHistoryProvider);
    }
  }

  IconData _platformIcon(String? platform) {
    if (platform == null) return Icons.link;
    switch (platform.toLowerCase()) {
      case 'youtube':
        return Icons.videocam;
      case 'instagram':
        return Icons.camera_alt;
      case 'twitter':
      case 'x':
        return Icons.alternate_email;
      case 'bilibili':
        return Icons.tv;
      case 'twitch':
        return Icons.live_tv;
      default:
        return Icons.link;
    }
  }

  Color _statusColor(String status, ColorScheme cs) {
    switch (status) {
      case 'completed':
        return cs.tertiary;
      case 'error':
        return cs.error;
      case 'downloading':
        return cs.primary;
      default:
        return cs.outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    final historyAsync = ref.watch(downloadHistoryProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
          child: Semantics(
            label: 'Search download history',
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search by title or URL...',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          ref
                              .read(downloadHistorySearchProvider.notifier)
                              .state = '';
                        },
                      )
                    : null,
                filled: true,
                fillColor: colorScheme.surfaceContainerLow,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
              style: textTheme.bodyMedium,
              onChanged: (value) {
                ref.read(downloadHistorySearchProvider.notifier).state = value;
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              _FilterChip(
                label: 'All',
                selected: ref.watch(downloadHistoryStatusFilterProvider) ==
                    null,
                onSelected: () {
                  ref
                      .read(downloadHistoryStatusFilterProvider.notifier)
                      .state = null;
                },
                colorScheme: colorScheme,
              ),
              const SizedBox(width: 8),
              _FilterChip(
                label: 'Completed',
                selected:
                    ref.watch(downloadHistoryStatusFilterProvider) ==
                        'completed',
                onSelected: () {
                  ref
                      .read(downloadHistoryStatusFilterProvider.notifier)
                      .state = 'completed';
                },
                colorScheme: colorScheme,
              ),
              const SizedBox(width: 8),
              _FilterChip(
                label: 'Failed',
                selected:
                    ref.watch(downloadHistoryStatusFilterProvider) == 'error',
                onSelected: () {
                  ref
                      .read(downloadHistoryStatusFilterProvider.notifier)
                      .state = 'error';
                },
                colorScheme: colorScheme,
              ),
              const SizedBox(width: 8),
              _FilterChip(
                label: 'In Progress',
                selected:
                    ref.watch(downloadHistoryStatusFilterProvider) ==
                        'downloading',
                onSelected: () {
                  ref
                      .read(downloadHistoryStatusFilterProvider.notifier)
                      .state = 'downloading';
                },
                colorScheme: colorScheme,
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: historyAsync.when(
            data: (records) {
              if (records.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 60),
                    child: Column(
                      children: [
                        Icon(Icons.history,
                            size: 64,
                            color: colorScheme.outline.withValues(alpha: 0.5)),
                        const SizedBox(height: 16),
                        Text(
                          'No download history yet',
                          style: textTheme.bodyLarge?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
                itemCount: records.length,
                itemBuilder: (context, index) {
                  final record = records[index];
                  return _HistoryItem(
                    record: record,
                    colorScheme: colorScheme,
                    textTheme: textTheme,
                    onDelete: () => _deleteRecord(record.id),
                    formatSize: _formatSize,
                    formatDate: _formatDate,
                    platformIcon: _platformIcon,
                    statusColor: _statusColor,
                  );
                },
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (err, _) => Center(
              child: Text('Error: $err',
                  style: textTheme.bodyMedium
                      ?.copyWith(color: colorScheme.error)),
            ),
          ),
        ),
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onSelected;
  final ColorScheme colorScheme;

  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onSelected,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Semantics(
      label: 'Filter: $label${selected ? ', selected' : ''}',
      child: GestureDetector(
        onTap: onSelected,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? colorScheme.primary
                : colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected
                  ? colorScheme.primary
                  : colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          child: Text(
            label,
            style: textTheme.labelMedium?.copyWith(
              color: selected
                  ? colorScheme.onPrimary
                  : colorScheme.onSurfaceVariant,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

class _HistoryItem extends StatelessWidget {
  final DownloadRecord record;
  final ColorScheme colorScheme;
  final TextTheme textTheme;
  final VoidCallback onDelete;
  final String Function(int?) formatSize;
  final String Function(String) formatDate;
  final IconData Function(String?) platformIcon;
  final Color Function(String, ColorScheme) statusColor;

  const _HistoryItem({
    required this.record,
    required this.colorScheme,
    required this.textTheme,
    required this.onDelete,
    required this.formatSize,
    required this.formatDate,
    required this.platformIcon,
    required this.statusColor,
  });

  @override
  Widget build(BuildContext context) {
    final statusCol = statusColor(record.status, colorScheme);

    return Dismissible(
      key: ValueKey(record.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(Icons.delete_outline, color: colorScheme.onErrorContainer),
      ),
      confirmDismiss: (_) async {
        onDelete();
        return false;
      },
      child: Semantics(
        label:
            '${record.title}, status: ${record.status}, ${formatSize(record.fileSize)}',
        child: Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  platformIcon(record.platform),
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      record.title,
                      style: textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: statusCol.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            record.status,
                            style: textTheme.mono.copyWith(
                              fontSize: 10,
                              color: statusCol,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (record.quality != null) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              record.quality!,
                              style: textTheme.mono.copyWith(
                                fontSize: 10,
                                color: colorScheme.onPrimaryContainer,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(width: 6),
                        if (record.fileSize != null &&
                            record.fileSize! > 0)
                          Text(
                            formatSize(record.fileSize),
                            style: textTheme.mono.copyWith(
                              fontSize: 11,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      formatDate(record.timestamp),
                      style: textTheme.mono.copyWith(
                        fontSize: 11,
                        color: colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
              Semantics(
                label: 'Delete download record',
                child: IconButton(
                  icon: Icon(Icons.delete_outline,
                      size: 18, color: colorScheme.outline),
                  onPressed: onDelete,
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Delete',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
