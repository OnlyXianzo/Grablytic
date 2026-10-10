import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../engine/engine_provider.dart';
import 'app_logger.dart';

/// Shows a user-visible notification.
///
/// With [title] supplied or [isError] true, attempts a native notification if
/// the engine reports permission granted. [isError] selects the error
/// notification, using "Notice" when no title is supplied.
///
/// Otherwise, or if checking/posting throws, shows a floating SnackBar using
/// inverse surface colors while [context] is mounted. [duration] and [action]
/// apply only to that SnackBar. A normally completed native call suppresses
/// the fallback even if the engine silently skips posting. Errors from the
/// SnackBar fallback propagate; it requires a ScaffoldMessenger and Scaffold.
Future<void> showAppNotification(
  BuildContext context,
  WidgetRef ref, {
  required String message,
  String? title,
  bool isError = false,
  Duration duration = const Duration(seconds: 3),
  SnackBarAction? action,
}) async {
  // Prefer native when we have a meaningful title/message and the
  // permission is granted (Android 13+). Check first to avoid
  // SecurityException and double-notify. Pre-33 areNotificationsEnabled
  // is true if the channel is enabled.
  if (title != null || isError) {
    try {
      final engine = ref.read(engineProvider);
      final perm = await engine.notificationPermissionStatus();
      final granted = perm['granted'] == true;
      // On <33 granted is always true (compat path); still gate on
      // areNotificationsEnabled for channel-disabled case.
      if (granted) {
        if (isError) {
          await engine.showErrorNotification(
            downloadId: 'app_${DateTime.now().millisecondsSinceEpoch}',
            title: title ?? 'Notice',
            error: message,
          );
        } else {
          await engine.showSuccessNotification(
            downloadId: 'app_${DateTime.now().millisecondsSinceEpoch}',
            title: title ?? 'Grablytic',
            message: message,
          );
        }
        return;
      }
      // Not granted → fall through to styled SnackBar (no native fire)
    } catch (e) {
      AppLogger.warn('Native check/post failed: $e', tag: 'NotificationHelper');
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

/// Creates a floating SnackBar using the theme's inverse surface colors.
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
