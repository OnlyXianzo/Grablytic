import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/text_styles.dart';
import '../../../features/home/screens/media_preview_screen.dart';
import '../../../features/home/widgets/download_overflow_menu.dart';
import '../../../providers/download_provider.dart';
import '../../../providers/playlist_provider.dart';
import '../../../providers/settings_provider.dart';
import 'download_history_screen.dart';
import 'playlist_details_screen.dart';

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  double _fabScale = 0.0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      setState(() {}); // Rebuild to show/hide FAB based on active tab
    });
    // Drive the FAB from the swipe animation (not just the settled
    // index) so it shrinks the moment a swipe starts and grows back
    // only when the playlist tab settles.
    _tabController.animation?.addListener(_syncFabScale);
    _syncFabScale();
  }

  void _syncFabScale() {
    final v = _tabController.animation?.value ?? _tabController.index.toDouble();
    final scale = (1.0 - (v - 1.0).abs()).clamp(0.0, 1.0);
    if ((scale - _fabScale).abs() > 0.01) {
      setState(() => _fabScale = scale);
    }
  }

  @override
  void dispose() {
    _tabController.animation?.removeListener(_syncFabScale);
    _tabController.dispose();
    super.dispose();
  }

  void _showCreatePlaylistDialog(
    BuildContext context,
    WidgetRef ref,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colorScheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('New Playlist', style: textTheme.titleMedium),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Enter playlist name...',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                ref.read(playlistProvider.notifier).createPlaylist(name);
                Navigator.pop(ctx);
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final downloads = ref.watch(downloadProvider);
    final playlists = ref.watch(playlistProvider);
    final settings = ref.watch(settingsProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      floatingActionButton: Visibility(
        visible: _fabScale > 0.05,
        child: AnimatedScale(
          scale: _fabScale,
          duration: const Duration(milliseconds: 150),
          child: FloatingActionButton.extended(
            onPressed: () => _showCreatePlaylistDialog(context, ref, colorScheme, textTheme),
            backgroundColor: colorScheme.primary,
            foregroundColor: colorScheme.onPrimary,
            icon: const Icon(Icons.playlist_add),
            label: const Text('New Playlist'),
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Row(
                children: [
                  Text(
                    'Library',
                    style: textTheme.headlineSmall?.copyWith(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => ref.read(settingsProvider.notifier).setUseGridView(!settings.useGridView),
                    icon: Icon(settings.useGridView ? Icons.view_list : Icons.grid_view),
                    tooltip: settings.useGridView ? 'List view' : 'Grid view',
                  ),
                ],
              ),
            ),
            // Tabs
            TabBar(
              controller: _tabController,
              indicatorColor: colorScheme.primary,
              labelColor: colorScheme.primary,
              unselectedLabelColor: colorScheme.onSurfaceVariant,
              labelStyle: textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              unselectedLabelStyle: textTheme.labelLarge,
              tabs: const [
                Tab(text: 'Videos'),
                Tab(text: 'Playlists'),
                Tab(text: 'History'),
              ],
            ),
            // Content
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildLibraryContent(downloads, colorScheme, textTheme, settings.useGridView),
                  _buildPlaylistsTab(playlists, colorScheme, textTheme),
                  const DownloadHistoryScreen(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLibraryContent(
    List<DownloadItem> downloads,
    ColorScheme colorScheme,
    TextTheme textTheme,
    bool useGridView,
  ) {
    final pending = downloads
        .where((d) =>
            d.status == 'downloading' ||
            d.status == 'pending' ||
            d.status == 'paused')
        .toList();
    final failed = downloads
        .where((d) => d.status == 'error' || d.status == 'cancelled')
        .toList();
    final completed =
        downloads.where((d) => d.status == 'completed').toList();

    if (downloads.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.only(top: 60),
          child: Text(
            'No downloads yet',
            style: textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: useGridView
          ? _buildGridView(completed, pending, failed, colorScheme, textTheme)
          : _buildListView(completed, pending, failed, colorScheme, textTheme),
    );
  }

  Widget _buildListView(
    List<DownloadItem> completed,
    List<DownloadItem> pending,
    List<DownloadItem> failed,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    // Lazily-built slivers: the old eager ListView(children:) constructed
    // every row (thumbnails, progress painters) on each frame — visible
    // stutter past ~20 items. Builders + a deeper cache keep scrolling flat.
    Widget sectionHeader(String label, Color color) => SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(
              label,
              style: textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
              ),
            ),
          ),
        );

    return CustomScrollView(
      key: const ValueKey('list'),
      scrollCacheExtent: ScrollCacheExtent.pixels(600),
      slivers: [
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
        if (pending.isNotEmpty) ...[
          sectionHeader('PENDING', colorScheme.primary),
          SliverList.builder(
            itemCount: pending.length,
            itemBuilder: (context, i) => Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: _LibraryItem(
                item: pending[i],
                colorScheme: colorScheme,
                isDownloading: true,
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 20)),
        ],
        if (failed.isNotEmpty) ...[
          sectionHeader('FAILED', colorScheme.error),
          SliverList.builder(
            itemCount: failed.length,
            itemBuilder: (context, i) => Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: _LibraryItem(
                item: failed[i],
                colorScheme: colorScheme,
                isError: true,
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 20)),
        ],
        if (completed.isNotEmpty) ...[
          sectionHeader('DOWNLOADED', colorScheme.primary),
          SliverList.builder(
            itemCount: completed.length,
            itemBuilder: (context, i) => Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: _LibraryItem(
                item: completed[i],
                colorScheme: colorScheme,
                isDownloading: false,
              ),
            ),
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 100)),
      ],
    );
  }

  Widget _buildGridView(
    List<DownloadItem> completed,
    List<DownloadItem> pending,
    List<DownloadItem> failed,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    final all = [...pending, ...failed, ...completed];
    return GridView.builder(
      key: const ValueKey('grid'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.7,
      ),
      itemCount: all.length,
      itemBuilder: (context, index) {
        final item = all[index];
        final isDownloading = item.status == 'downloading' || item.status == 'pending';
        final isError = item.status == 'error' || item.status == 'cancelled';
        return _LibraryGridCard(
          item: item,
          colorScheme: colorScheme,
          textTheme: textTheme,
          isDownloading: isDownloading,
          isError: isError,
        );
      },
    );
  }

  Widget _buildPlaylistsTab(
    List<Playlist> playlists,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    if (playlists.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Semantics(
              label: 'No playlists',
              child: Icon(
                Icons.playlist_add,
                size: 64,
                color: colorScheme.outline.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'No playlists yet',
              style: textTheme.bodyLarge?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => _showCreatePlaylistDialog(context, ref, colorScheme, textTheme),
              style: ElevatedButton.styleFrom(
                backgroundColor: colorScheme.primary,
                foregroundColor: colorScheme.onPrimary,
              ),
              child: const Text('Create Playlist'),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
      itemCount: playlists.length,
      itemBuilder: (context, index) {
        final playlist = playlists[index];
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          elevation: 0,
          color: colorScheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: colorScheme.outlineVariant.withValues(alpha: 0.3),
            ),
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            leading: CircleAvatar(
              backgroundColor: colorScheme.primary.withValues(alpha: 0.1),
              child: Icon(Icons.playlist_play, color: colorScheme.primary),
            ),
            title: Text(
              playlist.name,
              style: textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 4.0),
              child: Text(
                '${playlist.downloadIds.length} items',
                style: textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
            ),
            trailing: Semantics(
              label: 'Open playlist',
              child: const Icon(Icons.chevron_right),
            ),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PlaylistDetailsScreen(playlistId: playlist.id),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _ThumbnailImage extends StatelessWidget {
  final String? url;
  final Widget fallback;

  const _ThumbnailImage({
    required this.url,
    required this.fallback,
  });

  @override
  Widget build(BuildContext context) {
    if (url == null || url!.trim().isEmpty) return fallback;
    final trimmed = url!.trim();
    // Decode at ~2x the on-screen thumbnail size instead of full
    // resolution: full-size decodes on scroll were the main scroll-jank
    // source in long libraries. RepaintBoundary keeps progress animations
    // elsewhere from repainting settled images.
    const cacheW = 360;
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return RepaintBoundary(
        child: Image.network(
          trimmed,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          cacheWidth: cacheW,
          errorBuilder: (context, error, stackTrace) => fallback,
        ),
      );
    }
    final path = trimmed.startsWith('file://') ? trimmed.substring(7) : trimmed;
    final file = File(path);
    if (!file.existsSync()) {
      return fallback;
    }
    return RepaintBoundary(
      child: Image.file(
        file,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        cacheWidth: cacheW,
        errorBuilder: (context, error, stackTrace) => fallback,
      ),
    );
  }
}

class _LibraryGridCard extends ConsumerWidget {
  final DownloadItem item;
  final ColorScheme colorScheme;
  final TextTheme textTheme;
  final bool isDownloading;
  final bool isError;

  const _LibraryGridCard({
    required this.item,
    required this.colorScheme,
    required this.textTheme,
    this.isDownloading = false,
    this.isError = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final label = isError
        ? '${item.title}, failed'
        : '${item.title}, ${isDownloading ? 'downloading' : 'completed'}';

    return Semantics(
      label: label,
      child: Card(
        elevation: 0,
        color: colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: isError
                ? colorScheme.error.withValues(alpha: 0.4)
                : colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  gradient: isError
                      ? LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            colorScheme.errorContainer.withValues(alpha: 0.4),
                            colorScheme.error.withValues(alpha: 0.15),
                          ],
                        )
                      : LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            colorScheme.primary.withValues(alpha: 0.3),
                            colorScheme.tertiary.withValues(alpha: 0.3),
                          ],
                        ),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _ThumbnailImage(
                      // Local sidecar first (offline/privacy-first), remote
                      // URL as fallback. _ThumbnailImage already handles
                      // both + missing-file fallback (task 03).
                      url: item.thumbnailPath ?? item.thumbnailUrl,
                      fallback: Center(
                        child: isError
                            ? Icon(
                                Icons.error_outline,
                                size: 40,
                                color: colorScheme.error,
                              )
                            : Icon(
                                Icons.movie_outlined,
                                size: 40,
                                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                              ),
                      ),
                    ),
                    if (isDownloading)
                      Container(
                        color: Colors.black.withValues(alpha: 0.45),
                        child: Center(
                          child: SizedBox(
                            width: 40,
                            height: 40,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                CircularProgressIndicator(
                                  value: item.progress,
                                  strokeWidth: 3,
                                  color: colorScheme.primary,
                                  backgroundColor: colorScheme.surfaceContainerHighest,
                                ),
                                Text(
                                  '${(item.progress * 100).toInt()}%',
                                  style: textTheme.mono.copyWith(
                                    color: colorScheme.primary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    if (isError && item.thumbnailUrl != null && item.thumbnailUrl!.trim().isNotEmpty)
                      Container(
                        color: colorScheme.errorContainer.withValues(alpha: 0.4),
                        child: Center(
                          child: Icon(
                            Icons.error_outline,
                            size: 40,
                            color: colorScheme.error,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    style: textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  if (isError) ...[
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: colorScheme.errorContainer,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'Failed',
                            style: textTheme.labelSmall?.copyWith(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: colorScheme.onErrorContainer,
                            ),
                          ),
                        ),
                        const Spacer(),
                        Semantics(
                          label: 'Retry download',
                          child: IconButton(
                            icon: Icon(
                              Icons.refresh,
                              size: 18,
                              color: colorScheme.error,
                            ),
                            onPressed: () {
                              ref.read(downloadProvider.notifier).retryDownload(item.id);
                            },
                            visualDensity: VisualDensity.compact,
                            tooltip: 'Retry',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                        ),
                      ],
                    ),
                    if (item.errorMessage != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        item.errorMessage!,
                        style: textTheme.mono.copyWith(
                          fontSize: 10,
                          color: colorScheme.error,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ] else if (isDownloading) ...[
                    Row(
                      children: [
                        Flexible(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              item.stageLabel != null
                                  ? item.stageLabel!
                                  : (item.totalBytes > 0
                                      ? '${_formatBytes(item.downloadedBytes)} / ${_formatBytes(item.totalBytes)}'
                                      : '${(item.progress * 100).toInt()}% downloading'),
                              style: textTheme.mono.copyWith(
                                fontSize: 10,
                                color: colorScheme.onPrimaryContainer,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ] else ...[
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            item.fileSize ?? 'Completed',
                            style: textTheme.mono.copyWith(
                              fontSize: 10,
                              color: colorScheme.onPrimaryContainer,
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
    );
  }
}

class _LibraryItem extends ConsumerWidget {
  final DownloadItem item;
  final ColorScheme colorScheme;
  final bool isDownloading;
  final bool isError;

  const _LibraryItem({
    required this.item,
    required this.colorScheme,
    this.isDownloading = false,
    this.isError = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;

    final label = isError
        ? '${item.title}, failed'
        : '${item.title}, ${isDownloading ? 'downloading' : 'completed'}';

    return Semantics(
      label: label,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Row(
          crossAxisAlignment: (isDownloading || isError)
              ? CrossAxisAlignment.center
              : CrossAxisAlignment.start,
          children: [
            Container(
              width: 128,
              height: 72,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: isError
                    ? colorScheme.errorContainer.withValues(alpha: 0.2)
                    : colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
                border: isError
                    ? Border.all(
                        color: colorScheme.error.withValues(alpha: 0.3),
                      )
                    : null,
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _ThumbnailImage(
                    // Local sidecar first (offline/privacy-first), remote
                    // URL as fallback (task 03).
                    url: item.thumbnailPath ?? item.thumbnailUrl,
                    fallback: Center(
                      child: isDownloading
                          ? const SizedBox.shrink()
                          : isError
                              ? Semantics(
                                  label: 'Failed',
                                  child: Icon(
                                    Icons.error_outline,
                                    color: colorScheme.error,
                                    size: 32,
                                  ),
                                )
                              : Semantics(
                                  label: 'Completed',
                                  child: Icon(
                                    Icons.image_outlined,
                                    color: colorScheme.outline.withValues(alpha: 0.4),
                                    size: 32,
                                  ),
                                ),
                    ),
                  ),
                  if (isDownloading)
                    Container(
                      color: item.thumbnailUrl != null && item.thumbnailUrl!.trim().isNotEmpty
                          ? Colors.black.withValues(alpha: 0.35)
                          : Colors.transparent,
                      child: Center(
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: colorScheme.primary.withValues(alpha: 0.2),
                          ),
                          child: Semantics(
                            label: 'Downloading',
                            child: Icon(
                              Icons.downloading,
                              color: colorScheme.primary,
                              size: 20,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (isError && item.thumbnailUrl != null && item.thumbnailUrl!.trim().isNotEmpty)
                    Container(
                      color: colorScheme.errorContainer.withValues(alpha: 0.4),
                      child: Center(
                        child: Semantics(
                          label: 'Failed',
                          child: Icon(
                            Icons.error_outline,
                            color: colorScheme.error,
                            size: 32,
                          ),
                        ),
                      ),
                    ),
                ],
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
                          style: textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isError)
                        Semantics(
                          label: 'Retry download',
                          child: IconButton(
                            icon: Icon(
                              Icons.refresh,
                              size: 20,
                              color: colorScheme.error,
                            ),
                            onPressed: () {
                              ref
                                  .read(downloadProvider.notifier)
                                  .retryDownload(item.id);
                            },
                            visualDensity: VisualDensity.compact,
                            tooltip: 'Retry',
                          ),
                        )
                      else if (!isDownloading)
                        Semantics(
                          label: 'Preview',
                          child: IconButton(
                            icon: Icon(
                              Icons.play_circle_outline,
                              size: 20,
                              color: colorScheme.primary,
                            ),
                            onPressed: () {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => MediaPreviewScreen(
                                    filePath: item.filePath,
                                    title: item.title,
                                    thumbnailUrl: item.thumbnailUrl,
                                  ),
                                ),
                              );
                            },
                            visualDensity: VisualDensity.compact,
                            tooltip: 'Preview',
                          ),
                        ),
                      DownloadOverflowButton(
                        item: item,
                        colorScheme: colorScheme,
                      ),
                    ],
                  ),
                  if (isDownloading) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: item.progress,
                        backgroundColor: colorScheme.surfaceContainerHighest,
                        valueColor:
                            AlwaysStoppedAnimation(colorScheme.primary),
                        minHeight: 4,
                      ),
                    ),
                    if (item.stageLabel != null) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: colorScheme.primaryContainer.withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.hourglass_top,
                                    size: 11,
                                    color: colorScheme.onPrimaryContainer),
                                const SizedBox(width: 4),
                                Text(
                                  item.stageLabel!,
                                  style: textTheme.labelSmall?.copyWith(
                                    fontSize: 10,
                                    color: colorScheme.onPrimaryContainer,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '${(item.progress * 100).toInt()} % downloading',
                          style: textTheme.mono.copyWith(
                            color: colorScheme.primary,
                          ),
                        ),
                        Text(
                          item.speed > 0
                              ? '${_formatSpeed(item.speed)} · ${_formatBytes(item.downloadedBytes)}/${_formatBytes(item.totalBytes)}'
                              : '${_formatBytes(item.downloadedBytes)}/${_formatBytes(item.totalBytes)}',
                          style: textTheme.mono.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ] else if (isError) ...[
                    const SizedBox(height: 6),
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
                      const SizedBox(height: 4),
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
                        Text(
                          item.completedDate ?? 'Unknown',
                          style: textTheme.mono.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          width: 4,
                          height: 4,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: colorScheme.outlineVariant,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          item.fileSize ?? '',
                          style: textTheme.mono.copyWith(
                            color: colorScheme.onSurfaceVariant,
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
    );
  }
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
