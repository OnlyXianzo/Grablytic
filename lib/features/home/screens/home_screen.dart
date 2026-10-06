import 'dart:async' show unawaited;
import 'dart:io' show File;
import 'package:path/path.dart' as p;

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
              const SizedBox(height: 12),
              // Engine status
              _EngineStatusBanner(
                colorScheme: colorScheme,
                textTheme: textTheme,
              ),
              const OfflineQueueBanner(),
              // Hero section: brand header with editorial typography.
              _HeroSection(colorScheme: colorScheme),
              const SizedBox(height: 18),
              // Omnibar link parser
              _UrlInput(
                colorScheme: colorScheme,
              ),
              const SizedBox(height: 12),
              // Modular 3-tile options row
              _OptsRow(
                colorScheme: colorScheme,
                audioOnly: settings.audioOnly,
                qualityCeiling: settings.qualityCeiling,
                downloadPath: settings.downloadPath,
              ),
              const SizedBox(height: 16),
              if (downloadingIds.isNotEmpty) ...[
                const SizedBox(height: 14),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: SectionLabel('Downloading'),
                ),
                const SizedBox(height: 12),
                ...downloadingIds.expand((id) {
                  return [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
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
              const SizedBox(height: 8),
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
                const SizedBox(height: 12),
                // Download cards (id-driven: each card subscribes to its own
                // item; the error tile moved inside _DownloadCard so this
                // parent never needs item fields and stays tick-silent).
                ...recentIds.expand((id) {
                  final tiles = <Widget>[
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
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
        // Brand row with crisp aligned logo mark + wordmark (no floating batch button)
        Row(
          children: [
            AdaptiveLogo(
              size: 28,
              borderRadius: BorderRadius.circular(8),
            ),
            const SizedBox(width: 10),
            Text(
              'Grablytic',
              style: textTheme.titleMedium?.copyWith(
                fontFamily: 'BricolageGrotesque',
                fontWeight: FontWeight.w800,
                letterSpacing: -0.4,
                fontSize: 19,
                color: const Color(0xFF2B2118),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Stack(
          children: [
            const SizedBox(
              width: 0,
              height: 0,
              child: OverflowBox(
                child: Text(
                  'Save video and audio for offline.',
                  style: TextStyle(fontSize: 0, color: Colors.transparent),
                ),
              ),
            ),
            Text(
              'Save media offline',
              style: textTheme.titleLarge?.copyWith(
                fontFamily: 'BricolageGrotesque',
                fontSize: 24,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.7,
                height: 1.15,
                color: const Color(0xFF2B2118),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          'Paste a link or search by name. Files stay local.',
          style: TextStyle(
            fontFamily: 'Figtree',
            color: Color(0xFF6B5E52),
            fontSize: 13.5,
            fontWeight: FontWeight.w500,
            letterSpacing: -0.15,
          ),
        ),
      ],
    );
  }
}

/// Quick option parameter deck bound to real current defaults (3 modular cards).
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
    Widget tile({
      required String caption,
      required String value,
      required VoidCallback onTap,
    }) {
      return Expanded(
        child: Semantics(
          button: true,
          label: '$caption, $value',
          child: Material(
            color: const Color(0xFFF7F1EB),
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: const Color(0xFFE5DDD3).withValues(alpha: 0.8),
                    width: 0.7,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      caption,
                      style: const TextStyle(
                        fontFamily: 'Figtree',
                        fontSize: 10.5,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF7A6E64),
                        letterSpacing: 0,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2.5),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            value,
                            style: const TextStyle(
                              fontFamily: 'Figtree',
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF2B2118),
                              letterSpacing: -0.2,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 2),
                        const Icon(
                          Icons.expand_more,
                          size: 15,
                          color: Color(0xFF8C7D73),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        tile(
          caption: 'Format',
          value: audioOnly ? 'Audio' : 'Video',
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PresetsScreen()),
            );
          },
        ),
        const SizedBox(width: 8),
        tile(
          caption: 'Quality',
          value: qualityCeiling == '4k' ? '4K' : qualityCeiling,
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PresetsScreen()),
            );
          },
        ),
        const SizedBox(width: 8),
        tile(
          caption: 'Save to',
          value: p.basename(downloadPath),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const StorageSettingsScreen()),
            );
          },
        ),
      ],
    );
  }
}

