import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../core/engine/engine_provider.dart';
import '../../../core/utils/app_logger.dart';
import '../../../core/utils/download_config.dart';
import '../../../core/utils/playlist_selection.dart';
import '../../../core/utils/schedule_guard.dart';
import '../../../providers/download_provider.dart';
import '../../../providers/metered_guard.dart';
import '../../../providers/preset_provider.dart';
import '../../../providers/settings_provider.dart';

const _uuid = Uuid();

/// Remote-playlist entry picker (03-B UI wiring).
///
/// Pushed instead of [FormatPickerScreen] when a raw URL matches
/// [isPlaylistUrl] (paste + share-intent paths). Fetches
/// `EngineService.getPlaylistInfo` — previously zero Dart callers — and
/// turns the tap selection into the exact config keys the engine already
/// parses (`playlist_items` 1-based string + `playlist_rev` /
/// `playlist_rand` flags, via [playlistDownloadConfig]), then starts ONE
/// download through the existing `startDownload` path so task 06's queue
/// admits it like any other download (one queue slot per playlist
/// request). The download archive stays engine-transparent (`use_archive`
/// from settings still applies — no archive toggle here).
class PlaylistSelectionScreen extends ConsumerStatefulWidget {
  final String url;
  final String title;

  const PlaylistSelectionScreen({
    super.key,
    required this.url,
    String? title,
  }) : title = title ?? url;

  @override
  ConsumerState<PlaylistSelectionScreen> createState() =>
      _PlaylistSelectionScreenState();
}

