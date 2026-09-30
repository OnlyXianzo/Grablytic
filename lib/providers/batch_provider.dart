import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../core/database/download_history_db.dart';
import '../core/engine/engine_provider.dart';
import '../core/utils/download_config.dart';
import '../core/utils/history_guard.dart';
import '../core/utils/schedule_guard.dart';
import 'download_provider.dart';
import 'playlist_provider.dart';
import 'preset_provider.dart';
import 'settings_provider.dart';

const _uuid = Uuid();

/// Title suffix marking a batch entry skipped as already downloaded.
/// Client-side pre-filter surfacing — engine archive semantics unchanged.
const alreadyHaveSuffix = ' (already have)';

/// Pure, unit-tested pre-filter: entries whose canonical URL matches a
/// completed history record are marked completed (progress 1.0) with the
/// [alreadyHaveSuffix] title suffix, so the dispatcher never sends them
/// to the engine. Non-matches and already-suffixed titles pass through
/// untouched. Idempotent — running twice never double-suffixes.
List<BatchItem> markAlreadyHaveItems(
  List<BatchItem> items,
  List<DownloadRecord> completedRecords,
) {
  if (items.isEmpty || completedRecords.isEmpty) return items;
  return items.map((item) {
    if (item.status != BatchItemStatus.pending) return item;
    if (item.title.endsWith(alreadyHaveSuffix)) return item;
    if (findDuplicate(completedRecords, item.url) == null) return item;
    return item.copyWith(
      title: '${item.title}$alreadyHaveSuffix',
      status: BatchItemStatus.completed,
      progress: 1.0,
    );
  }).toList();
}

enum BatchItemStatus { pending, downloading, completed, failed }

class BatchItem {
  final String url;
  final String title;
  final BatchItemStatus status;
  final double progress;
  final String? thumbnailUrl;

  /// Engine-classified failure reason (see engine/grablytic_engine/errors.py
  /// via startDownload's error_type/error_message result keys). Null unless
  /// this item has failed at least once.
  final String? lastErrorType;
  final String? lastErrorMessage;

  const BatchItem({
    required this.url,
    required this.title,
    this.status = BatchItemStatus.pending,
    this.progress = 0,
    this.thumbnailUrl,
    this.lastErrorType,
    this.lastErrorMessage,
  });

  BatchItem copyWith({
    String? title,
    BatchItemStatus? status,
    double? progress,
    String? thumbnailUrl,
    String? lastErrorType,
    String? lastErrorMessage,

    /// Set to clear a previous failure reason (e.g. on retry).
    /// Needed because null [lastErrorType]/[lastErrorMessage] means "keep".
    bool clearError = false,
  }) {
    return BatchItem(
      url: url,
      title: title ?? this.title,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      lastErrorType: clearError ? null : (lastErrorType ?? this.lastErrorType),
      lastErrorMessage:
          clearError ? null : (lastErrorMessage ?? this.lastErrorMessage),
    );
  }
}

/// Error types that mean "this URL has no downloadable video" (Instagram
/// photo posts and carousel image children surface as
/// ERROR_FORMAT_UNAVAILABLE via "no video formats found"; private posts as
/// ERROR_PRIVATE). Failed items with these types are triaged as skipped —
/// retrying them is pointless.
const kBatchNoVideoErrorTypes = {
  'ERROR_FORMAT_UNAVAILABLE',
  'ERROR_PRIVATE',
};

/// True when a failed item was triaged as "no video — skipped".
bool batchItemSkipped(BatchItem item) =>
    item.status == BatchItemStatus.failed &&
    kBatchNoVideoErrorTypes.contains(item.lastErrorType);

/// User-facing failure reason for a batch item: friendly "no video —
/// skipped" for photo/carousel/private posts, the engine's error text for
/// transient failures, plain "Failed" when nothing was recorded.
String batchFailureLabel(BatchItem item) {
  if (kBatchNoVideoErrorTypes.contains(item.lastErrorType)) {
    return 'no video — skipped';
  }
  final message = item.lastErrorMessage;
  if (message != null && message.trim().isNotEmpty) return message;
  return 'Failed';
}

class BatchState {
  final List<BatchItem> items;
  final int currentIndex;
  final bool isRunning;
  final String? playlistId;

  /// Quality ceiling snapshot for the whole batch (e.g. '480p', '720p',
  /// '1080p', 'best'). Null means "follow the live active preset".
  /// Snapshotting at [BatchNotifier.startBatch] keeps every item on the
  /// quality the user picked before the batch started, even if the global
  /// preset changes mid-queue.
  final String? qualityCeiling;

  /// Client-side skip-existing pre-filter (FEATURE 3): when true (default),
  /// [BatchNotifier.startBatch] marks entries already in the completed
  /// history as completed with the "(already have)" title suffix before
  /// dispatch, so the engine archive behavior becomes per-batch visible.
  /// Engine archive semantics are unchanged — this only avoids dispatch.
  final bool skipExisting;

  const BatchState({
    required this.items,
    this.currentIndex = 0,
    this.isRunning = false,
    this.playlistId,
    this.qualityCeiling,
    this.skipExisting = true,
  });

