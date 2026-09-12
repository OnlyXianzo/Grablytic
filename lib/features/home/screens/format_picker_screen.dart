import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../core/theme/text_styles.dart';
import '../../../core/engine/engine_provider.dart';
import '../../../core/utils/app_logger.dart';
import '../../../core/utils/download_config.dart';
import '../../../core/utils/format_selector.dart';
import '../../../providers/download_provider.dart';
import '../../../providers/playlist_provider.dart';
import '../../../providers/preset_provider.dart';
import '../../../providers/settings_provider.dart';

const _uuid = Uuid();

class FormatPickerScreen extends ConsumerStatefulWidget {
  final String url;
  final String title;

  const FormatPickerScreen({
    super.key,
    required this.url,
    required this.title,
  });

  @override
  ConsumerState<FormatPickerScreen> createState() => _FormatPickerScreenState();
}

const _vpnKeywords = [
  'not available in your country',
  'sign in to confirm your age',
  'age-restricted',
  '403',
  'ssl',
  'handshake',
  'timeout',
  'name or service not known',
];

bool _isVpnSuggested(String error) {
  final lower = error.toLowerCase();
  return _vpnKeywords.any((kw) => lower.contains(kw));
}

class _FormatPickerScreenState extends ConsumerState<FormatPickerScreen> {
  String? _selectedVideoFormat;
  String? _selectedAudioFormat;
  String _selectedContainer = 'mkv';
  bool _isLoading = true;
  String? _error;
  bool _suggestsVpn = false;
  List<Map<String, dynamic>> _videoFormats = [];
  List<Map<String, dynamic>> _audioFormats = [];
  List<Map<String, dynamic>> _muxedFormats = [];
  String? _selectedMuxedFormat;
  String _fetchedTitle = '';
  String _thumbnailUrl = '';
  int? _durationSeconds;
  String _filterQuery = '';
  Playlist? _selectedPlaylist;
  bool _isStarting = false; // guard against duplicate download taps

  @override
  void initState() {
    super.initState();
    _fetchFormats();
  }

