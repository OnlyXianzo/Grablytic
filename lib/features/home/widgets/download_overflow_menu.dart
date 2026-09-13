import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../providers/download_provider.dart';
import '../../../core/utils/app_logger.dart';
import 'download_log_sheet.dart';

/// Per-item overflow actions (delete / redownload / audio-from-source).
///
/// State-gated so destructive or duplicative work is impossible while the
/// engine holds the id:
/// - Active (downloading/pending/queued): only Cancel is legal (handled by
///   the card's existing progress UI) — Redownload/Delete are disabled with
///   an explanatory message instead of silently colliding (engine rejects
///   with ERROR_ALREADY_ACTIVE as backstop).
/// - Terminal (completed/error/cancelled): Redownload (same id, original
///   config; `fresh` for completed merges force_overwrite + ignore_archive
///   so the fetch actually happens), Download-audio-from-source (new id),
///   Remove-from-history (DB row only), Delete-file+history (filesystem +
///   row, path-confined, MediaStore ghost noted for Android follow-up).
class DownloadOverflowButton extends ConsumerWidget {
  final DownloadItem item;
  final ColorScheme colorScheme;

  const DownloadOverflowButton({
    super.key,
    required this.item,
    required this.colorScheme,
  });

  bool get _isActive =>
      item.status == 'downloading' ||
      item.status == 'pending' ||
      item.status == 'queued';

  bool get _isTerminal =>
      item.status == 'completed' ||
      item.status == 'error' ||
      item.status == 'cancelled';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Semantics(
      label: 'More options for ${item.title}',
      button: true,
      child: PopupMenuButton<String>(
        icon: Icon(
          Icons.more_vert,
          size: 18,
          color: colorScheme.outline.withValues(alpha: 0.6),
        ),
        tooltip: 'More options',
        onSelected: (value) => _onSelected(context, ref, value),
        itemBuilder: (ctx) => [
          PopupMenuItem(
            value: 'view_logs',
            child: Row(
              children: [
                Icon(Icons.terminal,
                    size: 18,
                    color: colorScheme.primary),
                const SizedBox(width: 12),
                const Text('View logs'),
              ],
            ),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'redownload',
            enabled: _isTerminal,
            child: Row(
              children: [
                Icon(Icons.refresh,
                    size: 18,
                    color: _isTerminal
                        ? colorScheme.primary
                        : colorScheme.outline),
                const SizedBox(width: 12),
                Text(item.status == 'completed'
                    ? 'Redownload'
                    : 'Retry download'),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'audio',
            enabled: !_isActive,
            child: Row(
              children: [
                Icon(Icons.audio_file_outlined,
                    size: 18,
                    color: !_isActive
                        ? colorScheme.primary
                        : colorScheme.outline),
                const SizedBox(width: 12),
                const Text('Download audio from source'),
              ],
            ),
          ),
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: 'remove_history',
            child: Row(
              children: [
                Icon(Icons.history, size: 18),
                SizedBox(width: 12),
                Text('Remove from history'),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'delete_file',
            enabled: _isTerminal,
            child: Row(
              children: [
                Icon(Icons.delete_outline,
                    size: 18,
                    color: _isTerminal ? colorScheme.error : colorScheme.outline),
                const SizedBox(width: 12),
                Text('Delete file',
                    style: TextStyle(
                        color: _isTerminal ? colorScheme.error : null)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _onSelected(
      BuildContext context, WidgetRef ref, String value) async {
    final notifier = ref.read(downloadProvider.notifier);
    switch (value) {
      case 'view_logs':
        DownloadLogSheet.show(
          context,
          downloadId: item.id,
          title: item.title,
          status: item.status,
          url: item.url,
        );
        return;
      case 'redownload':
        if (!_isTerminal) {
          _snack(context, 'Cancel the active download first');
          return;
        }
        AppLogger.info('User chose Redownload for ${item.id}',
            tag: 'DownloadOverflow');
        notifier.redownload(item.id, fresh: item.status == 'completed');
        _snack(
            context,
            item.status == 'completed'
                ? 'Re-downloading (fresh fetch)'
                : 'Retrying download');
      case 'audio':
        if (_isActive) {
          _snack(context, 'Cancel the active download first');
          return;
        }
        AppLogger.info('User chose audio-from-source for ${item.id}',
            tag: 'DownloadOverflow');
        final newId = await notifier.downloadAudioFromSource(item.id);
        if (!context.mounted) return;
        _snack(context,
            newId == null ? 'Could not start audio download' : 'Audio download started');
      case 'remove_history':
        if (!context.mounted) return;
        final go = await _confirm(
          context,
          title: 'Remove from history?',
          body:
              '“${_shortTitle(item.title)}” will be removed from your history. The downloaded file (if any) stays on disk.',
          confirm: 'Remove',
        );
        if (go == true) {
          await notifier.removeFromHistory(item.id);
          if (context.mounted) _snack(context, 'Removed from history');
        }
      case 'delete_file':
        if (!_isTerminal) {
          _snack(context, 'Cancel the active download first');
          return;
        }
        if (!context.mounted) return;
        final name = item.filePath?.split('/').lastWhere(
                (s) => s.isNotEmpty,
                orElse: () => '') ??
            '';
        final go = await _confirm(
          context,
          title: 'Delete file?',
          body: name.isNotEmpty
              ? '“$name” will be permanently deleted from disk and removed from history.\n\nIf a later re-download is skipped as already-downloaded, use Settings → Clear download archive.'
              : 'The downloaded file will be permanently deleted from disk and removed from history.',
          confirm: 'Delete',
          destructive: true,
        );
        if (go == true) {
          final ok = await notifier.deleteFileAndHistory(item.id);
          if (context.mounted) {
            _snack(context,
                ok ? 'File deleted' : 'Could not delete — try again');
          }
        }
    }
  }

  String _shortTitle(String title) =>
      title.length > 60 ? '${title.substring(0, 60)}…' : title;

  void _snack(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<bool?> _confirm(
    BuildContext context, {
    required String title,
    required String body,
    required String confirm,
    bool destructive = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: destructive
                ? ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(ctx).colorScheme.error,
                    foregroundColor: Theme.of(ctx).colorScheme.onError,
                  )
                : null,
            child: Text(confirm),
          ),
        ],
      ),
    );
  }
}