  BatchState copyWith({
    List<BatchItem>? items,
    int? currentIndex,
    bool? isRunning,
    String? playlistId,
    String? qualityCeiling,
    bool? skipExisting,
  }) {
    return BatchState(
      items: items ?? this.items,
      currentIndex: currentIndex ?? this.currentIndex,
      isRunning: isRunning ?? this.isRunning,
      playlistId: playlistId ?? this.playlistId,
      qualityCeiling: qualityCeiling ?? this.qualityCeiling,
      skipExisting: skipExisting ?? this.skipExisting,
    );
  }
}

class BatchNotifier extends StateNotifier<BatchState> {
  final Ref _ref;

  /// Monotonic batch generation: guards the async skip-existing pre-filter
  /// against races with cancelAll / a superseding startBatch.
  int _generation = 0;

  BatchNotifier(this._ref) : super(const BatchState(items: []));

  void startBatch(List<BatchItem> items,
      {String? playlistId, String? qualityCeiling, bool skipExisting = true}) {
    _generation++;
    state = BatchState(
      items: items,
      isRunning: true,
      playlistId: playlistId,
      qualityCeiling: qualityCeiling,
      skipExisting: skipExisting,
    );
    if (skipExisting) {
      _prefilterAlreadyHave(_generation);
    } else {
      processNext();
    }
  }

  /// Async skip-existing pre-filter: reads completed history records and
  /// marks duplicates via [markAlreadyHaveItems] before the first dispatch.
  /// Fail-open — history unavailable/slow means the batch proceeds
  /// unfiltered (engine archive still applies server-side).
  Future<void> _prefilterAlreadyHave(int generation) async {
    List<DownloadRecord> completed = const [];
    try {
      completed = await DownloadHistoryDb.instance
          .getCompleted()
          .timeout(const Duration(seconds: 2), onTimeout: () => completed);
    } catch (_) {
      // History unavailable — proceed without the guard, never block.
    }
    if (!mounted || generation != _generation) return;
    if (completed.isNotEmpty) {
      state = state.copyWith(
        items: markAlreadyHaveItems(state.items, completed),
      );
      if (!mounted || generation != _generation) return;
    }
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
    _generation++;
    final updated = state.items.map((item) {
      if (item.status == BatchItemStatus.pending ||
          item.status == BatchItemStatus.downloading) {
        return item.copyWith(status: BatchItemStatus.failed);
      }
      return item;
    }).toList();
    state = state.copyWith(items: updated, isRunning: false);
  }

  /// Retry failed items only: completed items are kept, failed items go
  /// back to pending (failure reason cleared), then the queue resumes.
  /// No-op when nothing failed or a batch is already running.
  void retryFailed() {
    final failedCount = state.items
        .where((i) => i.status == BatchItemStatus.failed)
        .length;
    if (failedCount == 0 || state.isRunning) return;
    final updated = state.items.map((item) {
      if (item.status == BatchItemStatus.failed) {
        return item.copyWith(
          status: BatchItemStatus.pending,
          progress: 0,
          clearError: true,
        );
      }
      return item;
    }).toList();
    state = state.copyWith(items: updated, isRunning: true);
    processNext();
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
    // Schedule gate (headless runner has no dialog): pause the batch and
    // leave remaining items pending instead of starting silently.
    if (!isWithinScheduleWindow(_ref.read(settingsProvider), DateTime.now())) {
      state = state.copyWith(isRunning: false);
      return;
    }
    if (_ref.read(downloadProvider.notifier).isDownloading(item.url)) {
      _updateItem(pendingIndex, status: BatchItemStatus.completed, progress: 1.0);
      processNext();
      return;
    }

    final engine = _ref.read(engineProvider);
    final downloadId = _uuid.v4();
    final activePreset = _ref.read(presetsProvider).activePreset;
    // Batch snapshot wins over the live preset so a mid-queue preset
    // change cannot split the batch across two qualities.
    final ceiling = state.qualityCeiling ?? activePreset.qualityCeiling;

    final config = <String, dynamic>{
      'container': activePreset.preferredContainer,
      'quality_ceiling': ceiling,
      'audio_only': activePreset.audioOnly,
      ...settingsDownloadConfig(_ref.read(settingsProvider)),
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
                status: result['queued'] == true ? 'queued' : 'downloading',
                thumbnailUrl: item.thumbnailUrl,
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
        _updateItem(
          pendingIndex,
          status: BatchItemStatus.failed,
          lastErrorType: result['error_type'] as String?,
          lastErrorMessage: result['error_message'] as String?,
        );
      }
      processNext();
    }).catchError((Object err) {
      _updateItem(
        pendingIndex,
        status: BatchItemStatus.failed,
        lastErrorMessage: '$err',
      );
      processNext();
    });
  }

  void _updateItem(
    int index, {
    BatchItemStatus? status,
    double? progress,
    String? lastErrorType,
    String? lastErrorMessage,
  }) {
    if (index < 0 || index >= state.items.length) return;
    final updated = [...state.items];
    updated[index] = updated[index].copyWith(
      status: status,
      progress: progress,
      lastErrorType: lastErrorType,
      lastErrorMessage: lastErrorMessage,
    );
    state = state.copyWith(items: updated);
  }
}

final batchProvider =
    StateNotifierProvider<BatchNotifier, BatchState>((ref) {
  return BatchNotifier(ref);
});
