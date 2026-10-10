import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/database/download_history_db.dart';
import '../../../core/engine/engine_provider.dart';
import '../../../core/theme/text_styles.dart';
import '../../../core/utils/notification_helper.dart';
import '../../../core/utils/trust_boundary.dart';
import '../../../providers/download_history_provider.dart';
import '../../home/widgets/download_log_sheet.dart';

/// History rows can be played when the media file path is known. Existence
/// is verified at tap time (the file may have been deleted outside the app).
bool _isPlayable(DownloadRecord record) =>
    record.filePath != null && record.filePath!.trim().isNotEmpty;

/// Opens a history record's media file in the system player.
///
/// Mirrors the media-preview open path: Android goes through FileProvider
/// (`intent/open_file`), desktop through the OS resolver. Never throws —
/// every failure surfaces as a snackbar.
Future<void> playHistoryRecord(
    BuildContext context, WidgetRef ref, DownloadRecord record) async {
  final raw = record.filePath;
  if (raw == null || raw.trim().isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      styledSnackBar(context, 'No file for this entry yet'),
    );
    return;
  }
  final path = sanitizeEngineFilePath(raw.trim()) ?? raw.trim();
  if (!File(path).existsSync()) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('File not found — it may have been moved or deleted'),
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );
    return;
  }
  bool opened = false;
  try {
    final res = await ref.read(engineProvider).openFile(path);
    opened = res['success'] == true;
  } catch (_) {}
  if (!context.mounted) return;
  if (opened) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('No app can play this file.\nOpen file at: $path'),
      backgroundColor: Theme.of(context).colorScheme.error,
    ),
  );
}

class DownloadHistoryScreen extends ConsumerStatefulWidget {
  final bool useGridView;

  const DownloadHistoryScreen({super.key, this.useGridView = false});

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
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: colorScheme.primary.withValues(alpha: 0.08),
                          ),
                          child: Icon(
                            Icons.history,
                            size: 36,
                            color: colorScheme.primary.withValues(alpha: 0.7),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'No download history yet',
                          style: textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Items you download will be logged here for quick access.',
                          textAlign: TextAlign.center,
                          style: textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }
              if (widget.useGridView) {
                return GridView.builder(
                  key: const ValueKey('history-grid'),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.72,
                  ),
                  itemCount: records.length,
                  itemBuilder: (context, index) {
                    final record = records[index];
                    return _HistoryGridCard(
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

/// Thumbnail for a history record with a play badge when playable.
///
/// Source order matches the Library: local sidecar ([DownloadRecord.thumbnailPath],
/// offline-friendly, no tracking-pixel fetch) first, remote
/// [DownloadRecord.thumbnailUrl] second, platform icon fallback last.
/// Local paths pass the [sanitizeEngineFilePath] trust boundary and must
/// exist on disk; decodes are capped like the Library to avoid scroll jank.
class _HistoryThumbnail extends StatelessWidget {
  final DownloadRecord record;
  final ColorScheme colorScheme;
  final IconData Function(String?) platformIcon;
  final double width;
  final double height;
  final double borderRadius;
  final bool showPlayBadge;

  const _HistoryThumbnail({
    required this.record,
    required this.colorScheme,
    required this.platformIcon,
    required this.width,
    required this.height,
    required this.borderRadius,
    this.showPlayBadge = false,
  });

  @override
  Widget build(BuildContext context) {
    Widget image = _fallback();
    final local = record.thumbnailPath;
    if (local != null && local.trim().isNotEmpty) {
      final raw = local.trim().startsWith('file://')
          ? local.trim().substring(7)
          : local.trim();
      final path = sanitizeEngineFilePath(raw);
      if (path != null && File(path).existsSync()) {
        image = _fileImage(File(path));
      }
    }
    if (image is _ThumbFallback) {
      final remote = record.thumbnailUrl;
      if (remote != null && remote.trim().isNotEmpty) {
        image = _networkImage(remote.trim());
      }
    }
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          image,
          if (showPlayBadge)
            const Center(
              child: Icon(
                Icons.play_circle_fill,
                size: 28,
                color: Colors.white,
              ),
            ),
        ],
      ),
    );
  }

  Widget _fallback() => _ThumbFallback(
        icon: platformIcon(record.platform),
        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
      );

  Widget _fileImage(File file) => RepaintBoundary(
        child: Image.file(
          file,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          cacheWidth: 360,
          errorBuilder: (context, error, stackTrace) => _fallback(),
        ),
      );

  Widget _networkImage(String url) {
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return _fallback();
    }
    return RepaintBoundary(
      child: Image.network(
        url,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        cacheWidth: 360,
        errorBuilder: (context, error, stackTrace) => _fallback(),
      ),
    );
  }
}

class _ThumbFallback extends StatelessWidget {
  final IconData icon;
  final Color color;

  const _ThumbFallback({required this.icon, required this.color});

  @override
  Widget build(BuildContext context) =>
      Center(child: Icon(icon, size: 20, color: color));
}

