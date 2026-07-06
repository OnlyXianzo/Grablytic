import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../core/engine/engine_provider.dart';
import 'download_provider.dart';
import 'playlist_provider.dart';
import 'preset_provider.dart';

const _uuid = Uuid();

enum BatchItemStatus { pending, downloading, completed, failed }

class BatchItem {
  final String url;
  final String title;
  final BatchItemStatus status;
  final double progress;

  const BatchItem({
    required this.url,
    required this.title,
    this.status = BatchItemStatus.pending,
    this.progress = 0,
  });

  BatchItem copyWith({BatchItemStatus? status, double? progress}) {
    return BatchItem(
      url: url,
      title: title,
      status: status ?? this.status,
      progress: progress ?? this.progress,
    );
  }
}

class BatchState {
  final List<BatchItem> items;
  final int currentIndex;
  final bool isRunning;
  final String? playlistId;

  const BatchState({
    required this.items,
    this.currentIndex = 0,
    this.isRunning = false,
    this.playlistId,
  });

  BatchState copyWith({
    List<BatchItem>? items,
    int? currentIndex,
    bool? isRunning,
    String? playlistId,
  }) {
    return BatchState(
      items: items ?? this.items,
      currentIndex: currentIndex ?? this.currentIndex,
      isRunning: isRunning ?? this.isRunning,
      playlistId: playlistId ?? this.playlistId,
    );
  }
}

class BatchNotifier extends StateNotifier<BatchState> {
  final Ref _ref;

  BatchNotifier(this._ref) : super(const BatchState(items: []));

  void startBatch(List<BatchItem> items, {String? playlistId}) {
    state = BatchState(items: items, isRunning: true, playlistId: playlistId);
    processNext();
  }

  void cancelItem(int index) {
    if (index < 0 || index >= state.items.length) return;
    final updated = [...state.items];
    final item = updated[index];
    if (item.status == BatchItemStatus.pending ||
        item.status == BatchItemStatus.downloading) {
      updated[index] = item.copyWith(status: BatchItemStatus.failed);
      state = state.copyWith(items: updated);
    }
    final remaining =
        state.items.where((i) => i.status == BatchItemStatus.pending).length;
    if (remaining <= 0) {
      state = state.copyWith(isRunning: false);
    }
  }

  void cancelAll() {
    final updated = state.items.map((item) {
      if (item.status == BatchItemStatus.pending ||
          item.status == BatchItemStatus.downloading) {
        return item.copyWith(status: BatchItemStatus.failed);
      }
      return item;
    }).toList();
    state = state.copyWith(items: updated, isRunning: false);
  }

  void processNext() {
    final pendingIndex = state.items
        .indexWhere((item) => item.status == BatchItemStatus.pending);

    if (pendingIndex == -1) {
      state = state.copyWith(isRunning: false);
      return;
    }

    final updated = [...state.items];
    updated[pendingIndex] = updated[pendingIndex].copyWith(
      status: BatchItemStatus.downloading,
    );
    state = state.copyWith(items: updated, currentIndex: pendingIndex);

    final item = state.items[pendingIndex];
    if (_ref.read(downloadProvider.notifier).isDownloading(item.url)) {
      _updateItem(pendingIndex, status: BatchItemStatus.completed, progress: 1.0);
      processNext();
      return;
    }

    final engine = _ref.read(engineProvider);
    final downloadId = _uuid.v4();
    final activePreset = _ref.read(presetsProvider).activePreset;

    final config = <String, dynamic>{
      'container': activePreset.preferredContainer,
      'quality_ceiling': activePreset.qualityCeiling,
      'audio_only': activePreset.audioOnly,
    };

    engine
        .startDownload(
      url: item.url,
      downloadId: downloadId,
      config: config,
      networkType: 'wifi',
    )
        .then((result) {
      if (result['success'] == true) {
        _ref.read(downloadProvider.notifier).addDownload(
              DownloadItem(
                id: downloadId,
                title: item.title,
                url: item.url,
                status: 'downloading',
              ),
            );

        if (state.playlistId != null) {
          _ref
              .read(playlistProvider.notifier)
              .addDownloadToPlaylist(state.playlistId!, downloadId);
        }

        _updateItem(
          pendingIndex,
          status: BatchItemStatus.completed,
          progress: 1.0,
        );
      } else {
        _updateItem(pendingIndex, status: BatchItemStatus.failed);
      }
      processNext();
    }).catchError((_) {
      _updateItem(pendingIndex, status: BatchItemStatus.failed);
      processNext();
    });
  }

  void _updateItem(int index, {BatchItemStatus? status, double? progress}) {
    if (index < 0 || index >= state.items.length) return;
    final updated = [...state.items];
    updated[index] =
        updated[index].copyWith(status: status, progress: progress);
    state = state.copyWith(items: updated);
  }
}

final batchProvider =
    StateNotifierProvider<BatchNotifier, BatchState>((ref) {
  return BatchNotifier(ref);
});
