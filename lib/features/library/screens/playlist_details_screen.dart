import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/text_styles.dart';
import '../../../providers/batch_provider.dart';
import '../../../providers/download_provider.dart';
import '../../../providers/playlist_provider.dart';
import '../../home/screens/batch_download_screen.dart';

class PlaylistDetailsScreen extends ConsumerStatefulWidget {
  final String playlistId;

  const PlaylistDetailsScreen({
    super.key,
    required this.playlistId,
  });

  @override
  ConsumerState<PlaylistDetailsScreen> createState() => _PlaylistDetailsScreenState();
}

class _PlaylistDetailsScreenState extends ConsumerState<PlaylistDetailsScreen> {
  final Set<String> _selectedIds = {};

  bool get _allSelected => _selectedIds.length == _memberIds.length && _memberIds.isNotEmpty;

  List<String> _memberIds = [];

  void _showAddDownloadsDialog(
    BuildContext context,
    WidgetRef ref,
    Playlist playlist,
    List<String> completedIds,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    final available = completedIds
        .where((id) => !playlist.downloadIds.contains(id))
        .map((id) => ref.read(downloadItemProvider(id)))
        .whereType<DownloadItem>()
        .toList();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colorScheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Add Downloaded Files', style: textTheme.titleMedium),
        content: available.isEmpty
            ? const SizedBox(
                height: 100,
                child: Center(
                  child: Text(
                    'No new downloaded files available to add.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : SizedBox(
                width: double.maxFinite,
                height: 300,
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: available.length,
                  itemBuilder: (context, index) {
                    final item = available[index];
                    return ListTile(
                      title: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyMedium,
                      ),
                      subtitle: Text(
                        item.fileSize ?? 'Completed',
                        style: textTheme.labelSmall?.copyWith(color: colorScheme.outline),
                      ),
                      trailing: const Icon(Icons.add_circle_outline),
                      onTap: () {
                        ref
                            .read(playlistProvider.notifier)
                            .addDownloadToPlaylist(playlist.id, item.id);
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Added file to playlist')),
                        );
                      },
                    );
                  },
                ),
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showRenameDialog(
    BuildContext context,
    WidgetRef ref,
    Playlist playlist,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    final controller = TextEditingController(text: playlist.name);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colorScheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Rename Playlist', style: textTheme.titleMedium),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Playlist name',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final newName = controller.text.trim();
              if (newName.isNotEmpty) {
                ref.read(playlistProvider.notifier).renamePlaylist(playlist.id, newName);
                Navigator.pop(ctx);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _toggleSelectAll() {
    if (_allSelected) {
      setState(() => _selectedIds.clear());
    } else {
      setState(() => _selectedIds.addAll(_memberIds));
    }
  }

  void _toggleSelection(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _startBatchDownload(BuildContext context, WidgetRef ref) {
    if (_selectedIds.isEmpty) return;

    final selected = _memberIds
        .where((id) => _selectedIds.contains(id))
        .map((id) => ref.read(downloadItemProvider(id)))
        .whereType<DownloadItem>()
        .map((item) => BatchItem(url: item.url, title: item.title))
        .toList();

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BatchDownloadScreen(
          items: selected,
          playlistId: widget.playlistId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final playlists = ref.watch(playlistProvider);
    // Loop-3 O(1) rebuilds: structural sections only; rows watch items by id.
    final sections = ref.watch(downloadSectionsProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final playlistIndex = playlists.indexWhere((p) => p.id == widget.playlistId);
    if (playlistIndex == -1) {
      return const Scaffold(body: Center(child: Text('Playlist not found')));
    }
    final playlist = playlists[playlistIndex];

    _memberIds = playlist.downloadIds
        .where((id) => sections.allIds.contains(id))
        .toList();
    final completedIds = sections.completedIds;

    final hasSelection = _selectedIds.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(playlist.name),
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.primary,
        elevation: 0,
        actions: [
          if (_memberIds.isNotEmpty)
            IconButton(
              icon: Text(
                _allSelected ? 'Deselect All' : 'Select All',
                style: textTheme.labelSmall?.copyWith(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              onPressed: _toggleSelectAll,
            ),
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => _showRenameDialog(context, ref, playlist, colorScheme, textTheme),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.red),
            onPressed: () {
              ref.read(playlistProvider.notifier).deletePlaylist(playlist.id);
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Playlist deleted')),
              );
            },
          ),
        ],
      ),
      floatingActionButton: hasSelection
          ? FloatingActionButton.extended(
              onPressed: () => _startBatchDownload(context, ref),
              backgroundColor: colorScheme.primary,
              foregroundColor: colorScheme.onPrimary,
              icon: const Icon(Icons.download),
              label: Text('Download Selected (${_selectedIds.length})'),
            )
          : FloatingActionButton.extended(
              onPressed: () => _showAddDownloadsDialog(
                context,
                ref,
                playlist,
                completedIds,
                colorScheme,
                textTheme,
              ),
              backgroundColor: colorScheme.primary,
              foregroundColor: colorScheme.onPrimary,
              icon: const Icon(Icons.add),
              label: const Text('Add Files'),
            ),
      body: SafeArea(
        child: _memberIds.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Semantics(
                        label: 'No files in playlist',
                        child: Icon(
                          Icons.playlist_play,
                          size: 64,
                          color: colorScheme.outline.withValues(alpha: 0.5),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No files in this playlist yet',
                        style: textTheme.bodyLarge?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Tap "Add Files" to insert completed downloads.',
                        style: textTheme.bodyMedium?.copyWith(
                          color: colorScheme.outline,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              )
            : Column(
                children: [
                  if (hasSelection)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                      color: colorScheme.primaryContainer.withValues(alpha: 0.15),
                      child: Text(
                        '${_selectedIds.length} of ${_memberIds.length} selected',
                        style: textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurface,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
                      itemCount: _memberIds.length,
                      itemBuilder: (context, index) {
                        final id = _memberIds[index];
                        return _PlaylistRow(
                          id: id,
                          playlistId: playlist.id,
                          isSelected: _selectedIds.contains(id),
                          onToggleSelection: _toggleSelection,
                          onRemoved: () => _selectedIds.remove(id),
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Loop-3 O(1) rebuilds: subscribes to its own item only. The parent screen
/// watches structural sections, so progress ticks for other downloads never
/// rebuild this row.
class _PlaylistRow extends ConsumerWidget {
  final String id;
  final String playlistId;
  final bool isSelected;
  final ValueChanged<String> onToggleSelection;
  final VoidCallback onRemoved;

  const _PlaylistRow({
    required this.id,
    required this.playlistId,
    required this.isSelected,
    required this.onToggleSelection,
    required this.onRemoved,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = ref.watch(downloadItemProvider(id));
    if (item == null) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      color: isSelected
          ? colorScheme.primaryContainer.withValues(alpha: 0.08)
          : colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isSelected
              ? colorScheme.primary.withValues(alpha: 0.4)
              : colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      child: InkWell(
        onTap: () => onToggleSelection(item.id),
        borderRadius: BorderRadius.circular(12),
        child: ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          leading: Checkbox(
            value: isSelected,
            onChanged: (_) => onToggleSelection(item.id),
            activeColor: colorScheme.primary,
            checkColor: colorScheme.onPrimary,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          title: Text(
            item.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 6.0),
            child: Text(
              item.fileSize ?? 'Completed',
              style: textTheme.mono.copyWith(fontSize: 11),
            ),
          ),
          trailing: IconButton(
            icon:
                const Icon(Icons.remove_circle_outline, color: Colors.red),
            onPressed: () {
              ref
                  .read(playlistProvider.notifier)
                  .removeDownloadFromPlaylist(playlistId, item.id);
              onRemoved();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Removed file from playlist')),
              );
            },
          ),
        ),
      ),
    );
  }
}
