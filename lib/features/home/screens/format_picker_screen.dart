import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shimmer/shimmer.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';
import '../../../core/database/download_history_db.dart';
import '../../../core/engine/extraction_cache.dart';
import '../../../core/theme/text_styles.dart';
import '../../../core/engine/engine_provider.dart';
import '../../../core/utils/app_logger.dart';
import '../../../core/utils/command_template.dart';
import '../../../core/utils/download_config.dart';
import '../../../core/utils/format_selector.dart';
import '../../../core/utils/history_guard.dart';
import '../../../core/utils/schedule_guard.dart';
import '../../../core/utils/picker_session_state.dart';
import '../../../providers/download_provider.dart';
import '../../../providers/metered_guard.dart';
import '../../../providers/playlist_provider.dart';
import '../../../providers/preset_provider.dart';
import '../../../providers/settings_provider.dart';

const _uuid = Uuid();

class FormatPickerScreen extends ConsumerStatefulWidget {
  final String url;
  final String title;

  const FormatPickerScreen({super.key, required this.url, required this.title});

  static int? parseTimeToSeconds(String input) {
    final s = input.trim();
    if (s.isEmpty) return null;
    final parts = s.split(':');
    if (parts.length == 1) {
      final sec = int.tryParse(parts[0]);
      if (sec == null || sec < 0) return null;
      return sec;
    } else if (parts.length == 2) {
      final m = int.tryParse(parts[0]);
      final sec = int.tryParse(parts[1]);
      if (m == null || sec == null || sec < 0 || sec >= 60 || m < 0) {
        return null;
      }
      return m * 60 + sec;
    } else if (parts.length == 3) {
      final h = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      final sec = int.tryParse(parts[2]);
      if (h == null ||
          m == null ||
          sec == null ||
          sec < 0 ||
          sec >= 60 ||
          m < 0 ||
          m >= 60 ||
          h < 0) {
        return null;
      }
      return h * 3600 + m * 60 + sec;
    }
    return null;
  }

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
  bool _isAudioOnlyMode = false;
  String? _recommendedVideoFormatId;
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
  String? _selectedTemplate;
  Playlist? _selectedPlaylist;
  bool _isStarting = false; // guard against duplicate download taps

  // T03: Picker-integrated toggles with session persistence
  String _qualityCeiling = 'best';
  bool _embedSubtitles = false;
  bool _clipEnabled = false;
  late final TextEditingController _clipStartController;
  late final TextEditingController _clipEndController;
  String? _clipValidationError;

  // Description / thumbnail opts (visible in picker, session-persisted)
  bool _saveDescription = false;
  bool _saveThumbnails = true;
  String? _fileNameTemplate;
  late final TextEditingController _customFileNameController;
  String? _fileNameError;

  static const List<String> _predefinedFileNames = [
    '%(title)s.%(ext)s',
    '%(uploader)s - %(title)s.%(ext)s',
    '%(upload_date)s - %(title)s.%(ext)s',
    '%(playlist)s/%(title)s.%(ext)s',
    '%(extractor)s/%(title)s.%(ext)s',
  ];

  // T08: In-app progressive preview
  Map<String, dynamic>? _previewStream;
  VideoPlayerController? _previewController;
  bool _isPreviewInitializing = false;
  bool _isPreviewPlaying = false;
  bool _isPreviewUnavailable = false;

  static String normalizeCeiling(String? val) {
    if (val == null) return 'best';
    final v = val.toLowerCase().trim();
    if (v == '2160p') return '4k';
    if (v == '2k') return '1440p';
    const valid = {'best', '4k', '1440p', '1080p', '720p', '480p', '360p'};
    return valid.contains(v) ? v : 'best';
  }

  @override
  void initState() {
    super.initState();
    final session = PickerSessionState.instance;
    final settings = ref.read(settingsProvider);
    _qualityCeiling = normalizeCeiling(
      session.qualityCeiling ?? settings.qualityCeiling,
    );
    _embedSubtitles = session.embedSubtitles ?? settings.embedSubtitles;
    _clipEnabled = session.clipEnabled;
    _clipStartController = TextEditingController(text: session.clipStart);
    _clipEndController = TextEditingController(text: session.clipEnd);
    _validateClip();
    _saveDescription = session.saveDescription ?? settings.saveDescription;
    _saveThumbnails = session.saveThumbnails ?? settings.saveThumbnails;
    _fileNameTemplate = session.fileNameTemplate;
    _customFileNameController =
        TextEditingController(text: session.customFileName ?? '');
    _validateFileName();

    final cached = ExtractionCache.instance.get(widget.url);
    if (cached != null && cached['success'] == true) {
      _applyFormatsResult(cached);
      _isLoading = false;
    } else {
      _fetchFormats();
    }
  }

  @override
  void dispose() {
    _clipStartController.dispose();
    _clipEndController.dispose();
    _customFileNameController.dispose();
    _previewController?.dispose();
    _previewController = null;
    super.dispose();
  }

  void _validateClip() {
    if (!_clipEnabled) {
      _clipValidationError = null;
      return;
    }
    final startText = _clipStartController.text.trim();
    final endText = _clipEndController.text.trim();

    if (endText.isEmpty) {
      _clipValidationError = 'Enter clip end time (e.g. 01:30)';
      return;
    }

    final startSec = startText.isEmpty
        ? 0
        : FormatPickerScreen.parseTimeToSeconds(startText);
    if (startSec == null) {
      _clipValidationError = 'Invalid start time (use mm:ss or hh:mm:ss)';
      return;
    }

    final endSec = FormatPickerScreen.parseTimeToSeconds(endText);
    if (endSec == null) {
      _clipValidationError = 'Invalid end time (use mm:ss or hh:mm:ss)';
      return;
    }

    if (endSec <= startSec) {
      _clipValidationError = 'End time must be after start time';
      return;
    }

    if (_durationSeconds != null && endSec > _durationSeconds!) {
      _clipValidationError =
          'End time exceeds duration (${_formatDuration(_durationSeconds)})';
      return;
    }

    _clipValidationError = null;
  }

  String? get _clipRangeSpec {
    if (!_clipEnabled || _clipValidationError != null) return null;
    final startText = _clipStartController.text.trim();
    final endText = _clipEndController.text.trim();
    final startSec = startText.isEmpty
        ? 0
        : (FormatPickerScreen.parseTimeToSeconds(startText) ?? 0);
    final endSec = FormatPickerScreen.parseTimeToSeconds(endText);
    if (endSec == null || endSec <= startSec) return null;
    return '*$startSec-$endSec';
  }

  void _onQualityCeilingChanged(String newCeiling) {
    setState(() {
      _qualityCeiling = normalizeCeiling(newCeiling);
      PickerSessionState.instance.qualityCeiling = _qualityCeiling;
      if (!_isAudioOnlyMode) {
        final activePreset = ref.read(presetsProvider).activePreset;
        _selectedVideoFormat = selectBestVideoFormat(
          _videoFormats,
          targetHeight: targetHeightForCeiling(
            _qualityCeiling,
            activePreset.id,
          ),
          preferredCodec: activePreset.preferredCodec,
          fallbackRecommendedId: _recommendedVideoFormatId,
        );
      }
    });
  }

