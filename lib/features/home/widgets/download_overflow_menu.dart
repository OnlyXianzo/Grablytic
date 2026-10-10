import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../providers/download_provider.dart';
import '../../../core/utils/app_logger.dart';
import 'download_log_sheet.dart';

/// Per-item overflow actions (view logs, cancel, copy, redownload, audio,
/// remove, delete).
///
/// State-gated so destructive or duplicative work is impossible while the
/// engine holds the id:
/// - Active (downloading/pending/queued): Cancel is the primary action;
///   Redownload/Delete stay disabled with an explanatory message instead of
///   silently colliding (engine rejects with ERROR_ALREADY_ACTIVE backstop).
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
      item.status == 'cancelling' ||
      item.status == 'queued';

  bool get _isTerminal =>
      item.status == 'completed' ||
      item.status == 'error' ||
      item.status == 'cancelled' ||
      item.status == 'interrupted';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final disabledColor = colorScheme.onSurface.withValues(alpha: 0.38);

    return Semantics(
      label: 'More options for ${item.title}',
      button: true,
      child: PopupMenuButton<String>(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.25),
          ),
        ),
        color: colorScheme.surfaceContainerHigh,
        elevation: 3,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
        icon: const Icon(
          Icons.more_horiz_rounded,
          size: 19,
          color: Color(0xFF8C7D73),
        ),
        tooltip: 'More options',
        onSelected: (value) => _onSelected(context, ref, value),
        itemBuilder: (ctx) => [
          PopupMenuItem(
            value: 'view_logs',
            child: Row(
              children: [
                Icon(Icons.terminal, size: 18, color: colorScheme.primary),
                const SizedBox(width: 12),
                const Flexible(
                  child: Text(
                    'View logs',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'cancel_download',
            enabled: _isActive,
            child: Row(
              children: [
                Icon(
                  Icons.cancel_outlined,
                  size: 18,
                  color: _isActive
                      ? colorScheme.error
                      : disabledColor,
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    'Cancel download',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color:
                          _isActive ? colorScheme.error : disabledColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'copy_link',
            enabled: item.url.isNotEmpty,
            child: Row(
              children: [
                Icon(
                  Icons.link,
                  size: 18,
                  color: item.url.isNotEmpty
                      ? colorScheme.primary
                      : disabledColor,
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    'Copy Link',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: item.url.isNotEmpty ? null : disabledColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'redownload',
            enabled: _isTerminal,
            child: Row(
              children: [
                Icon(
                  Icons.refresh,
                  size: 18,
                  color: _isTerminal
                      ? colorScheme.primary
                      : disabledColor,
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    item.status == 'completed'
                        ? 'Redownload'
                        : (item.status == 'interrupted'
                              ? 'Resume download'
                              : 'Retry download'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _isTerminal ? null : disabledColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'audio',
            enabled: !_isActive,
            child: Row(
              children: [
                Icon(
                  Icons.audio_file_outlined,
                  size: 18,
                  color: !_isActive ? colorScheme.primary : disabledColor,
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    'Download audio from source',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: !_isActive ? null : disabledColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'remove_history',
            child: Row(
              children: [
                Icon(Icons.history, size: 18),
                SizedBox(width: 12),
                Flexible(
                  child: Text(
                    'Remove from history',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'delete_file',
            enabled: _isTerminal,
            child: Row(
              children: [
                Icon(
                  Icons.delete_outline,
                  size: 18,
                  color: _isTerminal ? colorScheme.error : disabledColor,
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    'Delete file',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _isTerminal ? colorScheme.error : disabledColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _onSelected(
    BuildContext context,
    WidgetRef ref,
    String value,
  ) async {
    final notifier = ref.read(downloadProvider.notifier);
    switch (value) {
      case 'cancel_download':
        if (!_isActive) {
          _snack(context, 'Nothing to cancel');
          return;
        }
        AppLogger.info(
          'User chose Cancel for ${item.id}',
          tag: 'DownloadOverflow',
        );
        notifier.cancelDownload(item.id);
        _snack(context, 'Cancelling download');
        return;
      case 'copy_link':
        if (item.url.isEmpty) {
          _snack(context, 'No link to copy');
          return;
        }
        AppLogger.info(
          'User chose Copy Link for ${item.id}',
          tag: 'DownloadOverflow',
        );
        await Clipboard.setData(ClipboardData(text: item.url));
        if (!context.mounted) return;
        _snack(context, 'Link copied');
        return;
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
        AppLogger.info(
          'User chose Redownload for ${item.id}',
          tag: 'DownloadOverflow',
        );
        notifier.redownload(item.id, fresh: item.status == 'completed');
        _snack(
          context,
          item.status == 'completed'
              ? 'Re-downloading (fresh fetch)'
              : (item.status == 'interrupted'
                    ? 'Resuming download'
                    : 'Retrying download'),
        );
      case 'audio':
        if (_isActive) {
          _snack(context, 'Cancel the active download first');
          return;
        }
        AppLogger.info(
          'User chose audio-from-source for ${item.id}',
          tag: 'DownloadOverflow',
        );
        final newId = await notifier.downloadAudioFromSource(item.id);
        if (!context.mounted) return;
        _snack(
          context,
          newId == null
              ? 'Could not start audio download'
              : 'Audio download started',
        );
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
        final name =
            item.filePath
                ?.split('/')
                .lastWhere((s) => s.isNotEmpty, orElse: () => '') ??
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
            _snack(
              context,
              ok ? 'File deleted' : 'Could not delete — try again',
            );
          }
        }
    }
  }

  String _shortTitle(String title) =>
      title.length > 60 ? '${title.substring(0, 60)}…' : title;

  void _snack(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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
