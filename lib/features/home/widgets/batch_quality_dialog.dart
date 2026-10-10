library;
import 'package:flutter/material.dart';

/// Batch quality picker: one quality choice for an entire batch.
///
/// Shown before a batch starts ([showBatchQualityDialog]); the chosen
/// ceiling is snapshotted into [BatchState] so every item downloads at the
/// same quality even if the global preset changes mid-queue. The choice is
/// persisted under [lastBatchQualityKey] so the next batch starts from the
/// previous pick (per-batch override stays possible every time).

/// Quality options offered for a batch, in order (highest first).
const List<String> batchQualityOptions = ['best', '1080p', '720p', '480p'];

/// SharedPreferences key for the last batch quality pick.
const String lastBatchQualityKey = 'lastBatchQualityCeiling';

/// Human label for a batch quality value.
String batchQualityLabel(String ceiling) {
  switch (ceiling) {
    case '480p':
      return '480p · Data Saver';
    case '720p':
      return '720p · HD';
    case '1080p':
      return '1080p · Full HD';
    case 'best':
      return 'Best Available';
    default:
      return ceiling;
  }
}

/// Normalize any stored/preset ceiling to a dialog option.
///
/// Unknown values (e.g. the global '4k' preset, custom ceilings) fall back
/// to 'best': uncapped is the closest batch semantic to a 4K ceiling for
/// short-form sources, and it is portrait-safe by construction.
String normalizeBatchCeiling(String? ceiling) {
  if (ceiling != null && batchQualityOptions.contains(ceiling)) return ceiling;
  return 'best';
}

/// Shows the one-time batch quality dialog.
///
/// Returns the chosen ceiling, or null when the user cancels (caller must
/// not start the batch in that case).
Future<String?> showBatchQualityDialog({
  required BuildContext context,
  required String initialCeiling,
  required int itemCount,
}) {
  var selected = normalizeBatchCeiling(initialCeiling);
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Batch quality'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'One quality for all $itemCount items. Portrait reels stay video at every option.',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              RadioGroup<String>(
                groupValue: selected,
                onChanged: (v) {
                  if (v != null) setState(() => selected = v);
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final option in batchQualityOptions)
                      RadioListTile<String>(
                        key: Key('batch-quality-$option'),
                        title: Text(batchQualityLabel(option)),
                        value: option,
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const Key('batch-quality-cancel'),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('batch-quality-start'),
            onPressed: () => Navigator.pop(ctx, selected),
            child: const Text('Start'),
          ),
        ],
      ),
    ),
  );
}
