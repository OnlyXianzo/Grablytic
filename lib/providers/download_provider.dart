import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/database/download_history_db.dart';
import '../core/engine/engine_provider.dart';
import '../core/engine/engine_service.dart';
import '../core/utils/app_logger.dart';

class DownloadItem {
  final String id;
  final String title;
  final String url;
  final String status;
  final double progress;
  final int downloadedBytes;
  final int totalBytes;
  /// Current transfer speed in bytes/second (0 when unknown/stalled).
  final double speed;
  /// Estimated seconds remaining (-1 when unknown).
  final int eta;
  /// Post-processing stage key (merging, embedding_thumbnail, …) or null
  /// while plain downloading.
  final String? stage;
  final String? stageLabel;
  final String? thumbnailUrl;
  final String? filePath;
  final DateTime addedAt;
  final String? fileSize;
  final String? completedDate;
  final String? errorType;
  final String? errorMessage;
  final String? recoveryAction;
  final bool suggestsVpn;
  final Map<String, dynamic>? config;
  final String? networkType;

  DownloadItem({
    required this.id,
    required this.title,
    required this.url,
    this.status = 'pending',
    this.progress = 0,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.speed = 0,
    this.eta = -1,
    this.stage,
    this.stageLabel,
    this.thumbnailUrl,
    this.filePath,
    DateTime? addedAt,
    this.fileSize,
    this.completedDate,
    this.errorType,
    this.errorMessage,
    this.recoveryAction,
    this.suggestsVpn = false,
    this.config,
    this.networkType,
  }) : addedAt = addedAt ?? DateTime.now();

  DownloadItem copyWith({
    String? status,
    double? progress,
    int? downloadedBytes,
    int? totalBytes,
    double? speed,
    int? eta,
    String? stage,
    bool clearStage = false,
    String? stageLabel,
    bool clearStageLabel = false,
    String? thumbnailUrl,
    String? filePath,
    String? fileSize,
    String? completedDate,
    String? errorType,
    String? errorMessage,
    String? recoveryAction,
    bool? suggestsVpn,
    Map<String, dynamic>? config,
    String? networkType,
  }) {
    return DownloadItem(
      id: id,
      title: title,
      url: url,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      speed: speed ?? this.speed,
      eta: eta ?? this.eta,
      stage: clearStage ? null : (stage ?? this.stage),
      stageLabel: clearStageLabel ? null : (stageLabel ?? this.stageLabel),
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      filePath: filePath ?? this.filePath,
      addedAt: addedAt,
      fileSize: fileSize ?? this.fileSize,
      completedDate: completedDate ?? this.completedDate,
      errorType: errorType ?? this.errorType,
      errorMessage: errorMessage ?? this.errorMessage,
      recoveryAction: recoveryAction ?? this.recoveryAction,
      suggestsVpn: suggestsVpn ?? this.suggestsVpn,
      config: config ?? this.config,
      networkType: networkType ?? this.networkType,
    );
  }
}

class DownloadNotifier extends StateNotifier<List<DownloadItem>> {
  final EngineService _engine;

  DownloadNotifier(this._engine) : super([]);

  List<DownloadItem> get completed =>
      state.where((d) => d.status == 'completed').toList();
  List<DownloadItem> get inProgress =>
      state.where((d) => d.status == 'downloading').toList();

  bool isDownloading(String url) {
    return state.any((d) => d.url == url && d.status == 'downloading');
  }

  void addDownload(DownloadItem item) {
    state = [...state, item];
    _persistRecord(item);
  }

  void updateProgress(String id, double progress, int downloadedBytes) {
    state = [
      for (final d in state)
        if (d.id != id)
          d
        else
          // Progress events (including per-stream completions) must never
          // flip status to 'completed' — only the terminal 'finished' event
          // does that (after FFmpeg merge + post-processing). Hold at 99%.
          d.copyWith(
            status: (d.status == 'downloading' || d.status == 'pending')
                ? 'downloading'
                : d.status,
            progress: progress.clamp(0.0, 0.99),
            downloadedBytes: downloadedBytes,
          ),
    ];
  }

