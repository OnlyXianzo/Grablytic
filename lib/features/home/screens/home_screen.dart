import 'dart:async' show unawaited;
import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/adaptive_logo.dart';
import '../../../core/theme/text_styles.dart';
import '../../../core/widgets/grablytic_components.dart';
import '../../../providers/download_provider.dart';
import '../../../providers/engine_status_provider.dart';
import '../../../providers/resume_provider.dart';
import '../../../providers/settings_provider.dart';
import '../screens/format_picker_screen.dart';
import 'playlist_selection_screen.dart';
import 'search_results_screen.dart';
import '../../../features/settings/screens/cookie_webview_screen.dart';
import '../../../features/settings/screens/presets_screen.dart';
import '../../../features/settings/screens/settings_screen.dart';
import 'batch_import_screen.dart';
import '../widgets/error_recovery_card.dart';
import '../widgets/download_log_overlay.dart';
import '../widgets/download_overflow_menu.dart';
import '../widgets/download_sparkline.dart';
import '../../settings/screens/log_viewer_screen.dart';
import '../../../core/utils/app_logger.dart';
import '../../../core/utils/local_analytics.dart';
import '../../../core/utils.dart';
import '../../../core/utils/offline_link_queue.dart';
import '../../../core/utils/playlist_selection.dart';
import '../widgets/offline_queue_banner.dart';

class HomeScreen extends ConsumerWidget {
  /// Optional hook for the "See all" affordance (AppShell wires tab switch).
  final VoidCallback? onSeeAll;