  void _onEmbedSubtitlesChanged(bool value) {
    setState(() {
      _embedSubtitles = value;
      PickerSessionState.instance.embedSubtitles = value;
    });
  }

  void _onClipChanged() {
    setState(() {
      _validateClip();
      final session = PickerSessionState.instance;
      session.clipEnabled = _clipEnabled;
      session.clipStart = _clipStartController.text;
      session.clipEnd = _clipEndController.text;
    });
  }

  bool _isSafeFileName(String tmpl) {
    if (tmpl.isEmpty) return true;
    if (tmpl.length > 256) return false;
    if (tmpl.contains('\x00')) return false;
    final text = tmpl.replaceAll('\\', '/');
    if (text.startsWith('/') || text.startsWith('~')) return false;
    if (text.length >= 2 && text[1] == ':') return false;
    if (text.startsWith('//')) return false;
    if (text.split('/').contains('..')) return false;
    return true;
  }

  void _validateFileName() {
    final v = _customFileNameController.text.trim();
    if (v.isEmpty) {
      _fileNameError = null;
      return;
    }
    if (!_isSafeFileName(v)) {
      _fileNameError =
          'Unsafe template: no absolute paths or .. segments (max 256 chars).';
      return;
    }
    _fileNameError = null;
  }

  void _onCustomFileNameChanged() {
    setState(() {
      _validateFileName();
      PickerSessionState.instance.customFileName =
          _customFileNameController.text;
    });
  }

  void _onFileNameTemplateChanged(String? value) {
    setState(() {
      _fileNameTemplate = value;
      PickerSessionState.instance.fileNameTemplate = value;
    });
  }

  void _onSaveDescriptionChanged(bool v) {
    setState(() {
      _saveDescription = v;
      PickerSessionState.instance.saveDescription = v;
    });
  }

  void _onSaveThumbnailsChanged(bool v) {
    setState(() {
      _saveThumbnails = v;
      PickerSessionState.instance.saveThumbnails = v;
    });
  }

  void _showVpnDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(ctx).colorScheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(
              Icons.vpn_lock,
              color: Theme.of(ctx).colorScheme.error,
              size: 24,
            ),
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

  void _applyFormatsResult(Map<String, dynamic> result) {
    if (result['success'] == true) {
      final formats = (result['formats'] as List).cast<Map<String, dynamic>>();
      _videoFormats = formats
          .where((f) => f['stream_type'] == 'video')
          .toList();
      _audioFormats = formats
          .where((f) => f['stream_type'] == 'audio')
          .toList();
      _muxedFormats = formats
          .where((f) => f['stream_type'] == 'muxed')
          .toList();
      _fetchedTitle = result['title'] as String? ?? widget.title;
      _thumbnailUrl = result['thumbnail_url'] as String? ?? '';
      _durationSeconds = (result['duration_seconds'] as num?)?.toInt();

      // T08: Preview stream from single extraction
      if (result['preview_stream'] != null && result['preview_stream'] is Map) {
        _previewStream = Map<String, dynamic>.from(
          result['preview_stream'] as Map,
        );
        _isPreviewUnavailable = false;
      } else {
        _previewStream = null;
        _isPreviewUnavailable = true;
      }

      final activePreset = ref.read(presetsProvider).activePreset;
      _recommendedVideoFormatId =
          result['recommended_video_format_id'] as String?;
      final isPureAudio = _videoFormats.isEmpty && _muxedFormats.isEmpty;
      final session = PickerSessionState.instance;
      _qualityCeiling = normalizeCeiling(
        session.qualityCeiling ?? ref.read(settingsProvider).qualityCeiling,
      );
      _embedSubtitles =
          session.embedSubtitles ?? ref.read(settingsProvider).embedSubtitles;
      _isAudioOnlyMode =
          session.audioOnly ?? (activePreset.audioOnly || isPureAudio);
      _selectedContainer = activePreset.preferredContainer;
      _validateClip();

      // P0: sort-then-first (never unsorted .first). Audio = max bitrate.
      _selectedAudioFormat = selectBestAudioFormat(_audioFormats);

      if (_isAudioOnlyMode) {
        _selectedVideoFormat = null;
        _selectedMuxedFormat = null;
        if (!['m4a', 'mp3', 'opus', 'flac'].contains(_selectedContainer)) {
          _selectedContainer = activePreset.audioOnly
              ? activePreset.preferredContainer
              : 'm4a';
        }
      } else {
        final targetHeight = targetHeightForCeiling(
          _qualityCeiling,
          activePreset.id,
        );

        _selectedVideoFormat = selectBestVideoFormat(
          _videoFormats,
          targetHeight: targetHeight,
          preferredCodec: activePreset.preferredCodec,
          fallbackRecommendedId: _recommendedVideoFormatId,
        );

        // For platforms with only muxed formats (Twitter, Instagram, etc.)
        if (_videoFormats.isEmpty && _muxedFormats.isNotEmpty) {
          _selectedMuxedFormat = _muxedFormats.first['format_id'] as String?;
          _selectedVideoFormat = null;
        }
        if (!['mkv', 'mp4', 'webm'].contains(_selectedContainer)) {
          _selectedContainer = 'mkv';
        }
      }
    } else {
      _error = result['error_message'] as String? ?? 'Failed to load formats';
      _suggestsVpn = _isVpnSuggested(_error!);
    }
  }

