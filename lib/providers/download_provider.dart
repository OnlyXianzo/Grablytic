import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/engine/engine_provider.dart';
import '../core/engine/engine_service.dart';

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

  void addDownload(DownloadItem item) {
    state = [...state, item];
  }

  void updateProgress(String id, double progress, int downloadedBytes) {
    state = state.map((d) {
      if (d.id != id) return d;
      return DownloadItem(
        id: d.id,
        title: d.title,
        url: d.url,
        status: progress >= 1.0 ? 'completed' : 'downloading',
        progress: progress,
        downloadedBytes: downloadedBytes,
        totalBytes: d.totalBytes,
        thumbnailUrl: d.thumbnailUrl,
        filePath: d.filePath,
        addedAt: d.addedAt,
        fileSize: d.fileSize,
        completedDate: progress >= 1.0 ? 'Today' : null,
        config: d.config,
        networkType: d.networkType,
      );
    }).toList();
  }

  void handleProgressEvent(Map<String, dynamic> event) {
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
          progress: progress,
          downloadedBytes: downloaded,
          totalBytes: total,
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
