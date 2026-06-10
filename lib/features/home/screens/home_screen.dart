import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../../core/theme/text_styles.dart';
import '../../../providers/download_provider.dart';
import '../../../providers/engine_status_provider.dart';
import '../../../providers/resume_provider.dart';
import '../screens/format_picker_screen.dart';
import '../../../features/settings/screens/cookie_webview_screen.dart';
import '../../../features/settings/screens/settings_screen.dart';
import 'batch_import_dialog.dart';
import '../widgets/error_recovery_card.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloads = ref.watch(downloadProvider);
    final recentDownloads = downloads.take(3).toList();
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 24),
              // Engine status
              _EngineStatusBanner(colorScheme: colorScheme, textTheme: textTheme),
              const SizedBox(height: 24),
              // Hero section
              _HeroSection(colorScheme: colorScheme)
                  .animate()
                  .fadeIn(duration: 400.ms)
                  .slideY(begin: 0.2, curve: Curves.easeOutCubic),
              const SizedBox(height: 32),
              // URL input
              _UrlInput(colorScheme: colorScheme)
                  .animate()
                  .fadeIn(delay: 200.ms, duration: 400.ms)
                  .slideY(begin: 0.15, curve: Curves.easeOutCubic),
              const _ResumeScanSection(),
              const SizedBox(height: 40),
              // Your Library header
              if (recentDownloads.isNotEmpty) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Your Library',
                    style: textTheme.titleMedium?.copyWith(
                      color: colorScheme.primary,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // Download cards
                ...recentDownloads.expand((item) {
                  final tiles = <Widget>[
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: _DownloadCard(
                        item: item,
                        colorScheme: colorScheme,
                      ),
                    ),
                  ];
                  if (item.status == 'error') {
                    tiles.add(
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: ErrorRecoveryCard(
                          errorType: item.errorType,
                          errorMessage: item.errorMessage,
                          onRetry: () {
                            ref.read(downloadProvider.notifier).retryDownload(item.id);
                          },
                          onOpenCookies: () {
                            final siteName = _deriveSiteName(item.url);
                            final loginUrl = _deriveLoginUrl(item.url);
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => CookieWebViewScreen(
                                  loginUrl: loginUrl,
                                  siteName: siteName,
                                ),
                              ),
                            );
                          },
                          onOpenProxy: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const SettingsScreen(),
                              ),
                            );
                          },
                          onPickFormat: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => FormatPickerScreen(
                                  url: item.url,
                                  title: item.title,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    );
                  }
                  return tiles;
                }),
              ]               else ...[
                const SizedBox(height: 60),
                Semantics(
                  label: 'No downloads',
                  child: Icon(
                    Icons.cloud_download_outlined,
                    size: 48,
                    color: colorScheme.outline.withValues(alpha: 0.4),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'No downloads yet',
                  style: textTheme.bodyLarge?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Paste a link above to get started',
                  style: textTheme.bodyMedium?.copyWith(
                    color: colorScheme.outline,
                  ),
                ),
              ],
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeroSection extends StatelessWidget {
  final ColorScheme colorScheme;
  const _HeroSection({required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 120,
          height: 120,
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: colorScheme.outlineVariant.withValues(alpha: 0.2),
            ),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Semantics(
                label: 'TrueStream download icon',
                child: Icon(
                  Icons.cloud_download_outlined,
                  size: 64,
                  color: colorScheme.outline,
                ),
              ),
              Positioned(
                bottom: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Semantics(
                    label: 'Search sources',
                    child: Icon(
                      Icons.search,
                      size: 18,
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Every source. Maximum quality.',
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _UrlInput extends ConsumerStatefulWidget {
  final ColorScheme colorScheme;
  const _UrlInput({required this.colorScheme});

  @override
  ConsumerState<_UrlInput> createState() => _UrlInputState();
}

class _UrlInputState extends ConsumerState<_UrlInput> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submitUrl() {
    final url = _controller.text.trim();
    if (url.isEmpty) return;
    _focusNode.unfocus();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FormatPickerScreen(
          url: url,
          title: url,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String?>(sharedUrlProvider, (previous, next) {
      if (next != null && next.isNotEmpty) {
        _controller.text = next;
        _focusNode.requestFocus();
        ref.read(sharedUrlProvider.notifier).state = null;
      }
    });
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: widget.colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
        color: widget.colorScheme.surfaceContainerLowest,
      ),
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                decoration: InputDecoration(
                  hintText: 'Enter link......',
                  hintStyle: TextStyle(
                    color: widget.colorScheme.outline.withValues(alpha: 0.4),
                  ),
                  border: InputBorder.none,
                  isDense: true,
                ),
                style: Theme.of(context).textTheme.bodyMedium,
                onSubmitted: (_) => _submitUrl(),
              ),
            ),
          ),
          Semantics(
            button: true,
            label: 'Batch import URLs',
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Material(
                color: widget.colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => showDialog(
                    context: context,
                    builder: (_) => const BatchImportDialog(),
                  ),
                  child: Container(
                    width: 48,
                    height: 48,
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.dashboard_customize,
                      color: widget.colorScheme.onSurfaceVariant,
                      size: 20,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          Semantics(
            button: true,
            label: 'Submit URL',
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Material(
                color: widget.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: _submitUrl,
                  child: Container(
                    width: 48,
                    height: 48,
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.link,
                      color: widget.colorScheme.onPrimaryContainer,
                      size: 20,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DownloadCard extends StatelessWidget {
  final DownloadItem item;
  final ColorScheme colorScheme;

  const _DownloadCard({required this.item, required this.colorScheme});

  void _showVpnDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colorScheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.vpn_lock, color: colorScheme.error, size: 24),
            const SizedBox(width: 12),
            Text('Restricted Content',
                style: Theme.of(ctx).textTheme.titleMedium),
          ],
        ),
        content: Text(
          'This content may be blocked in your region.\n\n'
          'Try using a VPN or proxy to bypass network restrictions.',
          style: Theme.of(ctx).textTheme.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDownloading = item.status == 'downloading';
    final isError = item.status == 'error';
    final textTheme = Theme.of(context).textTheme;

    return Semantics(
      button: isError && item.suggestsVpn,
      label: isError && item.suggestsVpn ? '${item.title} - VPN suggested. Tap for details.' : item.title,
      child: GestureDetector(
        onTap: isError && item.suggestsVpn
            ? () => _showVpnDialog(context)
            : null,
        child: Container(
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isError
                  ? colorScheme.error.withValues(alpha: 0.4)
                  : colorScheme.outlineVariant.withValues(alpha: 0.2),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: isDownloading
                      ? Stack(
                          alignment: Alignment.center,
                          children: [
                            Semantics(
                              label: 'Downloading',
                              child: Icon(
                                Icons.downloading,
                                color: colorScheme.primary,
                                size: 32,
                              ),
                            ),
                          ],
                        )
                      : Semantics(
                          label: isError ? 'Error' : 'Completed',
                          child: Icon(
                              isError ? Icons.error_outline : Icons.image_outlined,
                              color: isError
                                  ? colorScheme.error
                                  : colorScheme.outline.withValues(alpha: 0.5),
                              size: 32,
                            ),
                        ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              item.title,
                              style: textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Semantics(
                            label: 'More options',
                            child: Icon(
                              Icons.more_vert,
                              size: 18,
                              color: colorScheme.outline.withValues(alpha: 0.6),
                            ),
                          ),
                        ],
                      ),
                    if (isDownloading) ...[
                      const SizedBox(height: 4),
                      Text(
                        '${_formatBytes(item.downloadedBytes)} / ${_formatBytes(item.totalBytes)}',
                        style: textTheme.mono.copyWith(
                          color: colorScheme.outline,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Text(
                            '${(item.progress * 100).toInt()} % downloading',
                            style: textTheme.mono.copyWith(
                              fontWeight: FontWeight.bold,
                              color: colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: item.progress,
                          backgroundColor: colorScheme.surfaceContainerHighest,
                          valueColor: AlwaysStoppedAnimation(
                              colorScheme.primaryContainer),
                          minHeight: 4,
                        ),
                      ),
                    ] else if (isError) ...[
                      const SizedBox(height: 8),
                      Text(
                        item.errorMessage ?? 'Download failed',
                        style: textTheme.mono.copyWith(
                          color: colorScheme.error,
                          fontSize: 11,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (item.suggestsVpn) ...[
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Icon(Icons.vpn_lock,
                                size: 14, color: colorScheme.error),
                            const SizedBox(width: 4),
                            Text(
                              'Try VPN or proxy',
                              style: textTheme.labelSmall?.copyWith(
                                color: colorScheme.error,
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ] else ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          if (item.fileSize != null)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: colorScheme.surfaceContainerHigh,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                item.fileSize!,
                                style: textTheme.mono.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: colorScheme.onSurfaceVariant,
                                  fontSize: 10,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                          const Spacer(),
                          Semantics(
                            label: 'Download complete',
                            child: Icon(
                              Icons.check_circle,
                              color: colorScheme.primary,
                              size: 20,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / 1048576).toStringAsFixed(1)} MB';
  }
}

class _EngineStatusBanner extends ConsumerWidget {
  final ColorScheme colorScheme;
  final TextTheme textTheme;

  const _EngineStatusBanner({required this.colorScheme, required this.textTheme});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statusAsync = ref.watch(engineStatusProvider);

    return statusAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (status) {
        final message = status.statusMessage;
        if (message == null) return const SizedBox.shrink();

        final hasError = status.error != null;

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: hasError
                ? colorScheme.errorContainer
                : colorScheme.tertiaryContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Semantics(
            label: hasError ? 'Engine error: $message' : 'Engine status: $message',
            child: Row(
              children: [
                Semantics(
                  label: hasError ? 'Warning' : 'Update',
                  child: Icon(
                    hasError ? Icons.warning_amber : Icons.system_update,
                    size: 16,
                    color: hasError
                        ? colorScheme.onErrorContainer
                        : colorScheme.onTertiaryContainer,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    message,
                    style: textTheme.labelSmall?.copyWith(
                      color: hasError
                          ? colorScheme.onErrorContainer
                          : colorScheme.onTertiaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ResumeScanSection extends ConsumerWidget {
  const _ResumeScanSection();

  String _formatAge(int seconds) {
    if (seconds < 60) return '${seconds}s ago';
    final minutes = seconds ~/ 60;
    if (minutes < 60) return '${minutes}m ago';
    final hours = minutes ~/ 60;
    if (hours < 24) return '${hours}h ago';
    final days = hours ~/ 24;
    return '${days}d ago';
  }

  String _formatSize(int bytes) {
    final double mb = bytes / (1024 * 1024);
    if (mb > 1024) {
      return '${(mb / 1024).toStringAsFixed(1)} GB';
    }
    return '${mb.toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resumeState = ref.watch(resumeProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return resumeState.when(
      data: (candidates) {
        if (candidates.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 24),
            Text(
              'INTERRUPTED DOWNLOADS',
              style: textTheme.labelSmall?.copyWith(
                color: colorScheme.primary,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
              ),
            ),
            const SizedBox(height: 8),
            ...candidates.map((candidate) {
              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: colorScheme.outlineVariant.withValues(alpha: 0.3),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Semantics(
                          label: candidate.expired ? 'Expired' : 'Interrupted',
                          child: Icon(
                            Icons.warning_amber_rounded,
                            color: candidate.expired ? colorScheme.error : colorScheme.secondary,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                candidate.filename,
                                style: textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${_formatSize(candidate.sizeBytes)} · ${_formatAge(candidate.ageSeconds)}',
                                style: textTheme.labelSmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (candidate.expired) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: colorScheme.errorContainer.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: colorScheme.error.withValues(alpha: 0.2),
                          ),
                        ),
                        child: Row(
                          children: [
                            Semantics(
                              label: 'Expired',
                              child: Icon(Icons.timer_off_outlined, color: colorScheme.error, size: 16),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Stream URLs may have expired.',
                                style: textTheme.labelSmall?.copyWith(
                                  color: colorScheme.onErrorContainer,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () {
                            ref.read(resumeProvider.notifier).dismiss(candidate);
                          },
                          style: TextButton.styleFrom(
                            foregroundColor: colorScheme.outline,
                          ),
                          child: const Text('Dismiss'),
                        ),
                        const SizedBox(width: 8),
                        if (candidate.likelyUrl != null && !candidate.expired) ...[
                          ElevatedButton(
                            onPressed: () {
                              ref.read(sharedUrlProvider.notifier).state = candidate.likelyUrl;
                              ref.read(resumeProvider.notifier).removeCandidateFromList(candidate);
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: colorScheme.primary,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            child: const Text('Resume'),
                          ),
                        ] else ...[
                          OutlinedButton(
                            onPressed: () {
                              if (candidate.likelyUrl != null) {
                                ref.read(resumeProvider.notifier).deleteFileOnly(candidate);
                                ref.read(sharedUrlProvider.notifier).state = candidate.likelyUrl;
                              } else {
                                ref.read(resumeProvider.notifier).deleteFileOnly(candidate);
                              }
                            },
                            style: OutlinedButton.styleFrom(
                              foregroundColor: colorScheme.primary,
                              side: BorderSide(color: colorScheme.primary),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            child: const Text('Retry'),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              );
            }),
          ],
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
    );
  }
}

String _deriveSiteName(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return 'Unknown';
  final host = uri.host.replaceFirst('www.', '');
  if (host.contains('youtube') || host.contains('youtu.be')) return 'YouTube';
  if (host.contains('twitter') || host.contains('x.com')) return 'Twitter';
  if (host.contains('instagram')) return 'Instagram';
  if (host.contains('twitch')) return 'Twitch';
  if (host.contains('bilibili')) return 'Bilibili';
  return host.split('.').first;
}

String _deriveLoginUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  final host = uri.host.replaceFirst('www.', '');
  if (host.contains('youtube') || host.contains('youtu.be')) {
    return 'https://accounts.google.com';
  }
  if (host.contains('twitter') || host.contains('x.com')) {
    return 'https://twitter.com/login';
  }
  if (host.contains('instagram')) {
    return 'https://www.instagram.com/accounts/login/';
  }
  if (host.contains('twitch')) {
    return 'https://www.twitch.tv/login';
  }
  if (host.contains('bilibili')) {
    return 'https://passport.bilibili.com/login';
  }
  return 'https://${uri.host}/login';
}