  void _showVpnDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(ctx).colorScheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.vpn_lock, color: Theme.of(ctx).colorScheme.error, size: 24),
            const SizedBox(width: 12),
            Text('Restricted Content', style: Theme.of(ctx).textTheme.titleMedium),
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

  Future<void> _fetchFormats() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _suggestsVpn = false;
    });

    try {
      final engine = ref.read(engineProvider);
      final result = await AppLogger.trace<Map<String, dynamic>>(
        'Fetch format options for ${widget.url}',
        () => engine.getFormats(
          url: widget.url,
          config: {
            'cookies_path': null,
            'proxy': null,
            'verbose': false,
          },
        ),
        tag: 'FormatPickerScreen',
      );

      if (result['success'] == true) {
        final formats = (result['formats'] as List).cast<Map<String, dynamic>>();
        _videoFormats = formats.where((f) => f['stream_type'] == 'video').toList();
        _audioFormats = formats.where((f) => f['stream_type'] == 'audio').toList();
        _muxedFormats = formats.where((f) => f['stream_type'] == 'muxed').toList();
        _fetchedTitle = result['title'] as String? ?? widget.title;
        _thumbnailUrl = result['thumbnail_url'] as String? ?? '';
        _durationSeconds = (result['duration_seconds'] as num?)?.toInt();
        
        final activePreset = ref.read(presetsProvider).activePreset;
        _selectedContainer = activePreset.preferredContainer;

        // P0: sort-then-first (never unsorted .first). Audio = max bitrate.
        _selectedAudioFormat = selectBestAudioFormat(_audioFormats);

        if (activePreset.audioOnly) {
          _selectedVideoFormat = null;
        } else {
          final targetHeight = targetHeightForCeiling(
            activePreset.qualityCeiling,
            activePreset.id,
          );

          _selectedVideoFormat = selectBestVideoFormat(
            _videoFormats,
            targetHeight: targetHeight,
            preferredCodec: activePreset.preferredCodec,
            fallbackRecommendedId:
                result['recommended_video_format_id'] as String?,
          );

          // For platforms with only muxed formats (Twitter, Instagram, etc.)
          if (_videoFormats.isEmpty && _muxedFormats.isNotEmpty) {
            _selectedMuxedFormat = _muxedFormats.first['format_id'] as String?;
            _selectedVideoFormat = null;
          }
        }
      } else {
        _error = result['error_message'] as String? ?? 'Failed to load formats';
        _suggestsVpn = _isVpnSuggested(_error!);
      }
    } catch (e) {
      _error = 'Error: $e';
      _suggestsVpn = _isVpnSuggested(_error!);
    }

    if (mounted) setState(() => _isLoading = false);
  }

  /// True when [fmt] matches every whitespace-separated token of the
  /// search query against height/format id/codec/container (e.g. "1080p",
  /// "vp9 1080", "251"). Empty query matches everything.
  bool _matchesFilter(Map<String, dynamic> fmt, bool isVideo) {
    final q = _filterQuery.trim().toLowerCase();
    if (q.isEmpty) return true;
    final height = fmt['height'];
    final haystack = StringBuffer()
      ..write(fmt['format_id'])
      ..write(' ')
      ..write(isVideo && height != null ? '${height}p' : '')
      ..write(' ')
      ..write(isVideo ? (fmt['vcodec'] ?? '') : (fmt['acodec'] ?? ''))
      ..write(' ')
      ..write(fmt['ext'] ?? '')
      ..write(' ')
      ..write(fmt['abr'] ?? '')
      ..write(' ')
      ..write(fmt['format_note'] ?? '');
    final hay = haystack.toString().toLowerCase();
    return q.split(RegExp(r'\s+')).every(hay.contains);
  }

  String _formatDuration(int? seconds) {
    if (seconds == null || seconds < 0) return '';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    if (m >= 60) return '${m ~/ 60}h ${m % 60}m';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _formatSize(int? bytes) {    if (bytes == null) return 'Unknown size';
    final double mb = bytes / (1024 * 1024);
    if (mb > 1024) {
      return '${(mb / 1024).toStringAsFixed(1)} GB';
    }
    return '${mb.toStringAsFixed(0)} MB';
  }

  Future<void> _startDownload() async {
    if (_selectedVideoFormat == null && _selectedAudioFormat == null && _selectedMuxedFormat == null) return;
    if (_isStarting) return; // prevent duplicate taps

    final notifier = ref.read(downloadProvider.notifier);
    if (notifier.isDownloading(widget.url)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Download already in progress for this link')),
      );
      return;
    }

    AppLogger.info('User initiated download for url: ${widget.url}', tag: 'FormatPickerScreen');
    setState(() => _isStarting = true);

    final downloadId = _uuid.v4();
    final engine = ref.read(engineProvider);

    final config = <String, dynamic>{
      'container': _selectedContainer,
      'explicit_format_id': _selectedMuxedFormat ?? _selectedVideoFormat,
      'explicit_audio_format_id': _selectedMuxedFormat != null ? null : _selectedAudioFormat,
      // P1: forward user settings under exact engine contract keys
      // (config.py DEFAULT_CFG). Nulls dropped so defaults survive the
      // {**DEFAULT_CFG, **config} merge in build_ydl_opts().
      ...settingsDownloadConfig(ref.read(settingsProvider)),
    };

    final result = await AppLogger.trace<Map<String, dynamic>>(
      'Start download for ${widget.url}',
      () => engine.startDownload(
        url: widget.url,
        downloadId: downloadId,
        config: config,
        networkType: 'wifi',
      ),
      tag: 'FormatPickerScreen',
    );

    if (result['success'] == true) {
      notifier.addDownload(
        DownloadItem(
          id: downloadId,
          title: _fetchedTitle.isNotEmpty ? _fetchedTitle : widget.title,
          url: widget.url,
          status: 'downloading',
          config: config,
          networkType: 'wifi',
        ),
      );

      if (_selectedPlaylist != null) {
        ref.read(playlistProvider.notifier).addDownloadToPlaylist(_selectedPlaylist!.id, downloadId);
      }

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Download started')),
        );
      }
    } else {
      if (mounted) setState(() => _isStarting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Format Picker'),
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.primary,
        elevation: 0,
        actions: [
          if (!_isLoading && _error == null)
            IconButton(
              icon: const Icon(Icons.preview_outlined),
              tooltip: 'Preview selection',
              onPressed: () => _showPreview(colorScheme, textTheme),
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
                          Semantics(
                            label: _suggestsVpn ? 'VPN required' : 'Error',
                            child: Icon(
                              _suggestsVpn ? Icons.vpn_lock : Icons.error_outline,
                              size: 48,
                              color: colorScheme.error,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(_error!, textAlign: TextAlign.center),
                          if (_suggestsVpn) ...[
                            const SizedBox(height: 16),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: colorScheme.errorContainer.withValues(alpha: 0.3),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                'This content may be restricted in your region. '
                                'Try using a VPN or proxy to access it.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: colorScheme.onErrorContainer,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextButton.icon(
                              onPressed: _showVpnDialog,
                              icon: const Icon(Icons.info_outline, size: 16),
                              label: const Text('Learn more'),
                            ),
                          ],
                          const SizedBox(height: 16),
                          OutlinedButton(
                            onPressed: _fetchFormats,
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _fetchedTitle.isNotEmpty ? _fetchedTitle : widget.title,
                          style: textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          widget.url,
                          style: textTheme.mono.copyWith(
                            color: colorScheme.outline,
                            fontSize: 12,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          decoration: InputDecoration(
                            hintText: 'Filter formats (e.g. 1080p, vp9 1080, 251)',
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: _filterQuery.isEmpty
                                ? null
                                : IconButton(
                                    icon: const Icon(Icons.clear),
                                    onPressed: () => setState(() => _filterQuery = ''),
                                  ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 12),
                          ),
                          onChanged: (v) => setState(() => _filterQuery = v),
                        ),
                        const SizedBox(height: 8),
                        if (_videoFormats.isNotEmpty)
                          _buildSectionTile(
                            title: 'VIDEO STREAMS',
                            count: _videoFormats.length,
                            selectedLabel: _selectedVideoFormat == null
                                ? null
                                : 'Selected: $_selectedVideoFormat',
                            initiallyExpanded: false,
                            colorScheme: colorScheme,
                            textTheme: textTheme,
                            children: [
                              for (final fmt in _videoFormats.where((f) => _matchesFilter(f, true)))
                                _buildFormatRow(fmt, true, colorScheme, textTheme),
                            ],
                          ),
                        if (_muxedFormats.isNotEmpty)
                          _buildSectionTile(
                            title: 'COMBINED STREAMS',
                            count: _muxedFormats.length,
                            selectedLabel: _selectedMuxedFormat == null
                                ? null
                                : 'Selected: $_selectedMuxedFormat',
                            initiallyExpanded: false,
                            colorScheme: colorScheme,
                            textTheme: textTheme,
                            children: [
                              for (final fmt in _muxedFormats.where((f) => _matchesFilter(f, false)))
                                _buildMuxedFormatRow(fmt, colorScheme, textTheme),
                            ],
                          ),
                        if (_audioFormats.isNotEmpty)
                          _buildSectionTile(
                            title: 'AUDIO STREAMS',
                            count: _audioFormats.length,
                            selectedLabel: _selectedAudioFormat == null
                                ? null
                                : 'Selected: $_selectedAudioFormat',
                            initiallyExpanded: false,
                            colorScheme: colorScheme,
                            textTheme: textTheme,
                            children: [
                              for (final fmt in _audioFormats.where((f) => _matchesFilter(f, false)))
                                _buildFormatRow(fmt, false, colorScheme, textTheme),
                            ],
                          ),
                        const SizedBox(height: 24),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Preferred Container:', style: textTheme.bodyMedium),
                            Semantics(
                              label: 'Preferred Container, currently $_selectedContainer',
                              child: DropdownButton<String>(
                                value: _selectedContainer,
                                dropdownColor: colorScheme.surfaceContainerHigh,
                                items: const [
                                  DropdownMenuItem(value: 'mkv', child: Text('MKV (Recommended)')),
                                  DropdownMenuItem(value: 'mp4', child: Text('MP4')),
                                  DropdownMenuItem(value: 'webm', child: Text('WebM')),
                                ],
                                onChanged: (val) {
                                  if (val != null) setState(() => _selectedContainer = val);
                                },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Add to Playlist:', style: textTheme.bodyMedium),
                            Semantics(
                              label: 'Add to Playlist, ${_selectedPlaylist != null ? _selectedPlaylist!.name : "none"} selected',
                              child: DropdownButton<Playlist?>(
                                value: _selectedPlaylist,
                                dropdownColor: colorScheme.surfaceContainerHigh,
                                hint: const Text('None'),
                                items: [
                                  const DropdownMenuItem<Playlist?>(
                                    value: null,
                                    child: Text('None'),
                                  ),
                                  ...ref.watch(playlistProvider).map((p) => DropdownMenuItem<Playlist?>(
                                        value: p,
                                        child: Text(p.name),
                                      )),
                                ],
                                onChanged: (val) {
                                  setState(() => _selectedPlaylist = val);
                                },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 32),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: (!_isStarting && (_selectedVideoFormat != null || _selectedAudioFormat != null || _selectedMuxedFormat != null))
                                ? _startDownload
                                : null,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: colorScheme.primary,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: const Text('Download Now'),
                          ),
                        ),
                      ],
                    ),
                  ),
      ),
    );
  }

  /// Preview dialog: thumbnail + title + current selection summary with
  /// a Download CTA. (Streaming playback needs a player dependency —
  /// tracked as follow-up; this covers "see what I'm getting".)
  void _showPreview(ColorScheme colorScheme, TextTheme textTheme) {
    final dur = _formatDuration(_durationSeconds);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colorScheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_thumbnailUrl.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(
                    _thumbnailUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) =>
                        const Icon(Icons.broken_image_outlined, size: 48),
                  ),
                ),
              const SizedBox(height: 12),
              Text(
                _fetchedTitle.isNotEmpty ? _fetchedTitle : widget.title,
                style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
              ),
              if (dur.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text('Duration: $dur', style: textTheme.labelSmall),
              ],
              const SizedBox(height: 8),
              Text(
                'Video: ${_selectedMuxedFormat ?? _selectedVideoFormat ?? '—'}\n'
                'Audio: ${_selectedMuxedFormat != null ? '(in combined)' : (_selectedAudioFormat ?? '—')}\n'
                'Container: $_selectedContainer',
                style: textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _startDownload();
            },
            child: const Text('Download'),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTile({
    required String title,
    required int count,
    required String? selectedLabel,
    required bool initiallyExpanded,
    required ColorScheme colorScheme,
    required TextTheme textTheme,
    required List<Widget> children,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        collapsedShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.3)),
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.3)),
        ),
        title: Text(
          '$title ($count)',
          style: textTheme.labelSmall?.copyWith(
            color: colorScheme.primary,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.5,
          ),
        ),
        subtitle: selectedLabel == null
            ? null
            : Text(selectedLabel, style: textTheme.labelSmall),
        childrenPadding: const EdgeInsets.only(top: 8),
        children: children.isEmpty
            ? [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text('No formats match the filter.',
                      style: textTheme.labelSmall),
                ),
              ]
            : children,
      ),
    );
  }

  Widget _buildFormatRow(
    Map<String, dynamic> fmt,
    bool isVideo,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    final formatId = fmt['format_id'] as String;
    final isSelected = isVideo
        ? _selectedVideoFormat == formatId
        : _selectedAudioFormat == formatId;
    final isHdr = isVideo && fmt['dynamic_range'] != 'SDR';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isSelected
            ? colorScheme.primaryContainer.withValues(alpha: 0.1)
            : colorScheme.surfaceContainerLowest,
        border: Border.all(
          color: isSelected
              ? colorScheme.primary
              : colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Semantics(
        button: true,
        label: '${isVideo ? "Video" : "Audio"} format $formatId${isSelected ? ", selected" : ""}',
        child: InkWell(
          onTap: () => setState(() {
            if (isVideo) {
              _selectedVideoFormat = formatId;
            } else {
              _selectedAudioFormat = formatId;
            }
          }),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                _buildRadio(isSelected, formatId, colorScheme),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            isVideo
                                ? '$formatId · ${fmt['height'] != null ? '${fmt['height']}p' : ''}${fmt['fps'] != null ? '${fmt['fps']}' : ''}'
                                : '$formatId · ${fmt['acodec'] ?? 'Audio'} · ${fmt['abr'] != null ? '${(fmt['abr'] as num).toInt()} kbps' : (fmt['tbr'] != null ? '${(fmt['tbr'] as num).toInt()} kbps' : 'unknown')}',
                            style: textTheme.mono.copyWith(fontWeight: FontWeight.bold),
                          ),
                          if (isHdr) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: colorScheme.tertiaryContainer,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                fmt['dynamic_range'],
                                style: textTheme.labelSmall?.copyWith(
                                  color: colorScheme.onTertiaryContainer,
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      Text(
                        isVideo
                            ? '${fmt['vcodec']} · ${fmt['ext']} · ${_formatSize(fmt['filesize'])}'
                            : '${fmt['ext']} · ${_formatSize(fmt['filesize'])}',
                        style: textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant),
                      ),
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

  Widget _buildMuxedFormatRow(
    Map<String, dynamic> fmt,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    final formatId = fmt['format_id'] as String;
    final isSelected = _selectedMuxedFormat == formatId;
    final height = fmt['height'];
    final note = fmt['format_note'] as String? ?? '';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isSelected
            ? colorScheme.primaryContainer.withValues(alpha: 0.1)
            : colorScheme.surfaceContainerLowest,
        border: Border.all(
          color: isSelected
              ? colorScheme.primary
              : colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Semantics(
        button: true,
        label: 'Combined format $formatId${isSelected ? ", selected" : ""}',
        child: InkWell(
          onTap: () => setState(() {
            _selectedMuxedFormat = formatId;
            _selectedVideoFormat = null;
            _selectedAudioFormat = null;
          }),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                _buildRadio(isSelected, formatId, colorScheme),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        height != null
                            ? '$formatId · ${height}p${note.isNotEmpty ? ' · $note' : ''}'
                            : '$formatId${note.isNotEmpty ? ' · $note' : ''}',
                        style: textTheme.mono.copyWith(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        '${fmt['vcodec']} + ${fmt['acodec']} · ${fmt['ext']} · ${_formatSize(fmt['filesize'] as int?)}',
                        style: textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant),
                      ),
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

  Widget _buildRadio(bool isSelected, String formatId, ColorScheme colorScheme) {
    return Semantics(
      label: 'Select format $formatId',
      button: true,
      selected: isSelected,
      child: Container(
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: isSelected ? colorScheme.primary : colorScheme.outline.withValues(alpha: 0.5),
            width: 2,
          ),
        ),
        alignment: Alignment.center,
        child: isSelected
            ? Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colorScheme.primary,
                ),
              )
            : null,
      ),
    );
  }
}
