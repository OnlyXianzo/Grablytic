// ignore_for_file: unused_element, curly_braces_in_flow_control_structures, unnecessary_underscores
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';
import 'package:uuid/uuid.dart';

import '../../../providers/download_provider.dart';
import '../../../providers/engine_status_provider.dart';
import '../../../providers/preset_provider.dart';
import '../../../providers/settings_provider.dart';
import '../../../core/engine/engine_provider.dart';
import '../../../core/engine/extraction_cache.dart';
import '../../../core/theme/text_styles.dart';
import '../../../core/utils/app_logger.dart';
import '../../../core/utils/download_config.dart';
import '../../../core/utils/playlist_selection.dart';
import '../screens/format_picker_screen.dart';
import '../screens/playlist_selection_screen.dart';

/// Share-intent landing sheet with preview + direct download (Phase 7).
///
/// Previously the sheet only offered "Choose quality & download" with no
/// playback. Now it fetches a lightweight preview (thumbnail + stream)
/// and offers both inline playback and a one-tap direct download using
/// the active preset, without entering the full format picker.
class ShareIntentSheet extends ConsumerStatefulWidget {
  final String url;
  const ShareIntentSheet({super.key, required this.url});

  @override
  ConsumerState<ShareIntentSheet> createState() => _ShareIntentSheetState();
}

class _ShareIntentSheetState extends ConsumerState<ShareIntentSheet> {
  String? _thumbnailUrl;
  Map<String, dynamic>? _previewStream;
  VideoPlayerController? _previewController;
  bool _isPreviewInitializing = false;
  bool _isPreviewPlaying = false;
  bool _isPreviewUnavailable = false;
  bool _isLoadingPreview = true;
  bool _isDirectDownloading = false;

  @override
  void initState() {
    super.initState();
    // Lazy preview: first paint is instant with URL + buttons; thumbnail
    // comes from cache if already extracted, otherwise fetched only when
    // the user taps Play. This keeps showModalBottomSheet <100ms per
    // Flutter perf guidance (avoid heavy children during slide-up).
    _loadCachedThumbOnly();
  }

  void _loadCachedThumbOnly() {
    try {
      final cached = ExtractionCache.instance.get(widget.url);
      if (cached != null && cached['success'] == true) {
        _applyPreview(cached);
      }
    } catch (_) {}
    if (mounted) setState(() => _isLoadingPreview = false);
  }

  Future<void> _ensurePreviewLoaded() async {
    if (_previewStream != null || isPlaylistUrl(widget.url)) return;
    if (_isLoadingPreview) return;
    setState(() => _isLoadingPreview = true);
    try {
      final engine = ref.read(engineProvider);
      // Check engine ready before heavy getFormats (Yt-dlp init can be 10s)
      final status = ref.read(engineStatusProvider).valueOrNull;
      if (status != null && !status.ready) {
        setState(() => _isPreviewUnavailable = true);
        return;
      }
      final result = await ExtractionCache.instance.getOrFetch(
        widget.url,
        () => engine.getFormats(url: widget.url, config: const {'cookies_path': null, 'proxy': null, 'verbose': false}),
      );
      if (!mounted) return;
      _applyPreview(result);
    } catch (_) {
      if (mounted) setState(() => _isPreviewUnavailable = true);
    } finally {
      if (mounted) setState(() => _isLoadingPreview = false);
    }
  }

  @override
  void dispose() {
    _previewController?.dispose();
    super.dispose();
  }

  Future<void> _loadPreview() async {
    try {
      final cached = ExtractionCache.instance.get(widget.url);
      if (cached != null && cached['success'] == true) {
        _applyPreview(cached);
        if (mounted) setState(() => _isLoadingPreview = false);
        return;
      }
      final engine = ref.read(engineProvider);
      final result = await ExtractionCache.instance.getOrFetch(
        widget.url,
        () => engine.getFormats(url: widget.url, config: const {'cookies_path': null, 'proxy': null, 'verbose': false}),
      );
      if (!mounted) return;
      _applyPreview(result);
    } catch (_) {
      if (mounted) setState(() => _isPreviewUnavailable = true);
    } finally {
      if (mounted) setState(() => _isLoadingPreview = false);
    }
  }

  void _applyPreview(Map<String, dynamic> result) {
    if (result['success'] == true) {
      _thumbnailUrl = result['thumbnail_url'] as String?;
      if (result['preview_stream'] is Map) {
        _previewStream = Map<String, dynamic>.from(result['preview_stream'] as Map);
        _isPreviewUnavailable = false;
      } else {
        _previewStream = null;
        _isPreviewUnavailable = true;
      }
    } else {
      _isPreviewUnavailable = true;
    }
  }

