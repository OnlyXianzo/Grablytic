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
    final binaries = [
      _BinaryInfo(
        name: 'yt-dlp',
        ok: status.ytDlpVersion != null,
        version: status.ytDlpVersion,
      ),
      _BinaryInfo(
        name: 'FFmpeg',
        ok: status.ffmpegOk,
        version: status.ffmpegVersion,
      ),
      _BinaryInfo(
        name: 'aria2c',
        ok: status.aria2cOk,
        version: status.aria2cVersion,
      ),
      _BinaryInfo(
        name: 'Deno',
        ok: status.denoOk,
        version: status.denoVersion,
      ),
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

  const _BinaryInfo({
    required this.name,
    required this.ok,
    this.version,
  });
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            binary.ok ? Icons.check_circle : Icons.cancel,
            size: 16,
            color: binary.ok ? colorScheme.tertiary : colorScheme.error,
          ),
          const SizedBox(width: 8),
          Text(
            binary.name,
            style: textTheme.bodyMedium
                ?.copyWith(color: colorScheme.onSurface),
          ),
          const Spacer(),
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
              binary.ok ? 'installed' : 'missing',
              style: textTheme.mono.copyWith(
                color:
                    binary.ok ? colorScheme.tertiary : colorScheme.error,
                fontSize: 11,
              ),
            ),
        ],
      ),
    );
  }
}