  const HomeScreen({super.key, this.onSeeAll});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Loop-3 O(1) rebuilds: structural ids only (add/status-flip/remove).
    // Progress ticks no longer rebuild this screen; each card watches its
    // own item via [downloadItemProvider] and rebuilds alone.
    final sections = ref.watch(downloadSectionsProvider);
    final settings = ref.watch(settingsProvider);
    final downloadingIds = sections.pendingIds.take(3).toList();
    final recentIds = sections.completedIds.take(3).toList();
    final hasAny = sections.allIds.isNotEmpty;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 24),
              // Engine status
              _EngineStatusBanner(
                colorScheme: colorScheme,
                textTheme: textTheme,
              ),
              const SizedBox(height: 16),
              const OfflineQueueBanner(),
              const SizedBox(height: 8),
              // Hero section: the bench itself is the hero — brand row plus
              // one plain-spoken line about what the tool does. No entrance
              // choreography: motion answers taps, not page loads.
              _HeroSection(colorScheme: colorScheme),
              const SizedBox(height: 32),
              // URL input
              _UrlInput(colorScheme: colorScheme),
              const SizedBox(height: 14),
              // Quick option tiles bound to real defaults.
              _OptsRow(
                colorScheme: colorScheme,
                audioOnly: settings.audioOnly,
                qualityCeiling: settings.qualityCeiling,
                downloadPath: settings.downloadPath,
              ),
              const SizedBox(height: 8),
              if (downloadingIds.isNotEmpty) ...[
                const SizedBox(height: 16),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: SectionLabel('Downloading'),
                ),
                const SizedBox(height: 12),
                ...downloadingIds.expand((id) {
                  return [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: RepaintBoundary(
                        child: _DownloadCardWithError(
                          id: id,
                          colorScheme: colorScheme,
                        ),
                      ),
                    ),
                  ];
                }),
              ],
              const _ResumeScanSection(),
              const SizedBox(height: 40),
              // Recent downloads
              if (recentIds.isNotEmpty) ...[
                Row(
                  children: [
                    const Expanded(
                      child: SectionLabel('Recent'),
                    ),
                    if (onSeeAll != null)
                      TextButton(
                        onPressed: onSeeAll,
                        child: const Text('See all'),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                // Download cards (id-driven: each card subscribes to its own
                // item; the error tile moved inside _DownloadCard so this
                // parent never needs item fields and stays tick-silent).
                ...recentIds.expand((id) {
                  final tiles = <Widget>[
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: RepaintBoundary(
                        child: _DownloadCardWithError(
                          id: id,
                          colorScheme: colorScheme,
                        ),
                      ),
                    ),
                  ];
                  return tiles;
                }),
              ] else if (!hasAny) ...[
                const SizedBox(height: 36),
                Semantics(
                  label: 'No downloads',
                  child: Container(
                    width: 76,
                    height: 76,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: colorScheme.outlineVariant
                            .withValues(alpha: 0.5),
                      ),
                    ),
                    child: Icon(
                      Icons.cloud_download_outlined,
                      size: 30,
                      color: colorScheme.outline,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'No downloads yet',
                  style: textTheme.bodyLarge?.copyWith(
                    color: colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
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
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Brand row (mockup `.brand`).
        Row(
          children: [
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color:
                      colorScheme.outlineVariant.withValues(alpha: 0.5),
                ),
              ),
              child: AdaptiveLogo(
                size: 36,
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              'Grablytic',
              style: textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.01,
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
        Text(
          'Save video and audio for offline.',
          style: textTheme.headlineLarge?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: -0.02,
            height: 1.05,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Paste a link or type a name. Files stay on this device.',
          style: textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Quick option tiles (mockup `.opts`) bound to real current defaults.
/// Tiles are navigation shortcuts — values come from settings, targets are
/// the real screens that own each option. No new behavior.
class _OptsRow extends StatelessWidget {
  final ColorScheme colorScheme;
  final bool audioOnly;
  final String qualityCeiling;
  final String downloadPath;

  const _OptsRow({
    required this.colorScheme,
    required this.audioOnly,
    required this.qualityCeiling,
    required this.downloadPath,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    String basename(String path) {
      final parts =
          path.split('/').where((s) => s.isNotEmpty).toList();
      return parts.isEmpty ? path : parts.last;
    }

    Widget tile(String caption, String value, VoidCallback onTap) {
      return Expanded(
        child: Semantics(
          button: true,
          label: '$caption, $value',
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color:
                      colorScheme.outlineVariant.withValues(alpha: 0.3),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    caption,
                    style: textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          value,
                          style: textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        Icons.expand_more,
                        size: 16,
                        color: colorScheme.outline,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        tile('Format', audioOnly ? 'Audio' : 'Video', () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const PresetsScreen()),
          );
        }),
        const SizedBox(width: 8),
        tile('Quality', qualityCeiling, () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const PresetsScreen()),
          );
        }),
        const SizedBox(width: 8),
        tile('Save to', basename(downloadPath), () {
          Navigator.of(context).push(
            MaterialPageRoute(
                builder: (_) => const StorageSettingsScreen()),
          );
        }),
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
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _submitUrl() async {
    final input = _controller.text.trim();
    if (input.isEmpty) return;
    _focusNode.unfocus();

    if (looksLikeUrl(input)) {
      AppLogger.info('User submitted URL: $input', tag: 'HomeScreen');
      unawaited(LocalAnalytics.recordIntake(LocalAnalytics.kindPaste, input));
      final offline = await isDeviceOffline();
      if (!mounted) return;
      if (offline) {
        final added = await ref
            .read(offlineQueueProvider.notifier)
            .addLink(input, source: 'paste');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              added
                  ? 'Offline: Link saved to queue'
                  : 'Link is already in offline queue',
            ),
          ),
        );
        _controller.clear();
        return;
      }
      // Playlist URLs get entry selection (03-B) instead of the
      // single-video format picker — otherwise a playlist "downloads as
      // it wants" with no subset/reverse/shuffle control.
      final target = isPlaylistUrl(input)
          ? PlaylistSelectionScreen(url: input, title: input)
          : FormatPickerScreen(url: input, title: input);
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => target));
    } else {
      AppLogger.info('User submitted search query: $input', tag: 'HomeScreen');
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SearchResultsScreen(initialQuery: input),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = _controller.text.trim();
    final isUrl = text.isEmpty || looksLikeUrl(text);

    ref.listen<String?>(sharedUrlProvider, (previous, next) {
      if (next != null && next.isNotEmpty) {
        _controller.text = next;
        _focusNode.requestFocus();
        ref.read(sharedUrlProvider.notifier).state = null;
      }
    });
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: widget.colorScheme.outlineVariant.withValues(alpha: 0.85),
        ),
        color: widget.colorScheme.surfaceContainerLowest,
      ),
      padding: const EdgeInsets.all(6),
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 16, right: 8),
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                decoration: InputDecoration(
                  hintText: 'Search or enter link…',
                  hintStyle: TextStyle(
                    color: widget.colorScheme.outline,
                  ),
                  border: InputBorder.none,
                  isDense: true,
                ),
                style: Theme.of(context).textTheme.bodyMedium,
                onSubmitted: (_) => _submitUrl(),
              ),
            ),
          ),
          if (_controller.text.isNotEmpty)
            Semantics(
              button: true,
              label: 'Clear text',
              child: IconButton(
                icon: Icon(
                  Icons.close,
                  size: 18,
                  color: widget.colorScheme.onSurfaceVariant,
                ),
                tooltip: 'Clear input',
                onPressed: () {
                  _controller.clear();
                  _focusNode.requestFocus();
                },
              ),
            ),
          Semantics(
            button: true,
            label: 'Batch import URLs',
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Material(
                color: widget.colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    AppLogger.info(
                      'User clicked Batch import URLs button',
                      tag: 'HomeScreen',
                    );
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const BatchImportScreen(),
                      ),
                    );
                  },
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
            label: isUrl ? 'Submit URL' : 'Search videos',
            excludeSemantics: true,
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Material(
                color: widget.colorScheme.primary,
                borderRadius: BorderRadius.circular(16),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: _submitUrl,
                  child: Container(
                    height: 48,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14),
                    alignment: Alignment.center,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.download_outlined,
                          color: widget.colorScheme.onPrimary,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        // Decorative duplicate of the button's
                        // accessible name ('Submit URL' / 'Search
                        // videos') — excluded so the merged semantics
                        // label stays exact for tests + readers.
                        ExcludeSemantics(
                          child: Text(
                            isUrl ? 'Download' : 'Search',
                            style: Theme.of(context)
                                .textTheme
                                .bodyLarge
                                ?.copyWith(
                                  color:
                                      widget.colorScheme.onPrimary,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ),
                      ],
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

class _DownloadCardWithError extends ConsumerWidget {
  final String id;
  final ColorScheme colorScheme;

  const _DownloadCardWithError({required this.id, required this.colorScheme});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Own-item subscription: rebuilds only when THIS item changes
    // (progress ticks for other ids deliver the identical instance and are
    // skipped by Riverpod). Null = removed mid-frame: render nothing.
    final item = ref.watch(downloadItemProvider(id));
    if (item == null) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _DownloadCard(item: item, colorScheme: colorScheme),
        if (item.status == 'error')
          Padding(
            // Matches the pre-Loop-3 sibling spacing (16 between card and
            // tile); the outer bottom:16 is preserved by the caller.
            padding: const EdgeInsets.only(top: 16),
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
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                );
              },
              onPickFormat: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        FormatPickerScreen(url: item.url, title: item.title),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _DownloadCard extends StatelessWidget {
  final DownloadItem item;
  final ColorScheme colorScheme;

  const _DownloadCard({required this.item, required this.colorScheme});

  /// T07 artwork chain: app-private cache file → network URL → status icon.
  /// File/network images are ImageCache-backed, so rebuilds never refetch.
  Widget _artwork() {
    final cached = item.thumbnailPath ?? '';
    if (cached.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          File(cached),
          width: 96,
          height: 96,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _remoteOrPlaceholder(),
        ),
      );
    }
    return _remoteOrPlaceholder();
  }

  Widget _remoteOrPlaceholder() {
    final remote = item.thumbnailUrl ?? '';
    if (remote.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(
          remote,
          width: 96,
          height: 96,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _statusPlaceholder(),
        ),
      );
    }
    return _statusPlaceholder();
  }

  Widget _statusPlaceholder() {
    final isDownloading = item.status == 'downloading';
    final isCancelling = item.status == 'cancelling';
    final isQueued = item.status == 'queued' || item.status == 'pending';
    final isError = item.status == 'error';
    final isInterrupted = item.status == 'interrupted';
    if (isDownloading) {
      return Stack(
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
      );
    }
    if (isQueued) {
      return Semantics(
        label: 'Queued',
        child: Icon(
          Icons.hourglass_empty,
          color: colorScheme.onSurfaceVariant,
          size: 32,
        ),
      );
    }
    if (isInterrupted) {
      return Semantics(
        label: 'Interrupted',
        child: Icon(
          Icons.pause_circle_outline,
          color: colorScheme.secondary,
          size: 32,
        ),
      );
    }
    if (isCancelling) {
      return Semantics(
        label: 'Cancelling',
        child: Icon(
          Icons.cancel_outlined,
          color: colorScheme.onSurfaceVariant,
          size: 32,
        ),
      );
    }
    return Semantics(
      label: isError ? 'Error' : 'Completed',
      child: Icon(
        isError ? Icons.error_outline : Icons.image_outlined,
        color: isError
            ? colorScheme.error
            : colorScheme.outline.withValues(alpha: 0.5),
        size: 32,
      ),
    );
  }

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
            Text(
              'Restricted Content',
              style: Theme.of(ctx).textTheme.titleMedium,
            ),
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
    final isCancelling = item.status == 'cancelling';
    final isQueued = item.status == 'queued' || item.status == 'pending';
    final isError = item.status == 'error';
    final isInterrupted = item.status == 'interrupted';
    final textTheme = Theme.of(context).textTheme;

    return Semantics(
      button: isError && item.suggestsVpn,
      label: isError && item.suggestsVpn
          ? '${item.title} - VPN suggested. Tap for details.'
          : item.title,
      child: GestureDetector(
        onTap: isError && item.suggestsVpn
            ? () => _showVpnDialog(context)
            : null,
        child: Container(
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isError
                  ? colorScheme.error.withValues(alpha: 0.4)
                  : colorScheme.outlineVariant.withValues(alpha: 0.2),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 104,
                  height: 78,
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  // T07: cached file → network → status-icon placeholder.
                  // FileImage is ImageCache-backed (no per-rebuild fetch).
                  child: _artwork(),
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
                              style: textTheme.bodyLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          DownloadOverflowButton(
                            item: item,
                            colorScheme: colorScheme,
                          ),
                        ],
                      ),
                      if (isDownloading) ...[
                        const SizedBox(height: 4),
                        Text(
                          '${_formatBytes(item.downloadedBytes)} of ${_formatBytes(item.totalBytes)}',
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        const SizedBox(height: 14),
                        // Solid terracotta fill on track (mockup `.pbar`);
                        // indeterminate LinearProgress while
                        // post-processing (no progress callback when merging).
                        if (item.stage != null)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              backgroundColor:
                                  colorScheme.surfaceContainerHighest,
                              valueColor: AlwaysStoppedAnimation(
                                colorScheme.primary,
                              ),
                              minHeight: 8,
                            ),
                          )
                        else
                          Semantics(
                            label:
                                'Progress ${(item.progress * 100).toInt()} percent',
                            value: '${(item.progress * 100).toInt()}%',
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: Container(
                                height: 8,
                                color:
                                    colorScheme.surfaceContainerHighest,
                                alignment: Alignment.centerLeft,
                                 child: FractionallySizedBox(
                                   widthFactor:
                                       item.progress.clamp(0.0, 1.0),
                                   child: Container(
                                     decoration: BoxDecoration(
                                       color: colorScheme.primary,
                                       borderRadius:
                                           BorderRadius.circular(4),
                                     ),
                                   ),
                                 ),
                              ),
                            ),
                          ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment:
                              MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '${(item.progress * 100).toInt()}% · ${_formatSpeed(item.speed)}',
                              style: textTheme.bodySmall?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: colorScheme.primary,
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ],
                              ),
                            ),
                            Text(
                              'ETA ${_formatEta(item.eta)}',
                              style: textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ],
                              ),
                            ),
                          ],
                        ),
                        if (item.stageLabel != null) ...[
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: colorScheme.primaryContainer.withValues(
                                alpha: 0.5,
                              ),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.hourglass_top,
                                  size: 12,
                                  color: colorScheme.onPrimaryContainer,
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    item.stageLabel!,
                                    style: textTheme.labelSmall?.copyWith(
                                      color: colorScheme.onPrimaryContainer,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: 4),
                        if (item.speedHistory.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          DownloadSparkline(samples: item.speedHistory),
                          const SizedBox(height: 4),
                        ],
                        // Solid determinate bar lives above (mockup `.pbar`);
// the indeterminate post-processing case is handled
                        // there too.
                        const SizedBox(height: 8),
                        DownloadLogOverlay(
                          downloadId: item.id,
                          visible: isDownloading,
                        ),
                      ] else if (isCancelling) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Icon(
                              Icons.cancel_outlined,
                              size: 14,
                              color: colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Cancelling — waiting for worker to stop',
                              style: textTheme.labelSmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ] else if (isQueued) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Icon(
                              Icons.hourglass_empty,
                              size: 14,
                              color: colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Queued — starts when a slot frees up',
                              style: textTheme.labelSmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ] else if (isInterrupted) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Icon(
                              Icons.pause_circle_outline,
                              size: 14,
                              color: colorScheme.secondary,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Interrupted — tap menu to resume',
                              style: textTheme.labelSmall?.copyWith(
                                color: colorScheme.secondary,
                              ),
                            ),
                          ],
                        ),
                        if (item.downloadedBytes > 0 &&
                            item.totalBytes > 0) ...[
                          const SizedBox(height: 4),
                          Text(
                            '${_formatBytes(item.downloadedBytes)} / ${_formatBytes(item.totalBytes)} (${(item.progress * 100).toInt()}%)',
                            style: textTheme.mono.copyWith(
                              color: colorScheme.outline,
                              fontSize: 10,
                            ),
                          ),
                        ],
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
                        const SizedBox(height: 8),
                        DownloadLogOverlay(
                          downloadId: item.id,
                          visible: isError,
                        ),
                        if (item.suggestsVpn) ...[
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Icon(
                                Icons.vpn_lock,
                                size: 14,
                                color: colorScheme.error,
                              ),
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
                                  horizontal: 8,
                                  vertical: 3,
                                ),
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

  String _formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond <= 0) return '—';
    if (bytesPerSecond < 1048576) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(0)} KB/s';
    }
    return '${(bytesPerSecond / 1048576).toStringAsFixed(1)} MB/s';
  }

  String _formatEta(int seconds) {
    if (seconds < 0) return '--:--';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    if (m >= 60) return '${m ~/ 60}h ${m % 60}m';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}

