import 'package:flutter_riverpod/flutter_riverpod.dart';
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
  }

  void updateProgress(String id, double progress, int downloadedBytes) {
    state = state.map((d) {
      if (d.id != id) return d;
      // Progress events (including per-stream completions) must never flip
      // status to 'completed' — only the terminal 'finished' event does that
      // (after FFmpeg merge + post-processing). Hold at 99% meanwhile.
      final isActive = d.status == 'downloading' || d.status == 'pending';
      return DownloadItem(
        id: d.id,
        title: d.title,
        url: d.url,
        status: isActive ? 'downloading' : d.status,
        progress: progress.clamp(0.0, 0.99),
        downloadedBytes: downloadedBytes,
        totalBytes: d.totalBytes,
        thumbnailUrl: d.thumbnailUrl,
        filePath: d.filePath,
        addedAt: d.addedAt,
        fileSize: d.fileSize,
        completedDate: d.completedDate,
        config: d.config,
        networkType: d.networkType,
      );
    }).toList();
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
      updateProgress(downloadId, progress, downloaded);

      state = state.map((d) {
        if (d.id != downloadId) return d;
        return DownloadItem(
          id: d.id,
          title: d.title,
          url: d.url,
          status: 'downloading',
          progress: progress.clamp(0.0, 0.99),
          downloadedBytes: downloaded,
          totalBytes: total,
          thumbnailUrl: d.thumbnailUrl,
          filePath: d.filePath,
          addedAt: d.addedAt,
          config: d.config,
          networkType: d.networkType,
        );
      }).toList();
    } else if (eventType == 'stream_finished') {
      // One stream (e.g. DASH video) landed; more may follow, then FFmpeg
      // merge + post-processing. Record bytes, hold below 100%, stay
      // 'downloading' — only terminal 'finished' completes the item.
      final filesize = event['filesize_bytes'] as int? ?? 0;
      state = state.map((d) {
        if (d.id != downloadId) return d;
        final known = filesize > d.totalBytes ? filesize : d.totalBytes;
        return DownloadItem(
          id: d.id,
          title: d.title,
          url: d.url,
          status: 'downloading',
          progress: d.progress.clamp(0.0, 0.99),
          downloadedBytes: filesize > 0 ? filesize : d.downloadedBytes,
          totalBytes: known,
          thumbnailUrl: d.thumbnailUrl,
          filePath: d.filePath,
          addedAt: d.addedAt,
          config: d.config,
          networkType: d.networkType,
        );
      }).toList();
    } else if (eventType == 'finished') {
      final filesize = event['filesize_bytes'] as int? ?? 0;
      final sizeStr = _formatFilesize(filesize);
      // Terminal outcome — one line per download (never per-progress) so
      // diagnostics reports always show what happened. ID + outcome only,
      // never the URL (may carry auth query params).
      AppLogger.info('Download finished: $downloadId ($sizeStr)',
          tag: 'download');

      state = state.map((d) {
        if (d.id != downloadId) return d;
        return DownloadItem(
          id: d.id,
          title: d.title,
          url: d.url,
          status: 'completed',
          progress: 1.0,
          downloadedBytes: filesize,
          totalBytes: filesize,
          thumbnailUrl: d.thumbnailUrl,
          addedAt: d.addedAt,
          fileSize: sizeStr,
          completedDate: 'Today',
          config: d.config,
          networkType: d.networkType,
        );
      }).toList();
    } else if (eventType == 'error') {
      final errorType = event['error_type'] as String?;
      final errorMessage = event['error_message'] as String?;
      final suggestsVpn = event['suggests_vpn'] as bool? ?? false;
      AppLogger.warn(
          'Download failed: $downloadId [$errorType]${suggestsVpn ? ' (VPN may help)' : ''}',
          tag: 'download');

      state = state.map((d) {
        if (d.id != downloadId) return d;
        return DownloadItem(
          id: d.id,
          title: d.title,
          url: d.url,
          status: 'error',
          progress: d.progress,
          downloadedBytes: d.downloadedBytes,
          totalBytes: d.totalBytes,
          thumbnailUrl: d.thumbnailUrl,
          addedAt: d.addedAt,
          errorType: errorType,
          errorMessage: errorMessage,
          suggestsVpn: suggestsVpn,
          config: d.config,
          networkType: d.networkType,
        );
      }).toList();
    } else if (eventType == 'cancelled') {
      AppLogger.info('Download cancelled: $downloadId', tag: 'download');
      state = state.map((d) {
        if (d.id != downloadId) return d;
        return DownloadItem(
          id: d.id,
          title: d.title,
          url: d.url,
          status: 'cancelled',
          progress: d.progress,
          downloadedBytes: d.downloadedBytes,
          totalBytes: d.totalBytes,
          thumbnailUrl: d.thumbnailUrl,
          addedAt: d.addedAt,
          errorType: 'ERROR_CANCELLED',
          errorMessage: 'Download cancelled',
          recoveryAction: 'none',
          config: d.config,
          networkType: d.networkType,
        );
      }).toList();
    }
  }

  void retryDownload(String id) {
    final index = state.indexWhere((d) => d.id == id);
    if (index == -1) return;

    final item = state[index];

    state = state.map((d) {
      if (d.id != id) return d;
      return DownloadItem(
        id: d.id,
        title: d.title,
        url: d.url,
        status: 'downloading',
        progress: 0,
        downloadedBytes: 0,
        totalBytes: 0,
        thumbnailUrl: d.thumbnailUrl,
        addedAt: d.addedAt,
        config: d.config,
        networkType: d.networkType,
      );
    }).toList();

    _engine.startDownload(
      url: item.url,
      downloadId: id,
      config: item.config ?? <String, dynamic>{},
      networkType: item.networkType ?? 'wifi',
    );
  }

  void cancelDownload(String id) {
    _engine.cancelDownload(id);
    state = state.map((d) {
      if (d.id != id) return d;
      return DownloadItem(
        id: d.id,
        title: d.title,
        url: d.url,
        status: 'cancelled',
        progress: d.progress,
        downloadedBytes: d.downloadedBytes,
        totalBytes: d.totalBytes,
        thumbnailUrl: d.thumbnailUrl,
        addedAt: d.addedAt,
        errorType: 'ERROR_CANCELLED',
        errorMessage: 'Download cancelled',
        recoveryAction: 'none',
        config: d.config,
        networkType: d.networkType,
      );
    }).toList();
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
  final subscription = engine.progressStream.listen((event) {
    notifier.handleProgressEvent(event);
  });
  ref.onDispose(() {
    subscription.cancel();
  });
  return notifier;
});

final sharedUrlProvider = StateProvider<String?>((ref) => null);
