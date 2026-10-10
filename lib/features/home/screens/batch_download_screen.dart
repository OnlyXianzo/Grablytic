import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../providers/batch_provider.dart';
import '../../../providers/metered_guard.dart';
import '../../../providers/preset_provider.dart';
import '../../../providers/settings_provider.dart';
import '../widgets/batch_quality_dialog.dart';

class BatchDownloadScreen extends ConsumerStatefulWidget {
  final List<BatchItem> items;
  final String? playlistId;
  final bool skipQualityDialog;

  /// Displays batch progress. With [skipQualityDialog], opening the screen
  /// skips metered-network confirmation, quality selection, and batch startup;
  /// the caller is responsible for starting the batch beforehand.
  const BatchDownloadScreen({
    super.key,
    required this.items,
    this.playlistId,
    this.skipQualityDialog = false,
  });

  @override
  ConsumerState<BatchDownloadScreen> createState() =>
      _BatchDownloadScreenState();
}

class _BatchDownloadScreenState extends ConsumerState<BatchDownloadScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || widget.items.isEmpty) return;
      if (widget.skipQualityDialog) return;
      final batch = ref.read(batchProvider);
      if (batch.isRunning && batch.items.length == widget.items.length) return;
      // One metered confirm for the whole batch (Seal parity) — "Wait"
      // backs out of the batch screen instead of starting silently.
      if (!await ensureUnmeteredDownload(context: context, ref: ref)) {
        if (mounted) Navigator.pop(context);
        return;
      }
      if (!mounted) return;
      // One quality pick for the whole queue (persisted as the next
      // batch's default). Cancel backs out instead of starting silently.
      final prefs = ref.read(sharedPreferencesProvider);
      final activeCeiling =
          ref.read(presetsProvider).activePreset.qualityCeiling;
      final initial = normalizeBatchCeiling(
        prefs.getString(lastBatchQualityKey) ?? activeCeiling,
      );
      final chosen = await showBatchQualityDialog(
        context: context,
        initialCeiling: initial,
        itemCount: widget.items.length,
      );
      if (!mounted) return;
      if (chosen == null) {
        Navigator.pop(context);
        return;
      }
      await prefs.setString(lastBatchQualityKey, chosen);
      if (mounted && widget.items.isNotEmpty) {
        ref.read(batchProvider.notifier).startBatch(
              widget.items,
              playlistId: widget.playlistId,
              qualityCeiling: chosen,
            );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final batchState = ref.watch(batchProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final total = widget.items.length;
    final completed = batchState.items
        .where((i) => i.status == BatchItemStatus.completed)
        .length;
    final failedItems = batchState.items
        .where((i) => i.status == BatchItemStatus.failed)
        .toList();
    final failedCount = failedItems.length;
    final skippedCount = failedItems.where(batchItemSkipped).length;
    final retryableCount = failedCount - skippedCount;
    final progress = total > 0 ? completed / total : 0.0;
    final allDone = batchState.items.every(
      (i) => i.status == BatchItemStatus.completed ||
          i.status == BatchItemStatus.failed,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Batch Download'),
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.primary,
        elevation: 0,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              color: colorScheme.primaryContainer.withValues(alpha: 0.15),
                child: Text(
                  '$total items selected'
                  '${batchState.qualityCeiling != null ? ' · ${batchQualityLabel(batchState.qualityCeiling!)}' : ''}',
                style: textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Progress',
                        style: textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        '$completed / $total',
                        style: textTheme.bodySmall?.copyWith(
                          color: colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 6,
                      backgroundColor: colorScheme.surfaceContainerHighest,
                      valueColor:
                          AlwaysStoppedAnimation<Color>(colorScheme.primary),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '$completed completed · $failedCount failed · $skippedCount skipped',
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (failedCount > 0 && !batchState.isRunning) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () {
                          ref.read(batchProvider.notifier).retryFailed();
                        },
                        icon: const Icon(Icons.refresh),
                        label: Text('Retry $failedCount failed'),
                      ),
                    ),
                    if (skippedCount > 0 && retryableCount == 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'All failures are photo posts or private items with no video to retry.',
                          style: textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
                itemCount: batchState.items.length,
                itemBuilder: (context, index) {
                  final item = batchState.items[index];
                  final isCurrent = index == batchState.currentIndex;
                  return Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    elevation: 0,
                    color: colorScheme.surfaceContainerLow,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(
                        color: isCurrent
                            ? colorScheme.primary.withValues(alpha: 0.4)
                            : colorScheme.outlineVariant
                                .withValues(alpha: 0.3),
                      ),
                    ),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      leading: _buildStatusIcon(item.status, colorScheme),
                      title: Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          item.status == BatchItemStatus.failed
                              ? batchFailureLabel(item)
                              : _statusLabel(item.status),
                          style: textTheme.labelSmall?.copyWith(
                            color: _statusColor(item.status, colorScheme),
                          ),
                        ),
                      ),
                      trailing: item.status == BatchItemStatus.pending
                          ? IconButton(
                              icon: Icon(
                                Icons.cancel_outlined,
                                color: colorScheme.error,
                              ),
                              onPressed: () {
                                ref
                                    .read(batchProvider.notifier)
                                    .cancelItem(index);
                              },
                            )
                          : null,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: allDone
          ? FloatingActionButton.extended(
              onPressed: () => Navigator.pop(context),
              backgroundColor: colorScheme.primary,
              foregroundColor: colorScheme.onPrimary,
              icon: const Icon(Icons.check),
              label: const Text('Done'),
            )
          : batchState.isRunning
              ? FloatingActionButton.extended(
                  onPressed: () {
                    ref.read(batchProvider.notifier).cancelAll();
                  },
                  backgroundColor: colorScheme.error,
                  foregroundColor: colorScheme.onError,
                  icon: const Icon(Icons.stop),
                  label: const Text('Cancel All'),
                )
              : null,
    );
  }

  Widget _buildStatusIcon(BatchItemStatus status, ColorScheme colorScheme) {
    switch (status) {
      case BatchItemStatus.pending:
        return Icon(Icons.hourglass_empty, color: colorScheme.outline);
      case BatchItemStatus.downloading:
        return SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: colorScheme.primary,
          ),
        );
      case BatchItemStatus.completed:
        return Icon(Icons.check_circle, color: colorScheme.primary);
      case BatchItemStatus.failed:
        return Icon(Icons.error_outline, color: colorScheme.error);
    }
  }

  Color _statusColor(BatchItemStatus status, ColorScheme colorScheme) {
    switch (status) {
      case BatchItemStatus.pending:
        return colorScheme.outline;
      case BatchItemStatus.downloading:
        return colorScheme.primary;
      case BatchItemStatus.completed:
        return colorScheme.primary;
      case BatchItemStatus.failed:
        return colorScheme.error;
    }
  }

  String _statusLabel(BatchItemStatus status) {
    switch (status) {
      case BatchItemStatus.pending:
        return 'Pending';
      case BatchItemStatus.downloading:
        return 'Downloading...';
      case BatchItemStatus.completed:
        return 'Completed';
      case BatchItemStatus.failed:
        return 'Failed';
    }
  }
}
