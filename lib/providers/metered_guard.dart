import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/engine/engine_provider.dart';
import '../core/utils/app_logger.dart';
import 'settings_provider.dart';

/// Seal-grounded metered gate for explicit user taps.
///
/// Seal ships this as `CELLULAR_DOWNLOAD || !isActiveNetworkMetered`
/// (default: Wi-Fi-only). Here the Wi-Fi Only setting plays the
/// `CELLULAR_DOWNLOAD` role with matching polarity (`allowed =
/// !wifiOnly || !metered`):
///
/// - Wi-Fi Only off → `true`, no UI (tap is tap).
/// - Unmetered link → `true`, no UI.
/// - Metered link → confirm dialog (`Download` / `Wait`), honoring the
///   choice. Dismissal counts as `Wait`.
/// - Engine verdict unreadable (dead activity, timeout) → treated as
///   metered: prompt the user rather than silently spending data.
///
/// Single choke point: every UI admission path calls this before
/// `engine.startDownload`. Unattended auto-resume has its own silent
/// gate in `DownloadNotifier.unattendedNetworkAllowed` (no dialogs
/// from background work).
Future<bool> ensureUnmeteredDownload({
  required BuildContext context,
  required WidgetRef ref,
}) async {
  if (!ref.read(settingsProvider).wifiOnly) return true;

  bool metered;
  try {
    final verdict = await ref
        .read(engineProvider)
        .networkMeteredStatus()
        .timeout(const Duration(seconds: 3));
    metered = verdict['metered'] != false;
  } catch (e) {
    AppLogger.warn('Metered check failed ($e); asking the user',
        tag: 'metered-guard');
    metered = true;
  }
  if (!metered) return true;
  if (!context.mounted) return false;

  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('On mobile data'),
      content: const Text(
        'Wi-Fi Only is on and this connection looks metered.\n\n'
        'Download now anyway?',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Wait'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Download'),
        ),
      ],
    ),
  );
  return result ?? false;
}
