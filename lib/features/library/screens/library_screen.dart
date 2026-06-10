import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/text_styles.dart';
import '../../../features/home/screens/media_preview_screen.dart';
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

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      setState(() {}); // Rebuild to show/hide FAB based on active tab
    });
  }

  @override
  void dispose() {
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
      floatingActionButton: _tabController.index == 1
          ? FloatingActionButton.extended(
              onPressed: () => _showCreatePlaylistDialog(context, ref, colorScheme, textTheme),
              backgroundColor: colorScheme.primary,
              foregroundColor: colorScheme.onPrimary,
              icon: const Icon(Icons.playlist_add),
              label: const Text('New Playlist'),
            )
          : null,
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
    final pending = downloads.where((d) => d.status == 'downloading').toList();
    final completed = downloads.where((d) => d.status == 'completed').toList();

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
          ? _buildGridView(completed, pending, colorScheme, textTheme)
          : _buildListView(completed, pending, colorScheme, textTheme),
    );
  }

  Widget _buildListView(
    List<DownloadItem> completed,
    List<DownloadItem> pending,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    return ListView(
      key: const ValueKey('list'),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
      children: [
        if (pending.isNotEmpty) ...[
          Text(
            'PENDING',
            style: textTheme.labelSmall?.copyWith(
              color: colorScheme.primary,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          ...pending.map((item) => _LibraryItem(
                item: item,
                colorScheme: colorScheme,
                isDownloading: true,
              )),
          const SizedBox(height: 32),
        ],
        if (completed.isNotEmpty) ...[
          Text(
            'DOWNLOADED',
            style: textTheme.labelSmall?.copyWith(
              color: colorScheme.primary,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          ...completed.map((item) => _LibraryItem(
                item: item,
                colorScheme: colorScheme,
                isDownloading: false,
              )),
        ],
      ],
    );
  }

  Widget _buildGridView(
    List<DownloadItem> completed,
    List<DownloadItem> pending,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    final all = [...pending, ...completed];
    return GridView.builder(
      key: const ValueKey('grid'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.7,
      ),
      itemCount: all.length,
      itemBuilder: (context, index) {
        final item = all[index];
        return _LibraryGridCard(
          item: item,
          colorScheme: colorScheme,
          textTheme: textTheme,
          isDownloading: item.status == 'downloading',
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

class _LibraryGridCard extends StatelessWidget {
  final DownloadItem item;
  final ColorScheme colorScheme;
  final TextTheme textTheme;
  final bool isDownloading;

  const _LibraryGridCard({
    required this.item,
    required this.colorScheme,
    required this.textTheme,
    required this.isDownloading,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '${item.title}, ${isDownloading ? 'downloading' : 'completed'}',
      child: Card(
        elevation: 0,
        color: colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.3),
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
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      colorScheme.primary.withValues(alpha: 0.3),
                      colorScheme.tertiary.withValues(alpha: 0.3),
                    ],
                  ),
                ),
                child: Center(
                  child: isDownloading
                      ? SizedBox(
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
                        )
                      : Icon(
                          Icons.movie_outlined,
                          size: 40,
                          color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                        ),
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
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          item.fileSize ?? 'N/A',
                          style: textTheme.mono.copyWith(
                            fontSize: 10,
                            color: colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LibraryItem extends StatelessWidget {
  final DownloadItem item;
  final ColorScheme colorScheme;
  final bool isDownloading;

  const _LibraryItem({
    required this.item,
    required this.colorScheme,
    required this.isDownloading,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Semantics(
      label: '${item.title}, ${isDownloading ? 'downloading' : 'completed'}',
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Row(
          crossAxisAlignment: isDownloading ? CrossAxisAlignment.center : CrossAxisAlignment.start,
          children: [
            Container(
              width: 128,
              height: 72,
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
              ),
              child: isDownloading
                  ? Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
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
                      ],
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
                      if (!isDownloading)
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
                      Semantics(
                        label: 'More options',
                        child: Icon(
                          Icons.more_vert,
                          size: 18,
                          color: colorScheme.onSurfaceVariant,
                        ),
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
                        '${_formatBytes(item.downloadedBytes)}/${_formatBytes(item.totalBytes)}',
                        style: textTheme.mono.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
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

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / 1048576).toStringAsFixed(1)} MB';
  }
}