  Future<void> _togglePreviewPlay() async {
    // Lazy: if preview not yet fetched (heavy getFormats), fetch now only on Play tap
    if (_previewStream == null) {
      await _ensurePreviewLoaded();
      if (_previewStream == null || (_previewStream!['url'] as String?)?.isEmpty != false) {
        if (mounted) setState(() => _isPreviewUnavailable = true);
        return;
      }
    } else if ((_previewStream!['url'] as String?)?.isEmpty != false) {
      if (mounted) setState(() => _isPreviewUnavailable = true);
      return;
    }
    if (_previewController != null && _previewController!.value.isInitialized) {
      if (_previewController!.value.isPlaying) {
        await _previewController!.pause();
        if (mounted) setState(() => _isPreviewPlaying = false);
      } else {
        await _previewController!.play();
        if (mounted) setState(() => _isPreviewPlaying = true);
      }
      return;
    }
    if (_isPreviewInitializing) return;
    setState(() {
      _isPreviewInitializing = true;
      _isPreviewUnavailable = false;
    });
    try {
      final urlStr = _previewStream!['url'] as String;
      final headersRaw = _previewStream!['headers'];
      final headers = <String, String>{};
      if (headersRaw is Map) {
        for (final e in headersRaw.entries) {
          if (e.key != null && e.value != null) headers[e.key.toString()] = e.value.toString();
        }
      }
      final controller = VideoPlayerController.networkUrl(Uri.parse(urlStr), httpHeaders: headers);
      await controller.initialize();
      if (!mounted) {
        controller.dispose();
        return;
      }
      controller.addListener(() {
        if (!mounted) return;
        if (controller.value.hasError) {
          setState(() {
            _isPreviewUnavailable = true;
            _isPreviewPlaying = false;
          });
          return;
        }
        final isPlaying = controller.value.isPlaying;
        if (_isPreviewPlaying != isPlaying) setState(() => _isPreviewPlaying = isPlaying);
      });
      await controller.play();
      if (mounted) {
        setState(() {
          _previewController = controller;
          _isPreviewInitializing = false;
          _isPreviewPlaying = true;
        });
      } else {
        controller.dispose();
      }
    } catch (_) {
      if (mounted) setState(() {
        _isPreviewInitializing = false;
        _isPreviewUnavailable = true;
      });
    }
  }

  void _continueToPicker(BuildContext context) {
    final navigator = Navigator.of(context);
    navigator.pop();
    final target = isPlaylistUrl(widget.url)
        ? PlaylistSelectionScreen(url: widget.url, title: widget.url)
        : FormatPickerScreen(url: widget.url, title: widget.url);
    navigator.push(MaterialPageRoute(builder: (_) => target));
  }

