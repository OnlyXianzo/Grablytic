import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../core/utils/trust_boundary.dart';

/// Media-storage meter (FEATURE 6): read-mostly usage readout for the
/// download folder plus a top-10 largest-files list with safe per-file
/// delete (confirm dialog, path-containment guarded).
///
/// - Scanning is async and cached ([_scan] future); refresh re-scans.
/// - Missing/unreadable folders degrade to an "unavailable" line, never
///   throw into the settings screen.
/// - Deletes are single-file, user-confirmed, and confined to
///   [downloadPath] via [isPathWithinDir].

/// Human-readable byte count. Pure — unit-tested.
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = value >= 100 || unit == 0
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}

/// One scanned media file entry. Pure value — unit-tested.
class StorageFileEntry {
  final String path;
  final int sizeBytes;

  const StorageFileEntry({required this.path, required this.sizeBytes});

  String get name => p.basename(path);
}

/// Result of scanning a download folder. Pure value — unit-tested.
class StorageScan {
  final bool exists;
  final int totalBytes;
  final int fileCount;
  final List<StorageFileEntry> largest;

  const StorageScan({
    required this.exists,
    required this.totalBytes,
    required this.fileCount,
    required this.largest,
  });

  const StorageScan.missing()
      : exists = false,
        totalBytes = 0,
        fileCount = 0,
        largest = const [];
}

/// Recursively sums file sizes under [dir], returning the [topN] largest
/// files. Never throws: missing folders yield [StorageScan.missing],
/// per-entry errors are skipped. Pure I/O helper — unit-tested.
Future<StorageScan> scanMediaStorage(Directory dir, {int topN = 10}) async {
  bool exists = false;
  try {
    exists = await dir.exists();
  } catch (_) {
    return const StorageScan.missing();
  }
  if (!exists) return const StorageScan.missing();

  var total = 0;
  var count = 0;
  final entries = <StorageFileEntry>[];
  try {
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      try {
        if (entity is File) {
          final size = await entity.length();
          total += size;
          count++;
          entries.add(StorageFileEntry(path: entity.path, sizeBytes: size));
        }
      } catch (_) {
        // Skip unreadable entries — meter stays best-effort.
      }
    }
  } catch (_) {
    // Directory became unreadable mid-scan — report what we have.
  }
  entries.sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes));
  return StorageScan(
    exists: true,
    totalBytes: total,
    fileCount: count,
    largest: entries.take(topN).toList(),
  );
}

/// Deletes a single media file, confined to [baseDir]. Returns true on
/// success. Never throws; refuses paths outside [baseDir].
Future<bool> deleteMediaFile(String filePath, String baseDir) async {
  try {
    final normalized = p.normalize(p.absolute(filePath));
    if (!isPathWithinDir(normalized, baseDir)) return false;
    final file = File(normalized);
    if (!await file.exists()) return false;
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) return false;
    await file.delete();
    return true;
  } catch (_) {
    return false;
  }
}

/// Settings row card showing download-folder usage and the largest files.
class StorageMeterCard extends StatefulWidget {
  final String downloadPath;

  /// Test seams (default to the real implementations). Widget tests run in
  /// a FakeAsync zone where real disk I/O futures never resolve, so tests
  /// inject scripted results here instead of depending on timing; the real
  /// [scanMediaStorage]/[deleteMediaFile] stay covered by plain unit tests.
  final Future<StorageScan> Function(Directory dir)? scanForTesting;
  final Future<bool> Function(String filePath, String baseDir)?
      deleteForTesting;

  const StorageMeterCard({
    super.key,
    required this.downloadPath,
    this.scanForTesting,
    this.deleteForTesting,
  });

  @override
  State<StorageMeterCard> createState() => _StorageMeterCardState();
}

class _StorageMeterCardState extends State<StorageMeterCard> {
  Future<StorageScan>? _scan;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    _rescan();
  }

  @override
  void didUpdateWidget(covariant StorageMeterCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.downloadPath != widget.downloadPath) _rescan();
  }

  void _rescan() {
    final scan = widget.scanForTesting ?? scanMediaStorage;
    setState(() {
      _scan = scan(Directory(widget.downloadPath));
    });
  }

  Future<void> _confirmAndDelete(StorageFileEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Delete file?'),
        content: Text(
          '${entry.name} (${formatBytes(entry.sizeBytes)})\n\n'
          'This only deletes this file. The download history entry is kept, '
          'so a re-download stays skipped unless you clear it from history.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _deleting = true);
    final delete = widget.deleteForTesting ?? deleteMediaFile;
    final ok = await delete(entry.path, widget.downloadPath);
    if (!mounted) return;
    setState(() => _deleting = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not delete that file')),
      );
      return;
    }
    _rescan();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(Icons.storage_outlined,
                    color: colorScheme.primary, size: 20),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Media storage', style: textTheme.bodyLarge),
                    FutureBuilder<StorageScan>(
                      future: _scan,
                      builder: (context, snapshot) {
                        final scan = snapshot.data;
                        final subtitle = !snapshot.hasData
                            ? 'Measuring…'
                            : !scan!.exists
                                ? 'Folder unavailable'
                                : '${formatBytes(scan.totalBytes)} in '
                                    '${scan.fileCount} files';
                        return Text(
                          subtitle,
                          style: textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            fontFeatures: const [
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Refresh storage meter',
                onPressed: _rescan,
                icon: const Icon(Icons.refresh_outlined),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // "Open folder" info: scoped storage offers no guaranteed file
          // manager intent, so the path itself is the actionable info.
          Semantics(
            label: 'Download folder, ${widget.downloadPath}',
            child: Text(
              widget.downloadPath,
              style: textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          FutureBuilder<StorageScan>(
            future: _scan,
            builder: (context, snapshot) {
              final scan = snapshot.data;
              if (!snapshot.hasData || scan == null || !scan.exists) {
                return const SizedBox.shrink();
              }
              if (scan.largest.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Folder is empty.',
                    style: textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                );
              }
              return Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Largest files',
                      style: textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    for (final entry in scan.largest)
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              entry.name,
                              style: textTheme.labelSmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            formatBytes(entry.sizeBytes),
                            style: textTheme.labelSmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'Delete file',
                            visualDensity: VisualDensity.compact,
                            onPressed: _deleting
                                ? null
                                : () => _confirmAndDelete(entry),
                            icon: Icon(
                              Icons.delete_outline,
                              size: 18,
                              color: colorScheme.error,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