class _PlaylistSelectionScreenState
    extends ConsumerState<PlaylistSelectionScreen> {
  bool _isLoading = true;
  String? _error;
  String _playlistTitle = '';
  List<Map<String, dynamic>> _entries = [];
  final Set<int> _selected = {};
  bool _reverse = false;
  bool _shuffle = false;
  bool _isStarting = false;

  @override
  void initState() {
    super.initState();
    _loadPlaylist();
  }

  List<Map<String, dynamic>> get _available =>
      _entries.where((e) => e['is_available'] != false).toList();

  bool get _allSelected =>
      _available.isNotEmpty && _selected.length == _available.length;

  int _entryIndex(Map<String, dynamic> e) => (e['index'] as num).toInt();

  Future<void> _loadPlaylist() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final engine = ref.read(engineProvider);
      final result = await AppLogger.trace<Map<String, dynamic>>(
        'Fetch playlist info for ${widget.url}',
        () => engine.getPlaylistInfo(
          url: widget.url,
          config: const {
            'cookies_path': null,
            'proxy': null,
            'verbose': false,
          },
        ),
        tag: 'PlaylistSelectionScreen',
      );
      if (!mounted) return;
      if (result['success'] == true) {
        final entries =
            ((result['entries'] as List?) ?? const []).whereType<Map>().map(
                Map<String, dynamic>.from).toList();
        setState(() {
          _playlistTitle =
              result['title'] as String? ?? widget.title;
          _entries = entries;
          // Default: every downloadable entry (preserves the old
          // whole-playlist behavior; the user narrows it down).
          // Unavailable entries are never pre-selected.
          _selected
            ..clear()
            ..addAll(_available.map(_entryIndex));
          _isLoading = false;
        });
      } else {
        setState(() {
          _error = result['error_message'] as String? ??
              'Could not load playlist';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Error: $e';
        _isLoading = false;
      });
    }
  }

  void _toggleSelectAll() {
    setState(() {
      if (_allSelected) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(_available.map(_entryIndex));
      }
    });
  }

  void _toggleSelection(int index, bool available) {
    if (!available) return;
    setState(() {
      if (_selected.contains(index)) {
        _selected.remove(index);
      } else {
        _selected.add(index);
      }
    });
  }

  Future<bool> _confirmOutsideSchedule(AppSettings settings) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Outside scheduled window'),
        content: Text(
          'Your download schedule is ${scheduleSummary(settings)}.\n\n'
          'Start this playlist download now anyway?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Wait'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Start anyway'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _startDownload() async {
    if (_selected.isEmpty || _isStarting) return;

    final notifier = ref.read(downloadProvider.notifier);
    if (notifier.isDownloading(widget.url)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Download already in progress for this link')),
      );
      return;
    }

    final settings = ref.read(settingsProvider);
    if (!isWithinScheduleWindow(settings, DateTime.now()) && mounted) {
      final go = await _confirmOutsideSchedule(settings);
      if (!mounted || !go) return;
    }

    // Metered gate (Seal parity): explicit tap, but Wi-Fi Only is on —
    // confirm on metered links instead of silently spending data.
    if (mounted &&
        !await ensureUnmeteredDownload(context: context, ref: ref)) {
      return;
    }

    AppLogger.info(
        'User initiated playlist download for url: ${widget.url} '
        '(${_selected.length} entries)',
        tag: 'PlaylistSelectionScreen');
    setState(() => _isStarting = true);

    final downloadId = _uuid.v4();
    final engine = ref.read(engineProvider);
    final activePreset = ref.read(presetsProvider).activePreset;
    // Ascending playlist order; reverse/shuffle travel as engine flags
    // (yt-dlp selects by index, then reverses/shuffles the selected set).
    final ordered = _selected.toList()..sort();

    final config = <String, dynamic>{
      'container': activePreset.preferredContainer,
      'quality_ceiling': activePreset.qualityCeiling,
      'audio_only': activePreset.audioOnly,
      ...settingsDownloadConfig(settings),
      ...playlistDownloadConfig(
        selectedIndices: ordered,
        reverse: _reverse,
        shuffle: _shuffle,
      ),
    };

    final result = await AppLogger.trace<Map<String, dynamic>>(
      'Start playlist download for ${widget.url}',
      () => engine.startDownload(
        url: widget.url,
        downloadId: downloadId,
        config: config,
        networkType: 'wifi',
      ),
      tag: 'PlaylistSelectionScreen',
    );

    if (!mounted) return;
    if (result['success'] == true) {
      final wasQueued = result['queued'] == true;
      notifier.addDownload(
        DownloadItem(
          id: downloadId,
          title: _playlistTitle.isNotEmpty ? _playlistTitle : widget.title,
          url: widget.url,
          status: wasQueued ? 'queued' : 'downloading',
          config: config,
          networkType: 'wifi',
        ),
      );
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(wasQueued
                ? 'Queued — starts when a slot frees up'
                : 'Playlist download started')),
      );
    } else {
      setState(() => _isStarting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not start playlist download')),
      );
    }
  }

  String _formatDuration(dynamic seconds) {
    if (seconds is! num || seconds < 0) return '';
    final m = seconds.toInt() ~/ 60;
    final s = seconds.toInt() % 60;
    if (m >= 60) return '${m ~/ 60}h ${m % 60}m';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _playlistTitle.isNotEmpty ? _playlistTitle : 'Playlist',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.primary,
        elevation: 0,
        actions: [
          if (!_isLoading && _error == null && _available.isNotEmpty)
            TextButton(
              key: const Key('playlist-select-all'),
              onPressed: _toggleSelectAll,
              child: Text(
                _allSelected ? 'Deselect All' : 'Select All',
                style: textTheme.labelSmall?.copyWith(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.error_outline,
                              size: 48, color: colorScheme.error),
                          const SizedBox(height: 16),
                          Text(_error!, textAlign: TextAlign.center),
                          const SizedBox(height: 16),
                          OutlinedButton(
                            onPressed: _loadPlaylist,
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                  )
                : Column(
                    children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 10),
                        color: colorScheme.primaryContainer
                            .withValues(alpha: 0.15),
                        child: Text(
                          '${_selected.length} of ${_available.length} downloadable '
                          'selected (${_entries.length} total)',
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurface,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      SwitchListTile(
                        key: const Key('playlist-reverse'),
                        title: const Text('Reverse order'),
                        subtitle: const Text(
                            'Download selected entries last-to-first'),
                        value: _reverse,
                        onChanged: (v) => setState(() {
                          _reverse = v;
                          if (v) _shuffle = false;
                        }),
                      ),
                      SwitchListTile(
                        key: const Key('playlist-shuffle'),
                        title: const Text('Shuffle order'),
                        subtitle:
                            const Text('Download selected entries shuffled'),
                        value: _shuffle,
                        onChanged: (v) => setState(() {
                          _shuffle = v;
                          if (v) _reverse = false;
                        }),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: ListView.builder(
                          padding:
                              const EdgeInsets.fromLTRB(20, 12, 20, 100),
                          itemCount: _entries.length,
                          itemBuilder: (context, i) {
                            final entry = _entries[i];
                            final index = _entryIndex(entry);
                            final available =
                                entry['is_available'] != false;
                            final isSelected =
                                _selected.contains(index);
                            final dur = _formatDuration(
                                entry['duration_seconds']);
                            return Card(
                              margin:
                                  const EdgeInsets.only(bottom: 10),
                              elevation: 0,
                              color: isSelected
                                  ? colorScheme.primaryContainer
                                      .withValues(alpha: 0.08)
                                  : colorScheme.surfaceContainerLow,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: BorderSide(
                                  color: isSelected
                                      ? colorScheme.primary
                                          .withValues(alpha: 0.4)
                                      : colorScheme.outlineVariant
                                          .withValues(alpha: 0.3),
                                ),
                              ),
                              child: InkWell(
                                key: Key('playlist-entry-$index'),
                                onTap: () =>
                                    _toggleSelection(index, available),
                                borderRadius: BorderRadius.circular(12),
                                child: Opacity(
                                  opacity: available ? 1.0 : 0.55,
                                  child: ListTile(
                                    contentPadding:
                                        const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 6),
                                    leading: Checkbox(
                                      value: isSelected,
                                      // Unavailable entries are visible but
                                      // non-selectable (greyed, not hidden).
                                      onChanged: available
                                          ? (_) => _toggleSelection(
                                              index, available)
                                          : null,
                                      activeColor:
                                          colorScheme.primary,
                                      checkColor:
                                          colorScheme.onPrimary,
                                      shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(4),
                                      ),
                                    ),
                                    title: Text(
                                      '${entry['title'] ?? 'Video $index'}',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: textTheme.bodyMedium?.copyWith(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    subtitle: Text(
                                      available
                                          ? 'Video $index${dur.isNotEmpty ? ' · $dur' : ''}'
                                          : 'Video $index · Unavailable '
                                              '(deleted/private)',
                                      style: textTheme.labelSmall?.copyWith(
                                        color: available
                                            ? colorScheme.outline
                                            : colorScheme.error,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
      ),
      bottomNavigationBar: _isLoading || _error != null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    key: const Key('playlist-download-cta'),
                    onPressed: (_selected.isNotEmpty && !_isStarting)
                        ? _startDownload
                        : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: colorScheme.primary,
                      foregroundColor: Colors.white,
                      padding:
                          const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(
                        'Download ${_selected.length} selected'),
                  ),
                ),
              ),
            ),
    );
  }
}