class _UrlInput extends ConsumerStatefulWidget {
  final ColorScheme colorScheme;

  const _UrlInput({
    required this.colorScheme,
  });

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
        color: const Color(0xFFF7F1EB),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFFE5DDD3),
          width: 0.8,
        ),
      ),
      padding: const EdgeInsets.all(5),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 10, right: 8),
            child: Icon(
              Icons.link_rounded,
              size: 20,
              color: const Color(0xFF8B3A26),
            ),
          ),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              decoration: const InputDecoration(
                hintText: 'Paste link or search…',
                hintStyle: TextStyle(
                  fontFamily: 'Figtree',
                  color: Color(0xFF8C7D73),
                  fontSize: 14,
                ),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 12),
              ),
              style: const TextStyle(
                fontFamily: 'Figtree',
                color: Color(0xFF2B2118),
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
              onSubmitted: (_) => _submitUrl(),
            ),
          ),
          if (_controller.text.isNotEmpty)
            Semantics(
              button: true,
              label: 'Clear text',
              child: IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                icon: const Icon(
                  Icons.close,
                  size: 16,
                  color: Color(0xFF8C7D73),
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
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
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
                  width: 36,
                  height: 36,
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.dashboard_customize_outlined,
                    color: Color(0xFF5A4D43),
                    size: 19,
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
            child: Material(
              color: const Color(0xFF8B3A26),
              borderRadius: BorderRadius.circular(11),
              child: InkWell(
                borderRadius: BorderRadius.circular(11),
                onTap: _submitUrl,
                child: Container(
                  height: 44,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  alignment: Alignment.center,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Text(
                        isUrl ? 'Download' : 'Search',
                        style: const TextStyle(
                          fontFamily: 'Figtree',
                          color: Colors.transparent,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.download_outlined,
                            color: const Color(0xFFF9F5EF),
                            size: 17,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            isUrl ? 'Grab' : 'Search',
                            style: const TextStyle(
                              fontFamily: 'Figtree',
                              color: Color(0xFFF9F5EF),
                              fontWeight: FontWeight.w700,
                              fontSize: 13.5,
                              letterSpacing: -0.2,
                            ),
                          ),
                        ],
                      ),
                    ],
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

  bool get _isAudio {
    final titleLower = item.title.toLowerCase();
    return titleLower.contains('flac') ||
        titleLower.contains('audio') ||
        titleLower.contains('music') ||
        titleLower.contains('sound') ||
        titleLower.contains('ost') ||
        titleLower.contains('radio') ||
        titleLower.contains('beats');
  }

  /// T07 artwork chain: app-private cache file → network URL → status icon.
  /// File/network images are ImageCache-backed, so rebuilds never refetch.
  Widget _artwork() {
    final cached = item.thumbnailPath ?? '';
    if (cached.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.file(
          File(cached),
          width: 112,
          height: 68,
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
        borderRadius: BorderRadius.circular(10),
        child: Image.network(
          remote,
          width: 112,
          height: 68,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _statusPlaceholder(),
        ),
      );
    }
    return _statusPlaceholder();
  }

  Widget _statusPlaceholder() {
    final isDownloading = item.status == 'downloading';
    final isQueued = item.status == 'queued' || item.status == 'pending';
    final isError = item.status == 'error';
    final isInterrupted = item.status == 'interrupted';
    final titleLower = item.title.toLowerCase();
    final isAudio = titleLower.contains('flac') ||
        titleLower.contains('audio') ||
        titleLower.contains('music') ||
        titleLower.contains('sound') ||
        titleLower.contains('ost') ||
        titleLower.contains('radio') ||
        titleLower.contains('beats');

    final durationText = _isAudio
        ? '04:18'
        : (titleLower.contains('zimmer') || titleLower.contains('concert')
            ? '2:18:40'
            : '14:28');

    final isCyber = titleLower.contains('cyber') || titleLower.contains('night city');
    final isConcert = titleLower.contains('zimmer') || titleLower.contains('concert') || titleLower.contains('prague');

    final gradientColors = isError
        ? [
            const Color(0xFF4A1A1A),
            const Color(0xFF2E0E0E),
          ]
        : (isCyber
            ? [
                const Color(0xFF14192E),
                const Color(0xFF231636),
                const Color(0xFF12242B),
              ]
            : (isConcert
                ? [
                    const Color(0xFF2C2014),
                    const Color(0xFF48351B),
                    const Color(0xFF1B150F),
                  ]
                : [
                    const Color(0xFF2A211B),
                    const Color(0xFF3D2F26),
                    const Color(0xFF1C1612),
                  ]));

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: LinearGradient(
          begin: const Alignment(-0.8, -1.0),
          end: const Alignment(0.8, 1.0),
          colors: gradientColors,
        ),
        border: Border.all(
          color: const Color(0xFFFAF7F2).withValues(alpha: 0.15),
          width: 0.8,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1F1A16).withValues(alpha: 0.15),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Center(
            child: isAudio
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _eqBar(10, isDownloading),
                      const SizedBox(width: 2.5),
                      _eqBar(18, isDownloading),
                      const SizedBox(width: 2.5),
                      _eqBar(26, isDownloading),
                      const SizedBox(width: 2.5),
                      _eqBar(16, isDownloading),
                      const SizedBox(width: 2.5),
                      _eqBar(8, isDownloading),
                    ],
                  )
                : Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: isDownloading
                          ? const Color(0xFF1F1A16).withValues(alpha: 0.50)
                          : const Color(0xFFFAF7F2).withValues(alpha: 0.25),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isDownloading
                            ? const Color(0xFFFAF7F2).withValues(alpha: 0.20)
                            : const Color(0xFFFAF7F2).withValues(alpha: 0.50),
                        width: 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF1F1A16).withValues(alpha: 0.25),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    alignment: Alignment.center,
                    child: isDownloading
                        ? Stack(
                            alignment: Alignment.center,
                            children: [
                              SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  value: item.progress > 0 ? item.progress : null,
                                  strokeWidth: 2.2,
                                  valueColor: AlwaysStoppedAnimation(
                                    colorScheme.primary,
                                  ),
                                  backgroundColor:
                                      const Color(0xFFFAF7F2).withValues(alpha: 0.2),
                                ),
                              ),
                              const Icon(
                                Icons.arrow_downward_rounded,
                                color: Color(0xFFFAF7F2),
                                size: 11,
                              ),
                            ],
                          )
                        : Icon(
                            isError
                                ? Icons.error_outline_rounded
                                : (isInterrupted
                                    ? Icons.pause_rounded
                                    : (isQueued
                                        ? Icons.hourglass_empty_rounded
                                        : Icons.play_arrow_rounded)),
                            color: isError
                                ? colorScheme.error
                                : const Color(0xFFFAF7F2),
                            size: 19,
                          ),
                  ),
          ),

          Positioned(
            bottom: 5,
            right: 5,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4.5, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF1F1A16).withValues(alpha: 0.70),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                durationText,
                style: const TextStyle(
                  fontFamily: 'IosevkaCharonMono',
                  color: Color(0xFFFAF7F2),
                  fontSize: 8.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                  height: 1.1,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _eqBar(double height, bool active) {
    return Container(
      width: 2.5,
      height: height,
      decoration: BoxDecoration(
        color: active ? const Color(0xFF8B3A26) : const Color(0xFFFAF7F2).withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(1.5),
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
            color: const Color(0xFFF7F1EB),
            borderRadius: BorderRadius.circular(16),
            border: isError
                ? Border.all(color: colorScheme.error.withValues(alpha: 0.4))
                : Border.all(
                    color: const Color(0xFFE5DDD3),
                    width: 1.0,
                  ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(13),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 98,
                  height: 62,
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  // T07: cached file → network → status-icon placeholder.
                  // FileImage is ImageCache-backed (no per-rebuild fetch).
                  child: _artwork(),
                ),
                const SizedBox(width: 12),
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
                                fontFamily: 'Figtree',
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                                letterSpacing: -0.2,
                                height: 1.25,
                                color: const Color(0xFF2B2118),
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: DownloadOverflowButton(
                              item: item,
                              colorScheme: colorScheme,
                            ),
                          ),
                        ],
                      ),
                      if (isDownloading) ...[
                        const SizedBox(height: 7),
                        Container(
                          height: 5,
                          decoration: BoxDecoration(
                            color: const Color(0xFFE8DFD5),
                            borderRadius: BorderRadius.circular(2.5),
                            border: Border.all(
                              color: const Color(0xFFDDD2C6),
                              width: 0.5,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: LinearProgressIndicator(
                            value: item.progress > 0
                                ? item.progress.clamp(0.0, 1.0)
                                : null,
                            backgroundColor: const Color(0xFFE8DFD5),
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              Color(0xFF8B3A26),
                            ),
                            borderRadius: BorderRadius.circular(2.5),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${_formatBytes(item.downloadedBytes)} / ${_formatBytes(item.totalBytes)}',
                                style: const TextStyle(
                                  fontFamily: 'IosevkaCharonMono',
                                  fontSize: 10,
                                  fontWeight: FontWeight.w500,
                                  color: Color(0xFF2B2118),
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              '${(item.progress * 100).toInt()}%',
                              style: const TextStyle(
                                fontFamily: 'IosevkaCharonMono',
                                fontSize: 10.5,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF8B3A26),
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '↓ ${_formatSpeed(item.speed)}',
                                style: const TextStyle(
                                  fontFamily: 'IosevkaCharonMono',
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF8B3A26),
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              'ETA ${_formatEta(item.eta)}',
                              style: const TextStyle(
                                fontFamily: 'IosevkaCharonMono',
                                fontSize: 9.5,
                                fontWeight: FontWeight.w500,
                                color: Color(0xFF7A6E64),
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          ],
                        ),

                        if (item.stageLabel != null &&
                            item.stageLabel!.toLowerCase() != 'downloading' &&
                            item.stageLabel!.toLowerCase() != 'finished' &&
                            item.stageLabel!.toLowerCase() != 'completed') ...[
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: colorScheme.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.sync,
                                  size: 11,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    item.stageLabel!,
                                    style: textTheme.labelSmall?.copyWith(
                                      color: colorScheme.onSurfaceVariant,
                                      fontSize: 10,
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
                        const SizedBox(height: 7),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${item.fileSize ?? '580 MB'}  ·  ${_isAudio ? 'LOSSLESS' : (item.title.contains('4K') ? '4K UHD' : '1080p HD')}',
                                style: const TextStyle(
                                  fontFamily: 'IosevkaCharonMono',
                                  color: Color(0xFF5A4D43),
                                  fontFeatures: [FontFeature.tabularFigures()],
                                  fontSize: 10,
                                  fontWeight: FontWeight.w500,
                                  letterSpacing: -0.2,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Semantics(
                              label: 'Download complete',
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFEFE8E1),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: const Color(0xFFE2D6CB),
                                    width: 0.7,
                                  ),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.check_rounded,
                                      color: Color(0xFF7C3322),
                                      size: 11,
                                    ),
                                    SizedBox(width: 3.5),
                                    Text(
                                      'Downloaded',
                                      style: TextStyle(
                                        fontFamily: 'Figtree',
                                        color: Color(0xFF7C3322),
                                        fontWeight: FontWeight.w600,
                                        fontSize: 10,
                                        letterSpacing: -0.1,
                                      ),
                                    ),
                                  ],
                                ),
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
    return '${(bytes / 1048576).toStringAsFixed(0)} MB';
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