class _EngineStatusBanner extends ConsumerWidget {
  final ColorScheme colorScheme;
  final TextTheme textTheme;

  const _EngineStatusBanner({
    required this.colorScheme,
    required this.textTheme,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statusAsync = ref.watch(engineStatusProvider);

    return statusAsync.when(
      // Bootstrap card removed from Home (binaries live in Settings).
      // Only genuine engine errors and status messages surface here.
      loading: () => const SizedBox.shrink(),
      error: (err, _) {
        AppLogger.error('Engine status provider error', error: err);
        return _buildErrorPlaceholder(context, colorScheme, textTheme);
      },
      data: (status) {
        if (status.error != null) {
          AppLogger.error('Engine status reports error: ${status.error}');
          return _buildErrorPlaceholder(context, colorScheme, textTheme);
        }

        final message = status.statusMessage;
        if (message == null) return const SizedBox.shrink();
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: colorScheme.tertiaryContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Semantics(
            label: 'Engine status: $message',
            child: Row(
              children: [
                Icon(
                  Icons.system_update,
                  size: 16,
                  color: colorScheme.onTertiaryContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    message,
                    style: textTheme.labelSmall?.copyWith(
                      color: colorScheme.onTertiaryContainer,
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

  Widget _buildErrorPlaceholder(
    BuildContext context,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer.withAlpha(30),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.error.withAlpha(80)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline, color: colorScheme.error, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Looks like something went wrong.',
                  style: textTheme.titleSmall?.copyWith(
                    color: colorScheme.onErrorContainer,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'The engine encountered an error. You can view diagnostics, get an AI-generated fix template, or report this on GitHub.',
            style: textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () {
              AppLogger.info(
                'User clicked Open Log & Report button on error panel',
                tag: 'HomeScreen',
              );
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LogViewerScreen()),
              );
            },
            icon: const Icon(Icons.bug_report_outlined, size: 16),
            label: const Text('Open Log & Report'),
            style: OutlinedButton.styleFrom(
              foregroundColor: colorScheme.error,
              side: BorderSide(color: colorScheme.error.withAlpha(120)),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ],
      ),
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
              'Interrupted downloads',
              style: textTheme.titleSmall?.copyWith(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w600,
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
                            color: candidate.expired
                                ? colorScheme.error
                                : colorScheme.secondary,
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
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.errorContainer.withValues(
                            alpha: 0.1,
                          ),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: colorScheme.error.withValues(alpha: 0.2),
                          ),
                        ),
                        child: Row(
                          children: [
                            Semantics(
                              label: 'Expired',
                              child: Icon(
                                Icons.timer_off_outlined,
                                color: colorScheme.error,
                                size: 16,
                              ),
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
                            AppLogger.info(
                              'User dismissed resume candidate: ${candidate.filename}',
                              tag: 'HomeScreen',
                            );
                            ref
                                .read(resumeProvider.notifier)
                                .dismiss(candidate);
                          },
                          style: TextButton.styleFrom(
                            foregroundColor: colorScheme.outline,
                          ),
                          child: const Text('Dismiss'),
                        ),
                        const SizedBox(width: 8),
                        if (candidate.likelyUrl != null &&
                            !candidate.expired) ...[
                          ElevatedButton(
                            onPressed: () async {
                              AppLogger.info(
                                'User clicked resume candidate: ${candidate.filename}',
                                tag: 'HomeScreen',
                              );
                              final url = await ref
                                  .read(resumeProvider.notifier)
                                  .resumeDownload(candidate);
                              if (url != null) {
                                ref.read(sharedUrlProvider.notifier).state =
                                    url;
                              }
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: colorScheme.primary,
                              foregroundColor: colorScheme.onPrimary,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            child: const Text('Resume'),
                          ),
                        ] else ...[
                          OutlinedButton(
                            onPressed: () {
                              AppLogger.info(
                                'User clicked retry candidate: ${candidate.filename}',
                                tag: 'HomeScreen',
                              );
                              if (candidate.likelyUrl != null) {
                                ref
                                    .read(resumeProvider.notifier)
                                    .deleteFileOnly(candidate);
                                ref.read(sharedUrlProvider.notifier).state =
                                    candidate.likelyUrl;
                              } else {
                                ref
                                    .read(resumeProvider.notifier)
                                    .deleteFileOnly(candidate);
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