  Future<void> _fetchFormats() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _suggestsVpn = false;
    });

    try {
      final engine = ref.read(engineProvider);
      final result = await ExtractionCache.instance.getOrFetch(
        widget.url,
        () => AppLogger.trace<Map<String, dynamic>>(
          'Fetch format options for ${widget.url}',
          () => engine.getFormats(
            url: widget.url,
            config: {'cookies_path': null, 'proxy': null, 'verbose': false},
          ),
          tag: 'FormatPickerScreen',
        ),
      );
      if (!mounted) return;

      _applyFormatsResult(result);
    } catch (e) {
      _error = 'Error: $e';
      _suggestsVpn = _isVpnSuggested(_error!);
    }

    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _togglePreviewPlay() async {
    if (_previewStream == null ||
        _previewStream!['url'] == null ||
        (_previewStream!['url'] as String).isEmpty) {
      if (mounted) {
        setState(() => _isPreviewUnavailable = true);
      }
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
        for (final entry in headersRaw.entries) {
          if (entry.key != null && entry.value != null) {
            headers[entry.key.toString()] = entry.value.toString();
          }
        }
      }

      final controller = VideoPlayerController.networkUrl(
        Uri.parse(urlStr),
        httpHeaders: headers,
      );

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
        if (_isPreviewPlaying != isPlaying) {
          setState(() => _isPreviewPlaying = isPlaying);
        }
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
      // 403 / SABR / unsupported format: silent fallback, never blocks the picker
      if (mounted) {
        setState(() {
          _isPreviewInitializing = false;
          _isPreviewUnavailable = true;
        });
      }
    }
  }

  void _closePreview() {
    _previewController?.pause();
    _previewController?.dispose();
    _previewController = null;
    if (mounted) {
      setState(() {
        _isPreviewPlaying = false;
      });
    }
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

  /// Presentation-only ordering: selected first, then recommendation,
  /// then highest quality first (height desc, then bitrate). Never mutates
  /// state — purely display so the best stream is found in seconds.
  List<Map<String, dynamic>> _orderedForDisplay(
    Iterable<Map<String, dynamic>> formats, {
    required String? selectedId,
    String? recommendedId,
  }) {
    final list = formats.toList();
    int rank(Map<String, dynamic> fmt) {
      final id = fmt['format_id'] as String?;
      if (id != null && id == selectedId) return 0;
      if (recommendedId != null && id == recommendedId) return 1;
      return 2;
    }

    int qualityRank(Map<String, dynamic> fmt) {
      final h = fmt['height'];
      if (h is num) return -h.toInt();
      return 0;
    }

    num bitrate(Map<String, dynamic> fmt) {
      for (final k in ['tbr', 'abr', 'vbr']) {
        final v = fmt[k];
        if (v is num) return v;
      }
      return 0;
    }

    final indexed = list.asMap().entries.toList();
    indexed.sort((a, b) {
      final r = rank(a.value).compareTo(rank(b.value));
      if (r != 0) return r;
      final q = qualityRank(a.value).compareTo(qualityRank(b.value));
      if (q != 0) return q;
      final br = bitrate(b.value).compareTo(bitrate(a.value));
      if (br != 0) return br;
      return a.key.compareTo(b.key);
    });
    return indexed.map((e) => e.value).toList();
  }

  /// The single loud terracotta value for the header: current selection
  /// summarized in one line (quality + container). Null when nothing is
  /// selected yet — the header then stays quiet instead of guessing.
  String? _selectionValueLabel() {
    Map<String, dynamic>? byId(List<Map<String, dynamic>> list, String? id) {
      if (id == null) return null;
      for (final fmt in list) {
        if (fmt['format_id'] == id) return fmt;
      }
      return null;
    }

    final container = _selectedContainer.toUpperCase();
    final muxed = byId(_muxedFormats, _selectedMuxedFormat);
    if (muxed != null) {
      final height = muxed['height'];
      return height != null
          ? '$height\u2009p · $container'
          : 'Combined · $container';
    }
    final video = byId(_videoFormats, _selectedVideoFormat);
    if (video != null) {
      final height = video['height'];
      return height != null ? '$height\u2009p · $container' : 'Video · $container';
    }
    final audio = byId(_audioFormats, _selectedAudioFormat);
    if (audio != null) {
      final abr = audio['abr'];
      if (abr is num) return '${abr.toInt()}\u2009kbps audio · $container';
      return 'Audio · $container';
    }
    return null;
  }

  String _formatDuration(int? seconds) {
    if (seconds == null || seconds < 0) return '';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    if (m >= 60) return '${m ~/ 60}h ${m % 60}m';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _formatSize(int? bytes) {
    if (bytes == null) return 'Unknown size';
    final double mb = bytes / (1024 * 1024);
    if (mb > 1024) {
      return '${(mb / 1024).toStringAsFixed(1)} GB';
    }
    return '${mb.toStringAsFixed(0)} MB';
  }

  /// Confirm dialog when starting outside the scheduled window.
  Future<bool> _confirmOutsideSchedule(AppSettings settings) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Outside scheduled window'),
        content: Text(
          'Your download schedule is ${scheduleSummary(settings)}.\n\n'
          'Start this download now anyway?',
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

  /// Confirm dialog when the video is already in history. Returns true
  /// when the user explicitly chooses to download again.
  Future<bool> _confirmRedownload(DownloadRecord dup) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Already downloaded'),
        content: Text(
          '“${dup.title}” is already in your library'
          '${dup.format != null ? ' (${dup.format})' : ''}.\n\n'
          'Downloading again will replace the existing file.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Download again'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _startDownload() async {
    if (_selectedVideoFormat == null &&
        _selectedAudioFormat == null &&
        _selectedMuxedFormat == null) {
      return;
    }
    if (_isStarting) return; // prevent duplicate taps

    final notifier = ref.read(downloadProvider.notifier);
    if (notifier.isDownloading(widget.url)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Download already in progress for this link'),
        ),
      );
      return;
    }

    // Schedule gate: outside the window confirm instead of starting silently.
    final settings = ref.read(settingsProvider);
    if (!isWithinScheduleWindow(settings, DateTime.now()) && mounted) {
      final go = await _confirmOutsideSchedule(settings);
      if (!mounted || !go) return;
    }

    // Metered gate (Seal parity): explicit tap, but Wi-Fi Only is on —
    // confirm on metered links instead of silently spending data.
    if (mounted && !await ensureUnmeteredDownload(context: context, ref: ref)) {
      return;
    }

    // Already-downloaded / duplicate guard: warn instead of silently
    // replacing. Matches by exact URL or YouTube video id, so a video
    // previously saved as audio (or vice versa) still warns.
    try {
      final completed = await DownloadHistoryDb.instance.getCompleted().timeout(
        const Duration(milliseconds: 300),
        onTimeout: () => [],
      );
      final dup = findDuplicate(completed, widget.url);
      if (dup != null && mounted) {
        final again = await _confirmRedownload(dup);
        if (!mounted || !again) return;
      }
    } catch (_) {
      // History unavailable — proceed without the guard, never block.
    }

    AppLogger.info(
      'User initiated download for url: ${widget.url}',
      tag: 'FormatPickerScreen',
    );
    setState(() => _isStarting = true);

    final downloadId = _uuid.v4();
    final engine = ref.read(engineProvider);

    final isAudioOnly =
        _isAudioOnlyMode ||
        (_selectedVideoFormat == null &&
            _selectedMuxedFormat == null &&
            _selectedAudioFormat != null);

    final clipSpec = _clipRangeSpec;
    if (_clipEnabled && clipSpec == null) {
      if (!mounted) return;
      setState(() => _isStarting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_clipValidationError ?? 'Invalid clip range')),
      );
      return;
    }

    final customTmpl = _customFileNameController.text.trim();
    final effectiveTmpl = customTmpl.isNotEmpty
        ? customTmpl
        : (_fileNameTemplate ?? '');

    final config = <String, dynamic>{
      'container': _selectedContainer,
      // P1: forward user settings under exact engine contract keys
      // (config.py DEFAULT_CFG). Nulls dropped so defaults survive the
      // {**DEFAULT_CFG, **config} merge in build_ydl_opts().
      ...settingsDownloadConfig(settings),
      'quality_ceiling': _qualityCeiling,
      // Picker overrides for description/thumbnail per Phase 1.
      'write_description': _saveDescription,
      'embedthumbnail': _saveThumbnails,
      if (effectiveTmpl.isNotEmpty && _isSafeFileName(effectiveTmpl))
        'output_tmpl': effectiveTmpl,
      if (_embedSubtitles && !isAudioOnly) ...{
        'embed_subtitles': true,
        'download_subtitles': true,
      },
      if (_clipEnabled && clipSpec != null) ...{
        'download_sections': [clipSpec],
        'force_keyframes_at_cuts': true,
      },
      // Opt-in command template wins over settings (explicit format ids
      // below always win over everything — templates never touch them).
      if (_selectedTemplate != null && _selectedTemplate!.isNotEmpty)
        ...parseTemplateConfig(_selectedTemplate!).config,
      'explicit_format_id': _selectedMuxedFormat ?? _selectedVideoFormat,
      'explicit_audio_format_id': _selectedMuxedFormat != null
          ? null
          : _selectedAudioFormat,
      if (isAudioOnly) 'audio_only': true,
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
      final wasQueued = result['queued'] == true;
      notifier.addDownload(
        DownloadItem(
          id: downloadId,
          title: _fetchedTitle.isNotEmpty ? _fetchedTitle : widget.title,
          url: widget.url,
          status: wasQueued ? 'queued' : 'downloading',
          config: config,
          networkType: 'wifi',
          // Forward the formats.py thumbnail URL fetched for the preview
          // header — otherwise single-download Library rows can never show
          // a thumbnail (task 03: remote URL now, engine thumbnail_path
          // supersedes it locally on finish).
          thumbnailUrl: _thumbnailUrl.isNotEmpty ? _thumbnailUrl : null,
        ),
      );

      if (_selectedPlaylist != null) {
        ref
            .read(playlistProvider.notifier)
            .addDownloadToPlaylist(_selectedPlaylist!.id, downloadId);
      }

      if (mounted) {
        Navigator.pop(context);
        final wasQueued = result['queued'] == true;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              wasQueued
                  ? 'Queued — starts when a slot frees up'
                  : 'Download started',
            ),
          ),
        );
      }
    } else {
      if (mounted) {
        setState(() => _isStarting = false);
        final err = result['error_type']?.toString();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              err == 'ERROR_ALREADY_ACTIVE'
                  ? 'Download already in progress for this link'
                  : 'Could not start download',
            ),
          ),
        );
      }
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
        child: _error != null
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
                            color: colorScheme.errorContainer.withValues(
                              alpha: 0.3,
                            ),
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
            : _isLoading
            ? SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 16,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Opaque loading header: the shimmer skeleton below can
                    // read as pure black on dark (frozen mid-sweep), so this
                    // guarantees visible pixels + a way out (Cancel pops;
                    // _fetchFormats is mounted-guarded).
                    Semantics(
                      label: 'Fetching formats',
                      child: Center(
                        key: const Key('picker_loading'),
                        child: Column(
                          children: [
                            const SizedBox(height: 24),
                            const CircularProgressIndicator(),
                            const SizedBox(height: 16),
                            Text(
                              'Fetching formats…',
                              style: textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              widget.url,
                              style: textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 8),
                            TextButton(
                              onPressed: () =>
                                  Navigator.of(context).maybePop(),
                              child: const Text('Cancel'),
                            ),
                            const SizedBox(height: 8),
                          ],
                        ),
                      ),
                    ),
                    _buildPlaceholderView(colorScheme, textTheme),
                  ],
                ),
              )
            : SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 16,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeaderCard(colorScheme, textTheme),
                    if (_videoFormats.isNotEmpty ||
                        _muxedFormats.isNotEmpty) ...[
                      SizedBox(
                        width: double.infinity,
                        child: SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment<bool>(
                              value: false,
                              label: Text('Video + audio'),
                              icon: Icon(Icons.videocam_outlined),
                            ),
                            ButtonSegment<bool>(
                              value: true,
                              label: Text('Audio only'),
                              icon: Icon(Icons.audiotrack_outlined),
                            ),
                          ],
                          selected: {_isAudioOnlyMode},
                          onSelectionChanged: (v) =>
                              _setAudioOnly(v.first),
                          showSelectedIcon: false,
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    TextField(
                      decoration: InputDecoration(
                        hintText: 'Filter formats (e.g. 1080p, vp9 1080, 251)',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _filterQuery.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.clear),
                                onPressed: () =>
                                    setState(() => _filterQuery = ''),
                              ),
                        filled: true,
                        fillColor: colorScheme.surfaceContainerLowest,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(
                            color: colorScheme.outlineVariant.withValues(
                              alpha: 0.3,
                            ),
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(
                            color: colorScheme.outlineVariant.withValues(
                              alpha: 0.3,
                            ),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(
                            color: colorScheme.primary,
                            width: 1.5,
                          ),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                      ),
                      onChanged: (v) => setState(() => _filterQuery = v),
                    ),
                    const SizedBox(height: 12),
                    if (!_isAudioOnlyMode && _videoFormats.isNotEmpty)
                      _buildSectionTile(
                        title: 'Video streams',
                        count: _videoFormats.length,
                        selectedLabel: _selectedVideoFormat == null
                            ? null
                            : 'Selected: $_selectedVideoFormat',
                        initiallyExpanded: true,
                        colorScheme: colorScheme,
                        textTheme: textTheme,
                        children: [
                          for (final fmt in _orderedForDisplay(
                            _videoFormats.where(
                              (f) => _matchesFilter(f, true),
                            ),
                            selectedId: _selectedVideoFormat,
                            recommendedId: _recommendedVideoFormatId,
                          ))
                            _buildFormatRow(fmt, true, colorScheme, textTheme),
                        ],
                      ),
                    if (!_isAudioOnlyMode && _muxedFormats.isNotEmpty)
                      _buildSectionTile(
                        title: 'Combined streams',
                        count: _muxedFormats.length,
                        selectedLabel: _selectedMuxedFormat == null
                            ? null
                            : 'Selected: $_selectedMuxedFormat',
                        initiallyExpanded: false,
                        colorScheme: colorScheme,
                        textTheme: textTheme,
                        children: [
                          for (final fmt in _orderedForDisplay(
                            _muxedFormats.where(
                              (f) => _matchesFilter(f, false),
                            ),
                            selectedId: _selectedMuxedFormat,
                          ))
                            _buildMuxedFormatRow(fmt, colorScheme, textTheme),
                        ],
                      ),
                    if (_audioFormats.isNotEmpty)
                      _buildSectionTile(
                        title: 'Audio streams',
                        count: _audioFormats.length,
                        selectedLabel: _selectedAudioFormat == null
                            ? null
                            : 'Selected: $_selectedAudioFormat',
                        initiallyExpanded: _isAudioOnlyMode,
                        colorScheme: colorScheme,
                        textTheme: textTheme,
                        children: [
                          for (final fmt in _orderedForDisplay(
                            _audioFormats.where(
                              (f) => _matchesFilter(f, false),
                            ),
                            selectedId: _selectedAudioFormat,
                          ))
                            _buildFormatRow(fmt, false, colorScheme, textTheme),
                        ],
                      ),
                    const SizedBox(height: 12),
                    _buildOutputCard(colorScheme, textTheme),
                    const SizedBox(height: 12),
                    _buildMetadataCard(colorScheme, textTheme),
                    const SizedBox(height: 12),
                    _buildNamingCard(colorScheme, textTheme),
                    const SizedBox(height: 12),
                    _buildPlaylistAndTemplateCard(colorScheme, textTheme),
                    const SizedBox(height: 12),
                    _buildClipCard(colorScheme, textTheme),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed:
                            (!_isStarting &&
                                (_selectedVideoFormat != null ||
                                    _selectedAudioFormat != null ||
                                    _selectedMuxedFormat != null) &&
                                (!_clipEnabled ||
                                    _clipValidationError == null) &&
                                _fileNameError == null)
                            ? _startDownload
                            : null,
                        icon: const Icon(Icons.download_rounded, size: 20),
                        label: const Text(
                          'Download Now',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: colorScheme.primary,
                          foregroundColor: colorScheme.onPrimary,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          elevation: 0,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
      ),
    );
  }

  /// Mode switch backing the mockup `#fp-mode` seg. Moved verbatim from the
  /// old SegmentedButton handler: Audio-only clears video/muxed selection
  /// (hard rule — audio streams only) and picks audio-safe containers.
  void _setAudioOnly(bool audioOnly) {
    final activePreset = ref.read(presetsProvider).activePreset;
    setState(() {
      _isAudioOnlyMode = audioOnly;
      PickerSessionState.instance.audioOnly = _isAudioOnlyMode;
      if (_isAudioOnlyMode) {
        _selectedVideoFormat = null;
        _selectedMuxedFormat = null;
        _selectedAudioFormat ??= selectBestAudioFormat(_audioFormats);
        if (!['m4a', 'mp3', 'opus', 'flac'].contains(_selectedContainer)) {
          _selectedContainer = activePreset.audioOnly
              ? activePreset.preferredContainer
              : 'm4a';
        }
      } else {
        _selectedVideoFormat = selectBestVideoFormat(
          _videoFormats,
          targetHeight: targetHeightForCeiling(
            _qualityCeiling,
            activePreset.id,
          ),
          preferredCodec: activePreset.preferredCodec,
          fallbackRecommendedId: _recommendedVideoFormatId,
        );
        if (_videoFormats.isEmpty && _muxedFormats.isNotEmpty) {
          _selectedMuxedFormat =
              _muxedFormats.first['format_id'] as String?;
          _selectedVideoFormat = null;
        }
        _selectedAudioFormat ??= selectBestAudioFormat(_audioFormats);
        if (!['mkv', 'mp4', 'webm'].contains(_selectedContainer)) {
          _selectedContainer = 'mkv';
        }
      }
    });
  }

  Widget _buildHeaderCard(ColorScheme colorScheme, TextTheme textTheme) {
    final title = _fetchedTitle.isNotEmpty ? _fetchedTitle : widget.title;
    final dur = _formatDuration(_durationSeconds);
    final loudValue = _selectionValueLabel();

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.25),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            label: 'Video preview',
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  label: 'Video thumbnail',
                  child: _buildThumbnailWidget(colorScheme),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (loudValue != null) ...[
                        const SizedBox(height: 2),
                        Semantics(
                          label: 'Selected quality $loudValue',
                          child: Text(
                            loudValue,
                            style: textTheme.titleLarge?.copyWith(
                              color: colorScheme.primary,
                              fontWeight: FontWeight.w700,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            Icons.link,
                            size: 13,
                            color: colorScheme.outline,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              widget.url,
                              style: textTheme.mono.copyWith(
                                color: colorScheme.outline,
                                fontSize: 11,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          if (dur.isNotEmpty)
                            Semantics(
                              label: 'Duration $dur',
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: colorScheme.surfaceContainerHigh,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  'Duration $dur',
                                  style: textTheme.labelSmall?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: colorScheme.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '${_videoFormats.length} video · ${_audioFormats.length} audio'
                              '${_muxedFormats.isNotEmpty ? ' · ${_muxedFormats.length} combined' : ''} streams',
                              style: textTheme.labelSmall?.copyWith(
                                color: colorScheme.outline,
                                fontSize: 10,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (_isPreviewUnavailable) ...[
                        const SizedBox(height: 4),
                        Text(
                          'Preview unavailable',
                          style: textTheme.labelSmall?.copyWith(
                            color: colorScheme.outline,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (_previewController != null &&
              _previewController!.value.isInitialized &&
              !_isPreviewUnavailable) ...[
            const SizedBox(height: 12),
            _buildInlinePreviewPlayer(colorScheme, textTheme),
          ],
        ],
      ),
    );
  }

  Widget _buildOptionsCard(ColorScheme colorScheme, TextTheme textTheme) {
    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerLowest,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.25),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          Text(
            'Output options',
            style: textTheme.titleSmall?.copyWith(
              color: colorScheme.onSurface,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Format:',
                style: textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
              Semantics(
                label:
                    'Format, currently $_selectedContainer',
                child: DropdownButton<String>(
                  value: _selectedContainer,
                  dropdownColor: colorScheme.surfaceContainerHigh,
                  underline: const SizedBox.shrink(),
                  items: _isAudioOnlyMode
                      ? const [
                          DropdownMenuItem(
                            value: 'm4a',
                            child: Text('M4A (Recommended)'),
                          ),
                          DropdownMenuItem(
                            value: 'mp3',
                            child: Text('MP3'),
                          ),
                          DropdownMenuItem(
                            value: 'opus',
                            child: Text('Opus'),
                          ),
                          DropdownMenuItem(
                            value: 'flac',
                            child: Text('FLAC (Lossless)'),
                          ),
                        ]
                      : const [
                          DropdownMenuItem(
                            value: 'mkv',
                            child: Text('MKV (Recommended)'),
                          ),
                          DropdownMenuItem(
                            value: 'mp4',
                            child: Text('MP4'),
                          ),
                          DropdownMenuItem(
                            value: 'webm',
                            child: Text('WebM'),
                          ),
                        ],
                  onChanged: (val) {
                    if (val != null) {
                      setState(() => _selectedContainer = val);
                    }
                  },
                ),
              ),
            ],
          ),
          if (!_isAudioOnlyMode) ...[
            const Divider(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Quality:',
                  style: textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Semantics(
                  label:
                      'Quality, currently $_qualityCeiling',
                  child: DropdownButton<String>(
                    value: _qualityCeiling,
                    dropdownColor: colorScheme.surfaceContainerHigh,
                    underline: const SizedBox.shrink(),
                    items: const [
                      DropdownMenuItem(
                        value: 'best',
                        child: Text('Best Available'),
                      ),
                      DropdownMenuItem(
                        value: '4k',
                        child: Text('4K (2160p)'),
                      ),
                      DropdownMenuItem(
                        value: '1440p',
                        child: Text('1440p (2K)'),
                      ),
                      DropdownMenuItem(
                        value: '1080p',
                        child: Text('1080p (FHD)'),
                      ),
                      DropdownMenuItem(
                        value: '720p',
                        child: Text('720p (HD)'),
                      ),
                      DropdownMenuItem(
                        value: '480p',
                        child: Text('480p (SD)'),
                      ),
                      DropdownMenuItem(
                        value: '360p',
                        child: Text('360p'),
                      ),
                    ],
                    onChanged: (val) {
                      if (val != null) _onQualityCeilingChanged(val);
                    },
                  ),
                ),
              ],
            ),
          ],
          const Divider(height: 16),
          SwitchListTile(
            key: const Key('embed_subtitles_toggle'),
            title: const Text('Embed Subtitles'),
            subtitle: Text(
              _isAudioOnlyMode
                  ? 'Requires video stream'
                  : 'Embed subtitles directly into media file',
              style: textTheme.bodySmall?.copyWith(
                color: _isAudioOnlyMode ? colorScheme.outline : null,
              ),
            ),
            value: _isAudioOnlyMode ? false : _embedSubtitles,
            onChanged: _isAudioOnlyMode ? null : _onEmbedSubtitlesChanged,
            contentPadding: EdgeInsets.zero,
            secondary: Icon(
              Icons.subtitles_outlined,
              color: _isAudioOnlyMode
                  ? colorScheme.outline
                  : colorScheme.primary,
            ),
          ),
          const Divider(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Add to Playlist:', style: textTheme.bodyMedium),
              Semantics(
                label:
                    'Add to Playlist, ${_selectedPlaylist != null ? _selectedPlaylist!.name : "none"} selected',
                child: DropdownButton<Playlist?>(
                  value: _selectedPlaylist,
                  dropdownColor: colorScheme.surfaceContainerHigh,
                  underline: const SizedBox.shrink(),
                  hint: const Text('None'),
                  items: [
                    const DropdownMenuItem<Playlist?>(
                      value: null,
                      child: Text('None'),
                    ),
                    ...ref
                        .watch(playlistProvider)
                        .map(
                          (p) => DropdownMenuItem<Playlist?>(
                            value: p,
                            child: Text(p.name),
                          ),
                        ),
                  ],
                  onChanged: (val) {
                    setState(() => _selectedPlaylist = val);
                  },
                ),
              ),
            ],
          ),
          const Divider(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Command Template:', style: textTheme.bodyMedium),
              Semantics(
                label:
                    'Command Template, ${_selectedTemplate ?? "none"} selected',
                child: DropdownButton<String?>(
                  value: _selectedTemplate,
                  dropdownColor: colorScheme.surfaceContainerHigh,
                  underline: const SizedBox.shrink(),
                  hint: const Text('None'),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('None'),
                    ),
                    ...ref
                        .watch(settingsProvider)
                        .customTemplates
                        .map(
                          (t) => DropdownMenuItem<String?>(
                            value: t,
                            child: Text(
                              t.length > 24
                                  ? '${t.substring(0, 24)}…'
                                  : t,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                  ],
                  onChanged: (val) {
                    setState(() => _selectedTemplate = val);
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

  Widget _buildOutputCard(ColorScheme colorScheme, TextTheme textTheme) {
    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.25),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.video_settings_outlined,
                    size: 20, color: colorScheme.primary),
                const SizedBox(width: 8),
                Text('Output',
                    style: textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600, color: colorScheme.onSurface)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Format:', style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
                Semantics(
                  label: 'Format, currently $_selectedContainer',
                  child: DropdownButton<String>(
                    value: _selectedContainer,
                    dropdownColor: colorScheme.surfaceContainerHigh,
                    underline: const SizedBox.shrink(),
                    items: _isAudioOnlyMode
                        ? const [
                            DropdownMenuItem(value: 'm4a', child: Text('M4A (Recommended)')),
                            DropdownMenuItem(value: 'mp3', child: Text('MP3')),
                            DropdownMenuItem(value: 'opus', child: Text('Opus')),
                            DropdownMenuItem(value: 'flac', child: Text('FLAC (Lossless)')),
                          ]
                        : const [
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
            if (!_isAudioOnlyMode) ...[
              const Divider(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Quality:', style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
                  Semantics(
                    label: 'Quality, currently $_qualityCeiling',
                    child: DropdownButton<String>(
                      value: _qualityCeiling,
                      dropdownColor: colorScheme.surfaceContainerHigh,
                      underline: const SizedBox.shrink(),
                      items: const [
                        DropdownMenuItem(value: 'best', child: Text('Best Available')),
                        DropdownMenuItem(value: '4k', child: Text('4K (2160p)')),
                        DropdownMenuItem(value: '1440p', child: Text('1440p (2K)')),
                        DropdownMenuItem(value: '1080p', child: Text('1080p (FHD)')),
                        DropdownMenuItem(value: '720p', child: Text('720p (HD)')),
                        DropdownMenuItem(value: '480p', child: Text('480p (SD)')),
                        DropdownMenuItem(value: '360p', child: Text('360p')),
                      ],
                      onChanged: (val) {
                        if (val != null) _onQualityCeilingChanged(val);
                      },
                    ),
                  ),
                ],
              ),
            ],
            const Divider(height: 16),
            SwitchListTile(
              key: const Key('embed_subtitles_toggle'),
              title: const Text('Embed Subtitles'),
              subtitle: Text(
                _isAudioOnlyMode ? 'Requires video stream' : 'Embed subtitles directly into media file',
                style: textTheme.bodySmall?.copyWith(color: _isAudioOnlyMode ? colorScheme.outline : null),
              ),
              value: _isAudioOnlyMode ? false : _embedSubtitles,
              onChanged: _isAudioOnlyMode ? null : _onEmbedSubtitlesChanged,
              contentPadding: EdgeInsets.zero,
              secondary: Icon(Icons.subtitles_outlined,
                  color: _isAudioOnlyMode ? colorScheme.outline : colorScheme.primary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetadataCard(ColorScheme colorScheme, TextTheme textTheme) {
    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.25)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.perm_media_outlined, size: 20, color: colorScheme.primary),
                const SizedBox(width: 8),
                Text('Metadata',
                    style:
                        textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600, color: colorScheme.onSurface)),
              ],
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              key: const Key('save_description_toggle'),
              title: const Text('Save Description'),
              subtitle: Text('Save video description as .txt',
                  style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant)),
              value: _saveDescription,
              onChanged: _onSaveDescriptionChanged,
              contentPadding: EdgeInsets.zero,
              secondary:
                  Icon(Icons.description_outlined, color: colorScheme.primary, size: 20),
            ),
            const Divider(height: 8),
            SwitchListTile(
              key: const Key('save_thumbnail_toggle'),
              title: const Text('Save Thumbnail'),
              subtitle: Text('Embed or keep thumbnail next to file',
                  style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant)),
              value: _saveThumbnails,
              onChanged: _onSaveThumbnailsChanged,
              contentPadding: EdgeInsets.zero,
              secondary: Icon(Icons.image_outlined, color: colorScheme.primary, size: 20),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNamingCard(ColorScheme colorScheme, TextTheme textTheme) {
    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.25)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.drive_file_rename_outline, size: 20, color: colorScheme.primary),
                const SizedBox(width: 8),
                Text('File name',
                    style:
                        textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600, color: colorScheme.onSurface)),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              key: const Key('filename_template_dropdown'),
              initialValue: _fileNameTemplate,
              dropdownColor: colorScheme.surfaceContainerHigh,
              decoration: InputDecoration(
                labelText: 'Template',
                isDense: true,
                filled: true,
                fillColor: colorScheme.surfaceContainerHigh.withValues(alpha: 0.3),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
              hint: const Text('Default'),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('Default — %(uploader)s - %(title)s')),
                ..._predefinedFileNames.map((t) => DropdownMenuItem<String?>(
                      value: t,
                      child: Text(t, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                    )),
              ],
              onChanged: _onFileNameTemplateChanged,
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('custom_filename_field'),
              controller: _customFileNameController,
              decoration: InputDecoration(
                labelText: 'Custom file name',
                hintText: 'e.g. %(title)s.%(ext)s',
                isDense: true,
                filled: true,
                fillColor: colorScheme.surfaceContainerHigh.withValues(alpha: 0.3),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                prefixIcon: const Icon(Icons.edit_outlined, size: 18),
                errorText: _fileNameError,
              ),
              style: textTheme.bodyMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
              onChanged: (_) => _onCustomFileNameChanged(),
            ),
            const SizedBox(height: 6),
            Text(
              'Use yt-dlp placeholders like %(title)s, %(uploader)s, %(ext)s. Leave empty to use the template above.',
              style: textTheme.labelSmall?.copyWith(color: colorScheme.outline),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaylistAndTemplateCard(
      ColorScheme colorScheme, TextTheme textTheme) {
    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.25)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.playlist_add_outlined, size: 20, color: colorScheme.primary),
                const SizedBox(width: 8),
                Text('Playlist & Advanced',
                    style:
                        textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600, color: colorScheme.onSurface)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Add to Playlist:', style: textTheme.bodyMedium),
                Semantics(
                  label: 'Add to Playlist, ${_selectedPlaylist != null ? _selectedPlaylist!.name : "none"} selected',
                  child: DropdownButton<Playlist?>(
                    value: _selectedPlaylist,
                    dropdownColor: colorScheme.surfaceContainerHigh,
                    underline: const SizedBox.shrink(),
                    hint: const Text('None'),
                    items: [
                      const DropdownMenuItem<Playlist?>(value: null, child: Text('None')),
                      ...ref.watch(playlistProvider).map((p) => DropdownMenuItem<Playlist?>(
                            value: p,
                            child: Text(p.name),
                          )),
                    ],
                    onChanged: (val) => setState(() => _selectedPlaylist = val),
                  ),
                ),
              ],
            ),
            const Divider(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Command Template:', style: textTheme.bodyMedium),
                Semantics(
                  label: 'Command Template, ${_selectedTemplate ?? "none"} selected',
                  child: DropdownButton<String?>(
                    value: _selectedTemplate,
                    dropdownColor: colorScheme.surfaceContainerHigh,
                    underline: const SizedBox.shrink(),
                    hint: const Text('None'),
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('None')),
                      ...ref.watch(settingsProvider).customTemplates.map((t) => DropdownMenuItem<String?>(
                            value: t,
                            child: Text(t.length > 24 ? '${t.substring(0, 24)}…' : t, overflow: TextOverflow.ellipsis),
                          )),
                    ],
                    onChanged: (val) => setState(() => _selectedTemplate = val),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildClipCard(ColorScheme colorScheme, TextTheme textTheme) {
    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerLowest,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: _clipValidationError != null
              ? colorScheme.error
              : colorScheme.outlineVariant.withValues(alpha: 0.25),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.content_cut,
                    size: 20,
                    color: _clipEnabled
                        ? colorScheme.primary
                        : colorScheme.outline,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Clip / Trim Range',
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              Switch(
                key: const Key('clip_range_switch'),
                value: _clipEnabled,
                onChanged: (val) {
                  setState(() {
                    _clipEnabled = val;
                    _onClipChanged();
                  });
                },
              ),
            ],
          ),
          if (_clipEnabled) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('clip_start_field'),
                    controller: _clipStartController,
                    style: textTheme.bodyMedium?.copyWith(
                      fontFeatures: const [
                        FontFeature.tabularFigures(),
                      ],
                    ),
                    decoration: InputDecoration(
                      labelText: 'Start Time',
                      hintText: '00:00',
                      isDense: true,
                      filled: true,
                      fillColor: colorScheme.surfaceContainerHigh.withValues(
                        alpha: 0.3,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      prefixIcon: const Icon(
                        Icons.timer_outlined,
                        size: 18,
                      ),
                    ),
                    keyboardType: TextInputType.text,
                    onChanged: (_) => _onClipChanged(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    key: const Key('clip_end_field'),
                    controller: _clipEndController,
                    style: textTheme.bodyMedium?.copyWith(
                      fontFeatures: const [
                        FontFeature.tabularFigures(),
                      ],
                    ),
                    decoration: InputDecoration(
                      labelText: 'End Time',
                      hintText: '01:30',
                      isDense: true,
                      filled: true,
                      fillColor: colorScheme.surfaceContainerHigh.withValues(
                        alpha: 0.3,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      prefixIcon: const Icon(
                        Icons.timer_off_outlined,
                        size: 18,
                      ),
                    ),
                    keyboardType: TextInputType.text,
                    onChanged: (_) => _onClipChanged(),
                  ),
                ),
              ],
            ),
            if (_durationSeconds != null) ...[
              const SizedBox(height: 6),
              Text(
                'Total duration: ${_formatDuration(_durationSeconds)}',
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.outline,
                  fontFeatures: const [
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ],
            if (_clipValidationError != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 16,
                    color: colorScheme.error,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _clipValidationError!,
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.error,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ],
      ),
    ),
  );
}

  Widget _thumbFallback(ColorScheme colorScheme) {
    return Container(
      width: 112,
      height: 64,
      color: colorScheme.surfaceContainerHigh,
      child: Icon(
        Icons.movie_outlined,
        size: 28,
        color: colorScheme.outline.withValues(alpha: 0.5),
      ),
    );
  }

  Widget _buildThumbnailWidget(ColorScheme colorScheme) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _isPreviewUnavailable ? null : _togglePreviewPlay,
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            width: 112,
            height: 64,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _thumbnailUrl.isNotEmpty
                    ? Image.network(
                        _thumbnailUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => _thumbFallback(colorScheme),
                      )
                    : _thumbFallback(colorScheme),
                if (_isPreviewInitializing)
                  Container(
                    color: Colors.black45,
                    child: const Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  )
                else if (!_isPreviewUnavailable && _previewStream != null)
                  Container(
                    color: Colors.black26,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(
                          color: Colors.black54,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          _isPreviewPlaying ? Icons.pause : Icons.play_arrow,
                          color: Colors.white,
                          size: 20,
                        ),
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

  Widget _buildInlinePreviewPlayer(
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    final controller = _previewController;
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }
    final ar = controller.value.aspectRatio;
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Container(
        color: Colors.black,
        child: AspectRatio(
          aspectRatio: (ar > 0) ? ar : (16 / 9),
          child: Stack(
            alignment: Alignment.center,
            children: [
              VideoPlayer(controller),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _togglePreviewPlay,
                child: Center(
                  child: AnimatedOpacity(
                    opacity: _isPreviewPlaying ? 0.0 : 1.0,
                    duration: const Duration(milliseconds: 200),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: const BoxDecoration(
                        color: Colors.black54,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.play_arrow,
                        color: Colors.white,
                        size: 36,
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white70),
                  tooltip: 'Close preview',
                  onPressed: _closePreview,
                ),
              ),
              Positioned(
                bottom: 8,
                left: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'Preview · ${_previewStream?['height'] != null ? '${_previewStream!['height']}p' : '≤480p'}',
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Preview dialog: thumbnail + title + current selection summary with
  /// a Download CTA. Tap Preview Stream to toggle in-app preview.
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
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
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
                style: textTheme.mono,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          if (!_isPreviewUnavailable && _previewStream != null)
            TextButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                _togglePreviewPlay();
              },
              icon: Icon(_isPreviewPlaying ? Icons.pause : Icons.play_arrow),
              label: Text(
                _isPreviewPlaying ? 'Pause Stream' : 'Preview Stream',
              ),
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
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.25),
          ),
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.25),
          ),
        ),
        title: Text(
          '$title ($count)',
          style: textTheme.titleSmall?.copyWith(
            color: colorScheme.onSurface,
            fontWeight: FontWeight.w600,
            letterSpacing: 0,
          ),
        ),
        subtitle: selectedLabel == null
            ? null
            : Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  selectedLabel,
                  style: textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
        childrenPadding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        children: children.isEmpty
            ? [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'No formats match the filter.',
                    style: textTheme.labelSmall?.copyWith(
                      color: colorScheme.outline,
                    ),
                  ),
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
    final isHdr =
        isVideo &&
        fmt['dynamic_range'] != null &&
        fmt['dynamic_range'] != 'SDR' &&
        fmt['dynamic_range'].toString().isNotEmpty;
    final isRecommended =
        isVideo && _recommendedVideoFormatId == formatId && !isSelected;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isSelected
            ? colorScheme.primaryContainer.withValues(alpha: 0.12)
            : colorScheme.surfaceContainerHigh.withValues(alpha: 0.35),
        border: Border.all(
          color: isSelected
              ? colorScheme.primary
              : colorScheme.outlineVariant.withValues(alpha: 0.25),
          width: isSelected ? 1.5 : 1.0,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Semantics(
        button: true,
        label:
            '${isVideo ? "Video" : "Audio"} format $formatId${isSelected ? ", selected" : ""}',
        child: InkWell(
          onTap: () => setState(() {
            if (isVideo) {
              if (_selectedVideoFormat == formatId) {
                _selectedVideoFormat = null;
              } else {
                _selectedVideoFormat = formatId;
              }
            } else {
              if (_selectedAudioFormat == formatId &&
                  _selectedVideoFormat != null) {
                _selectedAudioFormat = null;
              } else {
                _selectedAudioFormat = formatId;
              }
            }
          }),
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
                          Flexible(
                            child: Text(
                              isVideo
                                  ? '$formatId · ${fmt['height'] != null ? '${fmt['height']}p' : ''}${fmt['fps'] != null ? '${fmt['fps']}' : ''}'
                                  : '$formatId · ${fmt['acodec'] ?? 'Audio'} · ${fmt['abr'] != null ? '${(fmt['abr'] as num).toInt()} kbps' : (fmt['tbr'] != null ? '${(fmt['tbr'] as num).toInt()} kbps' : 'unknown')}',
                              style: textTheme.mono.copyWith(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (isRecommended) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: colorScheme.surfaceContainerHigh,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                'Recommended',
                                style: textTheme.mono.copyWith(
                                  color: colorScheme.primary,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                          if (isHdr) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: colorScheme.tertiaryContainer,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                fmt['dynamic_range']?.toString() ?? '',
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
                      const SizedBox(height: 2),
                      Text(
                        isVideo
                            ? '${fmt['vcodec']} · ${fmt['ext']} · ${_formatSize(fmt['filesize'])}'
                            : '${fmt['ext']} · ${_formatSize(fmt['filesize'])}',
                        style: textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 12,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
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
            ? colorScheme.primaryContainer.withValues(alpha: 0.12)
            : colorScheme.surfaceContainerHigh.withValues(alpha: 0.35),
        border: Border.all(
          color: isSelected
              ? colorScheme.primary
              : colorScheme.outlineVariant.withValues(alpha: 0.25),
          width: isSelected ? 1.5 : 1.0,
        ),
        borderRadius: BorderRadius.circular(14),
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
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
                        style: textTheme.mono.copyWith(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${fmt['vcodec']} + ${fmt['acodec']} · ${fmt['ext']} · ${_formatSize(fmt['filesize'] as int?)}',
                        style: textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 12,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
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

  Widget _buildRadio(
    bool isSelected,
    String formatId,
    ColorScheme colorScheme,
  ) {
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
            color: isSelected
                ? colorScheme.primary
                : colorScheme.outline.withValues(alpha: 0.5),
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

  Widget _buildPlaceholderView(ColorScheme colorScheme, TextTheme textTheme) {
    final shimmerBase = colorScheme.surfaceContainerHigh;
    final shimmerHighlight = colorScheme.surfaceContainerHighest;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Shimmer.fromColors(
        baseColor: shimmerBase,
        highlightColor: shimmerHighlight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Hero header card placeholder
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: shimmerBase.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 112,
                    height: 64,
                    decoration: BoxDecoration(
                      color: shimmerBase,
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          height: 18,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: shimmerBase,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Container(
                          height: 12,
                          width: 180,
                          decoration: BoxDecoration(
                            color: shimmerBase,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          height: 14,
                          width: 140,
                          decoration: BoxDecoration(
                            color: shimmerBase,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // Mode toggle placeholder
            Container(
              height: 40,
              width: double.infinity,
              decoration: BoxDecoration(
                color: shimmerBase,
                borderRadius: BorderRadius.circular(20),
              ),
            ),
            const SizedBox(height: 16),
            // Filter search box placeholder
            Container(
              height: 44,
              width: double.infinity,
              decoration: BoxDecoration(
                color: shimmerBase,
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            const SizedBox(height: 24),
            // Section 1 header placeholder
            Container(
              height: 16,
              width: 140,
              decoration: BoxDecoration(
                color: shimmerBase,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(height: 12),
            // 3 format cards placeholders (non-interactive)
            for (int i = 0; i < 3; i++) ...[
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: shimmerBase,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: shimmerHighlight,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            height: 14,
                            width: 120,
                            decoration: BoxDecoration(
                              color: shimmerHighlight,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Container(
                            height: 11,
                            width: 180,
                            decoration: BoxDecoration(
                              color: shimmerHighlight,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 24),
            // Disabled Download Now button placeholder
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: null,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: const Text('Download Now'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
