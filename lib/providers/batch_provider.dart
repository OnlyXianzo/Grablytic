import 'dart:async' show unawaited;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../core/database/download_history_db.dart';
import '../core/engine/engine_provider.dart';
import '../core/engine/engine_service.dart';
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

  /// True when [BatchNotifier.processNext] hit the quiet-hours schedule
  /// gate and parked the queue instead of dispatching. The item it was
  /// about to start is back to `pending`; the UI can say "paused until
  /// `<window>`" rather than showing a spinner that never moves.
  final bool scheduleBlocked;

  /// Create batch state; [scheduleBlocked] marks a pause outside allowed hours.
  const BatchState({
    required this.items,
    this.currentIndex = 0,
    this.isRunning = false,
    this.playlistId,
    this.qualityCeiling,
    this.skipExisting = true,
    this.scheduleBlocked = false,
  });

  /// Copy the state, retaining existing values for omitted or null arguments.
  BatchState copyWith({
    List<BatchItem>? items,
    int? currentIndex,
    bool? isRunning,
    String? playlistId,
    String? qualityCeiling,
    bool? skipExisting,
    bool? scheduleBlocked,
  }) {
    return BatchState(
      items: items ?? this.items,
      currentIndex: currentIndex ?? this.currentIndex,
      isRunning: isRunning ?? this.isRunning,
      playlistId: playlistId ?? this.playlistId,
      qualityCeiling: qualityCeiling ?? this.qualityCeiling,
      skipExisting: skipExisting ?? this.skipExisting,
      scheduleBlocked: scheduleBlocked ?? this.scheduleBlocked,
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

  /// Mark pending and dispatching items failed and invalidate async results.
  /// Clears the schedule pause; does not send cancellation to the engine.
  void cancelAll() {
    _generation++;
    final updated = state.items.map((item) {
      if (item.status == BatchItemStatus.pending ||
          item.status == BatchItemStatus.downloading) {
        return item.copyWith(status: BatchItemStatus.failed);
      }
      return item;
    }).toList();
    state = state.copyWith(
      items: updated,
      isRunning: false,
      scheduleBlocked: false,
    );
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

  /// Dispatch the first pending item, or stop when no pending items remain.
  ///
  /// Outside the schedule window, park the batch with items still pending;
  /// another call is needed to resume. URLs already active in the download
  /// provider are marked completed and skipped. Completion here means accepted
  /// by the engine, including queued work; media completion is tracked there.
  void processNext() {
    // A loop, not recursion: an item whose URL is already downloading used
    // to recurse synchronously, so a long playlist of duplicates (or one
    // long enough that every entry hits) burned a stack frame per skip.
    while (true) {
      final pendingIndex = state.items
          .indexWhere((item) => item.status == BatchItemStatus.pending);

      if (pendingIndex == -1) {
        state = state.copyWith(isRunning: false, scheduleBlocked: false);
        return;
      }

      final item = state.items[pendingIndex];

      // Schedule gate (headless runner has no dialog): pause the batch and
      // leave remaining items pending instead of starting silently. This
      // check runs BEFORE the item is marked downloading — it used to run
      // after, so parking outside quiet hours left one item spinning
      // "downloading" for ever while `retryFailed` refused to touch it
      // (not failed) and `processNext` refused to advance (not pending).
      if (!isWithinScheduleWindow(
        _ref.read(settingsProvider),
        DateTime.now(),
      )) {
        state = state.copyWith(isRunning: false, scheduleBlocked: true);
        return;
      }

      if (_ref.read(downloadProvider.notifier).isDownloading(item.url)) {
        _updateItem(
          pendingIndex,
          status: BatchItemStatus.completed,
          progress: 1.0,
        );
        continue;
      }

      final updated = [...state.items];
      updated[pendingIndex] = item.copyWith(
        status: BatchItemStatus.downloading,
      );
      state = state.copyWith(
        items: updated,
        currentIndex: pendingIndex,
        scheduleBlocked: false,
      );

      final engine = _ref.read(engineProvider);
      final downloadId = _uuid.v4();
      final activePreset = _ref.read(presetsProvider).activePreset;
      final ceiling = state.qualityCeiling ?? activePreset.qualityCeiling;
      final baseConfig = <String, dynamic>{
        'container': activePreset.preferredContainer,
        'quality_ceiling': ceiling,
        'audio_only': activePreset.audioOnly,
      };
      unawaited(_dispatchBatchItem(
        engine: engine, downloadId: downloadId, item: item,
        index: pendingIndex, generation: _generation, baseConfig: baseConfig,
      ));
      return;
    }
  }

  /// Submit an item with secure settings merged over [baseConfig], then advance.
  ///
  /// Ignore results for an obsolete [generation] or a disposed notifier. Apply
  /// results only while [index] is still downloading, preserving cancellation.
  /// Rejections and caught errors mark that item failed; accepted work is added
  /// to downloads and the optional playlist before marking the batch item done.
  Future<void> _dispatchBatchItem({
    required EngineService engine,
    required String downloadId,
    required BatchItem item,
    required int index,
    required int generation,
    required Map<String, dynamic> baseConfig,
  }) async {
    try {
      final settingsConfig = await secureSettingsDownloadConfig(_ref.read(settingsProvider.notifier));
      if (!mounted || generation != _generation) return;
      final config = <String, dynamic>{...baseConfig, ...settingsConfig};
      final result = await engine.startDownload(
        url: item.url, downloadId: downloadId, config: config, networkType: 'wifi',
      );
      if (!mounted || generation != _generation) return;
      if (result['success'] == true) {
        // The user may have cancelled this item while the engine was
        // starting. A cancel marks it failed; without this guard the
        // success branch flipped it back to completed and the row claimed
        // a download the user had just cancelled.
        // (No early return: falling through still advances the queue.)
        if (_isStillDownloading(index)) {
          _ref.read(downloadProvider.notifier).addDownload(DownloadItem(
            id: downloadId, title: item.title, url: item.url,
            status: result['queued'] == true ? 'queued' : 'downloading',
            thumbnailUrl: item.thumbnailUrl, config: config,
          ));
          final playlistId = state.playlistId;
          if (playlistId != null) {
            _ref.read(playlistProvider.notifier).addDownloadToPlaylist(playlistId, downloadId);
          }
          _updateItem(index, status: BatchItemStatus.completed, progress: 1.0);
        }
      } else if (_isStillDownloading(index)) {
        _updateItem(index, status: BatchItemStatus.failed,
          lastErrorType: _stringOrNull(result['error_type']),
          lastErrorMessage: _stringOrNull(result['error_message']));
      }
    } catch (error) {
      if (!mounted || generation != _generation) return;
      if (_isStillDownloading(index)) {
        _updateItem(index, status: BatchItemStatus.failed,
            lastErrorMessage: '$error');
      }
    }
    if (mounted && generation == _generation) processNext();
  }

  /// True when [index] still points at an item the batch owns as
  /// `downloading` — i.e. nobody cancelled or replaced it meanwhile.
  bool _isStillDownloading(int index) {
    if (index < 0 || index >= state.items.length) return false;
    return state.items[index].status == BatchItemStatus.downloading;
  }

  /// Engine results are typed `dynamic`; an integer code used to throw a
  /// cast error inside the success branch and lose the real message.
  static String? _stringOrNull(Object? value) {
    if (value == null) return null;
    if (value is String) return value;
    return value.toString();
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