class _FilterChip extends StatelessWidget {  final String label;
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

class _HistoryItem extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final statusCol = statusColor(record.status, colorScheme);
    final playable = _isPlayable(record);

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
        hint: 'Double tap to show actions, swipe left to delete',
        onDismiss: onDelete,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: playable
                    ? () => playHistoryRecord(context, ref, record)
                    : null,
                child: _HistoryThumbnail(
                  record: record,
                  colorScheme: colorScheme,
                  platformIcon: platformIcon,
                  width: 64,
                  height: 64,
                  borderRadius: 12,
                  showPlayBadge: playable,
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
                              fontFeatures: const [FontFeature.tabularFigures()],
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
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              Semantics(
                label: 'More options for ${record.title}',
                hint: 'Shows Play, View logs, Delete actions',
                button: true,
                child: PopupMenuButton<String>(
                  key: Key('history-menu-${record.id}'),
                  icon: Icon(Icons.more_vert, size: 20, color: colorScheme.outline),
                  tooltip: 'More options for ${record.title} — shows Play, Logs, Delete',
                  iconSize: 20,
                  onSelected: (value) {
                    switch (value) {
                      case 'play':
                        playHistoryRecord(context, ref, record);
                        break;
                      case 'logs':
                        DownloadLogSheet.show(
                          context,
                          downloadId: record.id,
                          title: record.title,
                          status: record.status,
                          url: record.url,
                        );
                        break;
                      case 'delete':
                        onDelete();
                        break;
                    }
                  },
                  itemBuilder: (ctx) => [
                    if (playable)
                      PopupMenuItem(
                        value: 'play',
                        child: Semantics(
                          button: true,
                          label: 'Play ${record.title}',
                          hint: 'Double tap to play this download',
                          child: Row(children: [
                            Icon(Icons.play_circle_outline, size: 18, color: colorScheme.primary),
                            const SizedBox(width: 8),
                            const Text('Play'),
                          ]),
                        ),
                      ),
                    PopupMenuItem(
                      value: 'logs',
                      child: Semantics(
                        button: true,
                        label: 'View logs for ${record.title}',
                        hint: 'Double tap to view download logs',
                        child: Row(children: [
                          Icon(Icons.terminal, size: 18, color: colorScheme.outline),
                          const SizedBox(width: 8),
                          const Text('View logs'),
                        ]),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Semantics(
                        button: true,
                        label: 'Delete ${record.title}',
                        hint: 'Double tap to delete this download — swipe to delete also available',
                        child: Row(children: [
                          Icon(Icons.delete_outline, size: 18, color: colorScheme.error),
                          const SizedBox(width: 8),
                          Text('Delete', style: TextStyle(color: colorScheme.error)),
                        ]),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryGridCard extends ConsumerWidget {
  final DownloadRecord record;
  final ColorScheme colorScheme;
  final TextTheme textTheme;
  final VoidCallback onDelete;
  final String Function(int?) formatSize;
  final String Function(String) formatDate;
  final IconData Function(String?) platformIcon;
  final Color Function(String, ColorScheme) statusColor;

  const _HistoryGridCard({
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
  Widget build(BuildContext context, WidgetRef ref) {
    final statusCol = statusColor(record.status, colorScheme);
    final playable = _isPlayable(record);

    return Semantics(
      label:
          '${record.title}, status: ${record.status}, ${formatSize(record.fileSize)}',
      child: Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.25),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: playable
                    ? () => playHistoryRecord(context, ref, record)
                    : null,
                child: _HistoryThumbnail(
                  record: record,
                  colorScheme: colorScheme,
                  platformIcon: platformIcon,
                  width: double.infinity,
                  height: 110,
                  borderRadius: 8,
                  showPlayBadge: playable,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                record.title,
                style: textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
                const SizedBox(height: 4),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
              const SizedBox(height: 4),
              if (record.fileSize != null && record.fileSize! > 0)
                Text(
                  formatSize(record.fileSize),
                  style: textTheme.mono.copyWith(
                    fontSize: 11,
                    color: colorScheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              Text(
                formatDate(record.timestamp),
                style: textTheme.mono.copyWith(
                  fontSize: 11,
                  color: colorScheme.outline,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const Spacer(),
              Align(
                alignment: Alignment.centerRight,
                child: Semantics(
                  label: 'More options for ${record.title}',
                  hint: 'Shows Play, View logs, Delete actions',
                  button: true,
                  child: PopupMenuButton<String>(
                    key: Key('history-grid-menu-${record.id}'),
                    icon: Icon(Icons.more_vert, size: 20, color: colorScheme.outline),
                    tooltip: 'More options for ${record.title} — shows Play, Logs, Delete',
                    iconSize: 20,
                    onSelected: (value) {
                      switch (value) {
                        case 'play':
                          playHistoryRecord(context, ref, record);
                          break;
                        case 'logs':
                          DownloadLogSheet.show(
                            context,
                            downloadId: record.id,
                            title: record.title,
                            status: record.status,
                            url: record.url,
                          );
                          break;
                        case 'delete':
                          onDelete();
                          break;
                      }
                    },
                    itemBuilder: (ctx) => [
                      if (playable)
                        PopupMenuItem(
                          value: 'play',
                          child: Semantics(
                            button: true,
                            label: 'Play ${record.title}',
                            hint: 'Double tap to play this download',
                            child: Row(children: [
                              Icon(Icons.play_circle_outline, size: 18, color: colorScheme.primary),
                              const SizedBox(width: 8),
                              const Text('Play'),
                            ]),
                          ),
                        ),
                      PopupMenuItem(
                        value: 'logs',
                        child: Semantics(
                          button: true,
                          label: 'View logs for ${record.title}',
                          hint: 'Double tap to view download logs',
                          child: Row(children: [
                            Icon(Icons.terminal, size: 18, color: colorScheme.outline),
                            const SizedBox(width: 8),
                            const Text('View logs'),
                          ]),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: Semantics(
                          button: true,
                          label: 'Delete ${record.title}',
                          hint: 'Double tap to delete this download — swipe to delete also available',
                          child: Row(children: [
                            Icon(Icons.delete_outline, size: 18, color: colorScheme.error),
                            const SizedBox(width: 8),
                            Text('Delete', style: TextStyle(color: colorScheme.error)),
                          ]),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
