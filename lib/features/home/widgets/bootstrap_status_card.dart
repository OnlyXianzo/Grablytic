import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../../providers/engine_status_provider.dart';
import '../../../core/theme/text_styles.dart';

class BootstrapStatusCard extends ConsumerWidget {
  const BootstrapStatusCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statusAsync = ref.watch(engineStatusProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return statusAsync.when(
      loading: () => _buildLoadingCard(colorScheme, textTheme),
      error: (err, _) => _buildErrorCard(err.toString(), colorScheme, textTheme),
      data: (status) {
        if (status.error != null) {
          return _buildErrorCard(status.error!, colorScheme, textTheme);
        }
        if (status.allBinariesOk) {
          return _buildCompactReadyRow(status, colorScheme, textTheme);
        }
        return _buildBinaryList(status, colorScheme, textTheme);
      },
    );
  }

  Widget _buildLoadingCard(ColorScheme colorScheme, TextTheme textTheme) {
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: colorScheme.outlineVariant.withAlpha(40),
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colorScheme.primary,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            'Checking engine binaries...',
            style: textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactReadyRow(
      EngineStatus status, ColorScheme colorScheme, TextTheme textTheme) {
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: colorScheme.outlineVariant.withAlpha(40),
        ),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Icon(Icons.check_circle, size: 18, color: colorScheme.tertiary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'All binaries ready',
              style: textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurface,
              ),
            ),
          ),
          if (status.ytDlpVersion != null)
            Text(
              'yt-dlp ${status.ytDlpVersion}',
              style: textTheme.mono.copyWith(
                color: colorScheme.outline,
                fontSize: 11,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildErrorCard(
      String error, ColorScheme colorScheme, TextTheme textTheme) {
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.errorContainer.withAlpha(30),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: colorScheme.error.withAlpha(60),
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: colorScheme.error, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              error,
              style: textTheme.bodySmall
                  ?.copyWith(color: colorScheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBinaryList(
      EngineStatus status, ColorScheme colorScheme, TextTheme textTheme) {
    BinaryStatus lookup(String name, BinaryStatus fallback) {
      if (status.binaries.isEmpty) return fallback;
      return status.binaries.firstWhere(
        (b) => b.name == name,
        orElse: () => fallback,
      );
    }

    final ytDlp = lookup(
        'yt-dlp',
        BinaryStatus(
            name: 'yt-dlp',
            ok: status.ytDlpVersion != null,
            version: status.ytDlpVersion));
    final ffmpeg = lookup(
        'ffmpeg',
        BinaryStatus(
            name: 'ffmpeg', ok: status.ffmpegOk, version: status.ffmpegVersion));
    final aria2c = lookup(
        'aria2c',
        BinaryStatus(
            name: 'aria2c', ok: status.aria2cOk, version: status.aria2cVersion));
    // Effective JS runtime — never a hardcoded phantom. On Android this is
    // the bundled Deno (not QuickJS, which has no Chaquopy wheel).
    final jsName = status.jsRuntime != null && status.jsRuntime != 'none'
        ? status.jsRuntime!
        : (Platform.isAndroid ? 'QuickJS' : 'Deno');
    final jsRecord = lookup(
        jsName,
        BinaryStatus(
            name: jsName,
            ok: status.jsRuntimeOk,
            version:
                status.jsRuntimeOk ? status.jsRuntimeVersion : null));
    final binaries = [
      _BinaryInfo(
          name: 'yt-dlp',
          ok: ytDlp.ok,
          version: ytDlp.version,
          source: ytDlp.source,
          detail: ytDlp.detail),
      _BinaryInfo(
          name: 'FFmpeg',
          ok: ffmpeg.ok,
          version: ffmpeg.version,
          source: ffmpeg.source,
          detail: ffmpeg.detail),
      _BinaryInfo(
          name: 'aria2c',
          ok: aria2c.ok,
          version: aria2c.version,
          source: aria2c.source,
          detail: aria2c.detail,
          optional: true),
      _BinaryInfo(
          name: 'JS · $jsName',
          ok: jsRecord.ok,
          version: jsRecord.version,
          source: jsRecord.source,
          detail: jsRecord.detail,
          optional: !jsRecord.ok && !jsRecord.isActionable),
    ];

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: colorScheme.outlineVariant.withAlpha(40),
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.download_done, size: 18, color: colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                'Engine Binaries',
                style: textTheme.labelLarge?.copyWith(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          if (status.ytDlpOutdated) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.warning_amber,
                    size: 14, color: colorScheme.error),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'yt-dlp is outdated — update for security fixes',
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.error,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          ...binaries.asMap().entries.map((entry) {
            final index = entry.key;
            final binary = entry.value;
            return _BinaryRow(
              binary: binary,
              colorScheme: colorScheme,
              textTheme: textTheme,
            )
                .animate()
                .fadeIn(
                    delay: Duration(milliseconds: index * 80),
                    duration: 300.ms)
                .slideX(begin: 0.1, curve: Curves.easeOutCubic);
          }),
          if (status.jsRuntime != null) ...[
            const SizedBox(height: 8),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHigh.withAlpha(80),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.code, size: 12, color: colorScheme.outline),
                  const SizedBox(width: 4),
                  Text(
                    'JS runtime: ${status.jsRuntime}${status.jsRuntimeVersion != null ? ' ${status.jsRuntimeVersion}' : ''}',
                    style: textTheme.mono.copyWith(
                      fontSize: 10,
                      color: colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _BinaryInfo {
  final String name;
  final bool ok;
  final String? version;
  /// Provenance: bundled | downloaded | system | runtime | unsupported |
  /// missing | unknown (legacy engines).
  final String source;
  /// Short guidance when not ok (or null for paths, which stay hidden).
  final String? detail;
  /// When true and not ok, shows 'pending' with a neutral icon instead of error red.
  final bool optional;

  const _BinaryInfo({
    required this.name,
    required this.ok,
    this.version,
    this.source = 'unknown',
    this.detail,
    this.optional = false,
  });

  String get sourceLabel {
    switch (source) {
      case 'bundled':
        return 'Bundled';
      case 'downloaded':
        return 'Downloaded';
      case 'system':
        return 'System';
      case 'runtime':
        return 'Runtime';
      case 'unsupported':
        return 'Unavailable';
      case 'missing':
        return 'Missing';
      default:
        return '';
    }
  }

  /// Subtitle: source chip when known, replaced by short guidance when
  /// something is wrong (long filesystem paths are never shown).
  String? get subtitle {
    if (!ok && detail != null && detail!.length < 120) return detail;
    if (sourceLabel.isNotEmpty) return sourceLabel;
    return null;
  }
}

class _BinaryRow extends StatelessWidget {
  final _BinaryInfo binary;
  final ColorScheme colorScheme;
  final TextTheme textTheme;

  const _BinaryRow({
    required this.binary,
    required this.colorScheme,
    required this.textTheme,
  });

  @override
  Widget build(BuildContext context) {
    // For optional binaries that are missing, show neutral 'pending' state
    final isOptionalMissing = binary.optional && !binary.ok;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            binary.ok
                ? Icons.check_circle
                : (isOptionalMissing ? Icons.hourglass_empty : Icons.cancel),
            size: 16,
            color: binary.ok
                ? colorScheme.tertiary
                : (isOptionalMissing ? colorScheme.outline : colorScheme.error),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  binary.name,
                  style: textTheme.bodyMedium
                      ?.copyWith(color: colorScheme.onSurface),
                ),
                if (binary.subtitle != null)
                  Text(
                    binary.subtitle!,
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.outline,
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ),
          if (binary.version != null)
            Text(
              binary.version!,
              style: textTheme.mono.copyWith(
                color: colorScheme.outline,
                fontSize: 11,
              ),
            )
          else
            Text(
              binary.ok ? 'installed' : (isOptionalMissing ? 'pending' : 'missing'),
              style: textTheme.mono.copyWith(
                color: binary.ok
                    ? colorScheme.tertiary
                    : (isOptionalMissing ? colorScheme.outline : colorScheme.error),
                fontSize: 11,
              ),
            ),
        ],
      ),
    );
  }
}