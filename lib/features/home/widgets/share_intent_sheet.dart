import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/engine_status_provider.dart';
import '../../../core/utils/playlist_selection.dart';
import '../screens/format_picker_screen.dart';
import '../screens/playlist_selection_screen.dart';

/// Share-intent landing sheet (Part A of the share-intent + preview task).
///
/// Shown instead of auto-starting when a URL arrives via `ACTION_SEND` and
/// the `autoStartDownloadOnShare` opt-in is off (the default). This mirrors
/// the YTDLnis/Seal "bottom card" pattern at the Dart layer: confirm-and-edit
/// before acting (per Android's "make great share targets" guidance), while
/// the heavy work (format extraction) stays deferred to [FormatPickerScreen].
///
/// Engine-readiness: the sheet renders instantly and gates its primary
/// action on [engineStatusProvider] — a "still setting up" state rather
/// than a broken/empty sheet when the engine isn't ready yet.
class ShareIntentSheet extends ConsumerWidget {
  final String url;

  const ShareIntentSheet({super.key, required this.url});

  void _continueToPicker(BuildContext context) {
    final navigator = Navigator.of(context);
    navigator.pop();
    // Playlist URLs get entry selection (03-B) instead of the
    // single-video format picker.
    final target = isPlaylistUrl(url)
        ? PlaylistSelectionScreen(url: url, title: url)
        : FormatPickerScreen(url: url, title: url);
    navigator.push(
      MaterialPageRoute(builder: (_) => target),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statusAsync = ref.watch(engineStatusProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final isSettingUp = statusAsync.isLoading;
    final ready = statusAsync.maybeWhen(
      data: (s) => s.ready && s.error == null,
      orElse: () => false,
    );
    final statusError = statusAsync.maybeWhen(
      data: (s) => s.error,
      orElse: () => null,
    );

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Shared link',
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(height: 8),
            Semantics(
              label: 'Shared URL: $url',
              child: Text(
                url,
                style: textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: colorScheme.onSurfaceVariant,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 12),
            if (isSettingUp)
              Semantics(
                label: 'Engine still setting up',
                child: Row(
                  children: [
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Setting up the engine — quality choices unlock when ready.',
                        style: textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              )
            else if (!ready)
              Semantics(
                label: 'Engine not ready',
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 20,
                      color: colorScheme.error,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        statusError ?? 'Engine is not ready yet — try again shortly.',
                        style: textTheme.bodySmall?.copyWith(
                          color: colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: Semantics(
                button: true,
                label: 'Choose quality and download',
                child: ElevatedButton(
                  onPressed:
                      ready ? () => _continueToPicker(context) : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colorScheme.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('Choose quality & download'),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Center(
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Not now'),
              ),
            ),
            Center(
              child: Text(
                'Tip: enable auto-start in Settings to skip this sheet.',
                style: textTheme.labelSmall?.copyWith(
                  color: colorScheme.outline,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Presents the share-intent sheet. Returns the [showModalBottomSheet]
/// future so callers can chain on dismissal when needed.
Future<T?> showShareIntentSheet<T>(BuildContext context, String url) {
  final colorScheme = Theme.of(context).colorScheme;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: colorScheme.surfaceContainerLowest,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => ShareIntentSheet(url: url),
  );
}