  void handleProgressEvent(Map<String, dynamic> event) {
    // NOTE: `type:log` engine maps are intentionally NOT handled here.
    // LogIngester (subscribed to engine.logStream) is the single ingestion
    // point — handling them here too double-logged every engine line on
    // desktop. Log maps carry no top-level download_id, so they fall
    // through to the guard below and are ignored here.
    final type = event['type'] as String?;
    if (type == 'log') return;

    final downloadId = event['download_id'] as String?;
    if (downloadId == null) return;

    final eventType = event['event'] as String?;

    if (eventType == 'downloading') {
      final downloaded = event['downloaded_bytes'] as int? ?? 0;
      final total = event['total_bytes'] as int? ?? 0;
      final progress = total > 0 ? downloaded / total : 0.0;
      final speed = (event['speed'] as num?)?.toDouble() ?? 0;
      final eta = event['eta'] as int? ?? -1;
      state = [
        for (final d in state)
          if (d.id != downloadId)
            d
          else
            d.copyWith(
              status: 'downloading',
              progress: progress.clamp(0.0, 0.99),
              downloadedBytes: downloaded,
              totalBytes: total,
              speed: speed,
              eta: eta,
              clearStage: true,
              clearStageLabel: true,
            ),
      ];
    } else if (eventType == 'postprocessing') {
      // yt-dlp entered a post-processing stage (merging, embedding, …).
      // Surfaced on the card so a 99% item visibly keeps working.
      final stage = event['stage'] as String?;
      final stageLabel = event['stage_label'] as String?;
      state = [
        for (final d in state)
          if (d.id != downloadId)
            d
          else
            d.copyWith(stage: stage, stageLabel: stageLabel),
      ];
    } else if (eventType == 'stream_finished') {
      // One stream (e.g. DASH video) landed; more may follow, then FFmpeg
      // merge + post-processing. Record bytes, hold below 100%, stay
      // 'downloading' — only terminal 'finished' completes the item.
      final filesize = event['filesize_bytes'] as int? ?? 0;
      state = [
        for (final d in state)
          if (d.id != downloadId)
            d
          else
            d.copyWith(
              status: 'downloading',
              progress: d.progress.clamp(0.0, 0.99),
              downloadedBytes: filesize > 0 ? filesize : d.downloadedBytes,
              totalBytes: filesize > d.totalBytes ? filesize : d.totalBytes,
            ),
      ];
    } else if (eventType == 'finished') {
      final filesize = event['filesize_bytes'] as int? ?? 0;
      final filePath = event['file_path'] as String?;
      final sizeStr = _formatFilesize(filesize);
      // Terminal outcome — one line per download (never per-progress) so
      // diagnostics reports always show what happened. ID + outcome only,
      // never the URL (may carry auth query params).
      AppLogger.info('Download finished: $downloadId ($sizeStr)',
          tag: 'download');

      state = [
        for (final d in state)
          if (d.id != downloadId)
            d
          else
            d.copyWith(
              status: 'completed',
              progress: 1.0,
              downloadedBytes: filesize,
              totalBytes: filesize,
              filePath: filePath ?? d.filePath,
              speed: 0,
              eta: -1,
              clearStage: true,
              clearStageLabel: true,
              fileSize: sizeStr,
              completedDate: 'Today',
            ),
      ];
      final item = state.firstWhere((d) => d.id == downloadId, orElse: () => state.last);
      _persistRecord(item);
    } else if (eventType == 'error') {
      final errorType = event['error_type'] as String?;
      final errorMessage = event['error_message'] as String?;
      final suggestsVpn = event['suggests_vpn'] as bool? ?? false;
      AppLogger.warn(
          'Download failed: $downloadId [$errorType]${suggestsVpn ? ' (VPN may help)' : ''}',
          tag: 'download');

      state = [
        for (final d in state)
          if (d.id != downloadId)
            d
          else
            d.copyWith(
              status: 'error',
              speed: 0,
              eta: -1,
              clearStage: true,
              clearStageLabel: true,
              errorType: errorType,
              errorMessage: errorMessage,
              suggestsVpn: suggestsVpn,
            ),
      ];
      final item = state.firstWhere((d) => d.id == downloadId, orElse: () => state.last);
      _persistRecord(item);
    } else if (eventType == 'cancelled') {
      AppLogger.info('Download cancelled: $downloadId', tag: 'download');
      state = [
        for (final d in state)
          if (d.id != downloadId)
            d
          else
            d.copyWith(
              status: 'cancelled',
              speed: 0,
              eta: -1,
              clearStage: true,
              clearStageLabel: true,
              errorType: 'ERROR_CANCELLED',
              errorMessage: 'Download cancelled',
              recoveryAction: 'none',
            ),
      ];
      final item = state.firstWhere((d) => d.id == downloadId, orElse: () => state.last);
      _persistRecord(item);
    }
  }

