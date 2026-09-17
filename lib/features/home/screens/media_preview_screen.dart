import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/engine/engine_provider.dart';
import '../../../core/theme/text_styles.dart';

class MediaPreviewScreen extends ConsumerWidget {
  final String? filePath;
  final String? title;
  final String? thumbnailUrl;
  final String? duration;
  final String? quality;

  const MediaPreviewScreen({
    super.key,
    this.filePath,
    this.title,
    this.thumbnailUrl,
    this.duration,
    this.quality,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final fileExists = filePath != null && File(filePath!).existsSync();

    FileStat? fileStat;
    String? fileName;
    int? fileSizeBytes;

    if (fileExists) {
      final file = File(filePath!);
      fileStat = file.statSync();
      fileName = filePath!.split('/').last;
      fileSizeBytes = fileStat.size;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Media Preview',
          style: TextStyle(fontFamily: 'InstrumentSans',
            fontWeight: FontWeight.w600,
            color: colorScheme.primary,
          ),
        ),
        centerTitle: true,
        backgroundColor: colorScheme.surface,
        surfaceTintColor: colorScheme.surfaceTint,
      ),
      backgroundColor: colorScheme.surface,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 24),
              if (thumbnailUrl != null && thumbnailUrl!.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(
                    thumbnailUrl!,
                    width: double.infinity,
                    height: 200,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => _thumbnailPlaceholder(colorScheme),
                    loadingBuilder: (_, child, progress) {
                      if (progress == null) return child;
                      return _thumbnailPlaceholder(colorScheme);
                    },
                  ),
                )
              else
                _thumbnailPlaceholder(colorScheme),
              const SizedBox(height: 24),
              Text(
                title ?? fileName ?? 'Unknown',
                style: textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 24),
              _MetadataRow(
                label: duration != null ? 'Duration' : null,
                value: duration,
                colorScheme: colorScheme,
                textTheme: textTheme,
              ),
              if (quality != null) ...[
                const SizedBox(height: 8),
                _MetadataRow(
                  label: 'Quality',
                  value: quality,
                  colorScheme: colorScheme,
                  textTheme: textTheme,
                ),
              ],
              if (fileExists) ...[
                const SizedBox(height: 8),
                _MetadataRow(
                  label: 'Filename',
                  value: fileName,
                  colorScheme: colorScheme,
                  textTheme: textTheme,
                ),
                const SizedBox(height: 8),
                _MetadataRow(
                  label: 'Size',
                  value: _formatBytes(fileSizeBytes ?? 0),
                  colorScheme: colorScheme,
                  textTheme: textTheme,
                ),
                const SizedBox(height: 8),
                _MetadataRow(
                  label: 'Modified',
                  value: fileStat?.modified.toString().substring(0, 19),
                  colorScheme: colorScheme,
                  textTheme: textTheme,
                ),
              ],
              const SizedBox(height: 40),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton.icon(
                  onPressed: () => _openInPlayer(context, ref, filePath),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colorScheme.primary,
                    foregroundColor: colorScheme.onPrimary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  icon: const Icon(Icons.play_arrow_rounded, size: 28),
                  label: Text(
                    fileExists ? 'Open in system player' : 'No file available',
                    style: TextStyle(fontFamily: 'InstrumentSans',
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              if (!fileExists && filePath != null) ...[
                const SizedBox(height: 12),
                Text(
                  'File not found at:\n$filePath',
                  style: textTheme.mono.copyWith(
                    color: colorScheme.error,
                    fontSize: 11,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _thumbnailPlaceholder(ColorScheme colorScheme) {
    return Container(
      width: double.infinity,
      height: 200,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        Icons.movie_outlined,
        size: 64,
        color: colorScheme.outline.withValues(alpha: 0.4),
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1073741824) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
  }

  Future<void> _openInPlayer(
      BuildContext context, WidgetRef ref, String? path) async {
    if (path == null) return;
    if (!File(path).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('File not found'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
      return;
    }

    // Android: system player via FileProvider (MainActivity intent/open_file).
    // Desktop: OS resolver via the engine (xdg-open/open/explorer).
    // Never throws — falls back to showing the path.
    if (Platform.isAndroid) {
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
      return;
    }

    try {
      if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
        bool opened = false;
        try {
          final res = await ref.read(engineProvider).openFile(path);
          opened = res['success'] == true;
        } catch (_) {}
        if (!context.mounted) return;
        if (opened) return;
      }
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Open file at: $path'),
          backgroundColor: Theme.of(context).colorScheme.primary,
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not open file: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }
}

class _MetadataRow extends StatelessWidget {
  final String? label;
  final String? value;
  final ColorScheme colorScheme;
  final TextTheme textTheme;

  const _MetadataRow({
    this.label,
    this.value,
    required this.colorScheme,
    required this.textTheme,
  });

  @override
  Widget build(BuildContext context) {
    if (value == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          if (label != null)
            Text(
              label!,
              style: textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          Flexible(
            child: Text(
              value!,
              style: textTheme.mono.copyWith(
                color: colorScheme.onSurface,
              ),
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