  Future<void> _directDownload() async {
    if (_isDirectDownloading) return;
    setState(() => _isDirectDownloading = true);
    try {
      final engine = ref.read(engineProvider);
      final settings = ref.read(settingsProvider);
      final preset = ref.read(presetsProvider).activePreset;
      final notifier = ref.read(downloadProvider.notifier);
      final downloadId = const Uuid().v4();
      final config = <String, dynamic>{
        'container': preset.preferredContainer,
        ...settingsDownloadConfig(settings),
        'quality_ceiling': preset.qualityCeiling,
        if (preset.audioOnly) 'audio_only': true,
      };
      final res = await engine.startDownload(url: widget.url, downloadId: downloadId, config: config, networkType: 'wifi');
      if (res['success'] == true) {
        notifier.addDownload(DownloadItem(
          id: downloadId,
          title: widget.url,
          url: widget.url,
          status: res['queued'] == true ? 'queued' : 'downloading',
          config: config,
          networkType: 'wifi',
          thumbnailUrl: _thumbnailUrl,
        ));
        if (mounted) {
          Navigator.pop(context);
          final cs = Theme.of(context).colorScheme;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(res['queued'] == true ? 'Queued — starts when a slot frees up' : 'Download started', style: TextStyle(color: cs.onInverseSurface)),
            backgroundColor: cs.inverseSurface,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ));
          try {
            await engine.showSuccessNotification(downloadId: downloadId, title: 'Download started', message: widget.url);
          } catch (_) {}
        }
      } else {
        if (mounted) {
          setState(() => _isDirectDownloading = false);
          final cs = Theme.of(context).colorScheme;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not start download', style: TextStyle(color: cs.onInverseSurface)),
            backgroundColor: cs.inverseSurface,
            behavior: SnackBarBehavior.floating,
          ));
          try {
            await engine.showErrorNotification(downloadId: downloadId, title: 'Download failed', error: res['error_message']?.toString() ?? 'Could not start download');
          } catch (_) {}
        }
      }
    } catch (e) {
      AppLogger.warn('Direct download failed: $e', tag: 'ShareIntentSheet');
      if (mounted) setState(() => _isDirectDownloading = false);
    }
  }

  Widget _buildThumbnail(ColorScheme cs) {
    if (_isLoadingPreview) {
      return Container(
        width: double.infinity,
        height: 160,
        decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(12)),
        child: const Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }
    final hasThumb = _thumbnailUrl != null && _thumbnailUrl!.isNotEmpty;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _isPreviewUnavailable ? null : _togglePreviewPlay,
          child: SizedBox(
            width: double.infinity,
            height: 160,
            child: Stack(
              fit: StackFit.expand,
              children: [
                hasThumb
                    ? Image.network(_thumbnailUrl!, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Container(color: cs.surfaceContainerHigh, child: Icon(Icons.movie_outlined, color: cs.outline)))
                    : Container(color: cs.surfaceContainerHigh, child: Icon(Icons.movie_outlined, size: 36, color: cs.outline)),
                if (_isPreviewInitializing || _isLoadingPreview)
                  Container(color: Colors.black45, child: const Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))))
                else if (!_isPreviewUnavailable && !isPlaylistUrl(widget.url))
                  Container(
                    color: Colors.black26,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                        child: Icon(_isPreviewPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white, size: 28),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInlinePlayer(ColorScheme cs, TextTheme tt) {
    final c = _previewController;
    if (c == null || !c.value.isInitialized) return const SizedBox.shrink();
    final ar = c.value.aspectRatio;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        color: Colors.black,
        child: AspectRatio(
          aspectRatio: ar > 0 ? ar : 16 / 9,
          child: Stack(
            alignment: Alignment.center,
            children: [
              VideoPlayer(c),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _togglePreviewPlay,
                child: Center(
                  child: AnimatedOpacity(
                    opacity: _isPreviewPlaying ? 0.0 : 1.0,
                    duration: const Duration(milliseconds: 200),
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                      child: const Icon(Icons.play_arrow, color: Colors.white, size: 32),
                    ),
                  ),
                ),
              ),
              Positioned(top: 6, right: 6, child: IconButton(icon: const Icon(Icons.close, color: Colors.white70), onPressed: () {
                _previewController?.pause();
                _previewController?.dispose();
                _previewController = null;
                if (mounted) setState(() => _isPreviewPlaying = false);
              })),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final statusAsync = ref.watch(engineStatusProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isSettingUp = statusAsync.isLoading;
    final ready = statusAsync.maybeWhen(data: (s) => s.ready && s.error == null, orElse: () => false);
    final statusError = statusAsync.maybeWhen(data: (s) => s.error, orElse: () => null);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Shared link', style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold, color: colorScheme.primary)),
              const SizedBox(height: 8),
              Semantics(
                label: 'Shared URL: ${widget.url}',
                child: Text(widget.url, style: textTheme.mono.copyWith(color: colorScheme.onSurfaceVariant), maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(height: 12),
              _buildThumbnail(colorScheme),
              if (_previewController != null && _previewController!.value.isInitialized) ...[
                const SizedBox(height: 12),
                _buildInlinePlayer(colorScheme, textTheme),
              ] else if (_isPreviewUnavailable) ...[
                const SizedBox(height: 6),
                Text('Preview unavailable', style: textTheme.labelSmall?.copyWith(color: colorScheme.outline, fontStyle: FontStyle.italic)),
              ],
              const SizedBox(height: 12),
              if (isSettingUp)
                Row(children: [
                  const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 12),
                  Expanded(child: Text('Setting up the engine — quality choices unlock when ready.', style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant))),
                ])
              else if (!ready)
                Row(children: [
                  Icon(Icons.warning_amber_rounded, size: 20, color: colorScheme.error),
                  const SizedBox(width: 12),
                  Expanded(child: Text(statusError ?? 'Engine is not ready yet — try again shortly.', style: textTheme.bodySmall?.copyWith(color: colorScheme.error))),
                ]),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: ready && !_isDirectDownloading ? () => _directDownload() : null,
                  icon: _isDirectDownloading ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.download_rounded, size: 18),
                  label: const Text('Direct download'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colorScheme.primary,
                    foregroundColor: colorScheme.onPrimary,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: ready ? () => _continueToPicker(context) : null,
                  icon: const Icon(Icons.tune, size: 18),
                  label: const Text('Choose quality & download'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Center(child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Not now'))),
              Center(child: Text('Tip: enable auto-start in Settings to skip this sheet.', style: textTheme.labelSmall?.copyWith(color: colorScheme.outline), textAlign: TextAlign.center)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Presents the share-intent sheet. Returns the [showModalBottomSheet]
/// future so callers can chain on dismissal when needed.
Future<T?> showShareIntentSheet<T>(BuildContext context, String url) {
  final colorScheme = Theme.of(context).colorScheme;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: colorScheme.surfaceContainerLowest,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => ShareIntentSheet(url: url),
  );
}
