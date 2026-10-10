import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../engine/engine_provider.dart';
import 'app_logger.dart';

/// Shows a user-visible notification.
///
/// Prefers a native system notification (NotificationManager) when the
/// permission is granted; otherwise falls back to an in-app SnackBar that
/// is themed (inverseSurface) so it never appears as a white stripe at
/// the bottom. The white-stripe SnackBar (default surface) was reported
/// as visually broken on both light and dark themes.
///
/// [isError] chooses the native channel (error vs success). Never throws.
Future<void> showAppNotification(
  BuildContext context,
  WidgetRef ref, {
  required String message,
  String? title,
  bool isError = false,
  Duration duration = const Duration(seconds: 3),
  SnackBarAction? action,
}) async {
  // Try native first for important messages (errors & completions).
  if (isError || title != null) {
    try {
      final engine = ref.read(engineProvider);
      await engine.showErrorNotification(
        downloadId: 'app_${DateTime.now().millisecondsSinceEpoch}',
        title: title ?? (isError ? 'Notice' : 'Grablytic'),
        error: message,
      );
      // Also log for diagnostics; native may be denied, but we already
      // posted — no need to also SnackBar (would double-notify).
      // For permission-denied we still fall through to SnackBar.
      final status = await engine.notificationPermissionStatus();
      if (status['granted'] == true) return;
    } catch (e) {
      AppLogger.warn('Native notification failed: $e', tag: 'NotificationHelper');
    }
  }

  if (!context.mounted) return;
  final cs = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message, style: TextStyle(color: cs.onInverseSurface)),
      backgroundColor: cs.inverseSurface,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      duration: duration,
      action: action,
    ),
  );
}

/// Styled SnackBar that never shows as a white stripe.
/// Use when a native notification is not appropriate (e.g. quick inline
/// confirmation) but the default SnackBar would be a white bar.
SnackBar styledSnackBar(BuildContext context, String message, {SnackBarAction? action, Duration duration = const Duration(seconds: 3)}) {
  final cs = Theme.of(context).colorScheme;
  return SnackBar(
    content: Text(message, style: TextStyle(color: cs.onInverseSurface)),
    backgroundColor: cs.inverseSurface,
    behavior: SnackBarBehavior.floating,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    duration: duration,
    action: action,
  );
}