  void _persistRecord(DownloadItem item) {
    try {
      final record = DownloadRecord(
        id: item.id,
        url: item.url,
        title: item.title,
        platform: _derivePlatform(item.url),
        format: item.config?['format']?.toString(),
        quality: item.config?['quality']?.toString(),
        fileSize: item.totalBytes > 0
            ? item.totalBytes
            : (item.downloadedBytes > 0 ? item.downloadedBytes : null),
        filePath: item.filePath,
        status: item.status,
        progress: item.progress,
        timestamp: item.addedAt.toIso8601String(),
        thumbnailUrl: item.thumbnailUrl,
      );
      DownloadHistoryDb.instance.insert(record).catchError((_) => 0);
    } catch (_) {}
  }

  static String _derivePlatform(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('youtu')) return 'youtube';
    if (lower.contains('tiktok')) return 'tiktok';
    if (lower.contains('instagram')) return 'instagram';
    if (lower.contains('twitter') || lower.contains('x.com')) return 'twitter';
    if (lower.contains('facebook') || lower.contains('fb.com')) return 'facebook';
    if (lower.contains('reddit')) return 'reddit';
    return 'web';
  }

  void retryDownload(String id) {
    final index = state.indexWhere((d) => d.id == id);
    if (index == -1) return;

    final item = state[index];

    state = [
      for (final d in state)
        if (d.id != id)
          d
        else
          d.copyWith(
            status: 'downloading',
            progress: 0,
            downloadedBytes: 0,
            totalBytes: 0,
            speed: 0,
            eta: -1,
            clearStage: true,
            clearStageLabel: true,
          ),
    ];

    _engine.startDownload(
      url: item.url,
      downloadId: id,
      config: item.config ?? <String, dynamic>{},
      networkType: item.networkType ?? 'wifi',
    );
  }

  void cancelDownload(String id) {
    _engine.cancelDownload(id);
    state = [
      for (final d in state)
        if (d.id != id)
          d
        else
          d.copyWith(
            status: 'cancelled',
            speed: 0,
            eta: -1,
            clearStage: true,
            clearStageLabel: true,
            errorType: 'ERROR_CANCELLED',
            errorMessage: 'Download cancelled',
            recoveryAction: 'none',
          ),
    ];
  }

  String _formatFilesize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1073741824) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
  }
}

final downloadProvider =
    StateNotifierProvider<DownloadNotifier, List<DownloadItem>>((ref) {
  final engine = ref.watch(engineProvider);
  final notifier = DownloadNotifier(engine);
  final subscription = engine.progressStream.listen(
    (event) {
      notifier.handleProgressEvent(event);
    },
    onError: (err, stack) {
      AppLogger.warn('Progress stream error: $err', tag: 'download');
    },
  );
  ref.onDispose(() {
    subscription.cancel();
  });
  return notifier;
});

final sharedUrlProvider = StateProvider<String?>((ref) => null);
