import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:io' show File;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../core/database/download_history_db.dart';
import '../core/engine/engine_provider.dart';
import '../core/engine/engine_service.dart';
import '../core/utils/app_logger.dart';

const _uuid = Uuid();

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
  /// Rolling per-download speed history (smoothed bytes/sec samples, oldest
  /// first, capped at [kSpeedHistoryCap]). Transient UI signal for the
  /// sparkline only — never persisted. Empty until samples arrive.
  final List<double> speedHistory;
  /// Post-processing stage key (merging, embedding_thumbnail, …) or null
  /// while plain downloading.
  final String? stage;
  final String? stageLabel;
  final String? thumbnailUrl;
  final String? filePath;
  /// Local thumbnail sidecar file path reported by the engine finished
  /// event (task 03). Preferred over [thumbnailUrl] for Library rendering.
  final String? thumbnailPath;
  final DateTime addedAt;
  final String? fileSize;
  final String? completedDate;
  final String? errorType;
  final String? errorMessage;
  final String? recoveryAction;
  final bool suggestsVpn;
  final Map<String, dynamic>? config;
  final String? networkType;
  final int attempts;
  final int? queuePosition;

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
    this.speedHistory = const [],
    this.stage,
    this.stageLabel,
    this.thumbnailUrl,
    this.thumbnailPath,
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
    this.attempts = 0,
    this.queuePosition,
  }) : addedAt = addedAt ?? DateTime.now();

  DownloadItem copyWith({
    String? status,
    double? progress,
    int? downloadedBytes,
    int? totalBytes,
    double? speed,
    int? eta,
    List<double>? speedHistory,
    bool clearHistory = false,
    String? stage,
    bool clearStage = false,
    String? stageLabel,
    bool clearStageLabel = false,
    String? thumbnailUrl,
    String? thumbnailPath,
    String? filePath,
    String? fileSize,
    String? completedDate,
    String? errorType,
    String? errorMessage,
    String? recoveryAction,
    bool? suggestsVpn,
    Map<String, dynamic>? config,
    String? networkType,
    int? attempts,
    int? queuePosition,
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
      speedHistory:
          clearHistory ? const [] : (speedHistory ?? this.speedHistory),
      stage: clearStage ? null : (stage ?? this.stage),
      stageLabel: clearStageLabel ? null : (stageLabel ?? this.stageLabel),
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
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
      attempts: attempts ?? this.attempts,
      queuePosition: queuePosition ?? this.queuePosition,
    );
  }
}

/// EMA weight on each new speed sample (standard α·new + (1-α)·old form).
/// Mirrors yt-dlp's fragment-path smoothing (`smoothing=0.7` in its inverted
/// convention — mind the inversion, do not copy 0.7 here). Settles in ~5-7
/// samples at 1 Hz yet visibly damps single-sample spikes.
const kSpeedEmaAlpha = 0.3;

/// Lighter second-stage EMA on the derived ETA (yt-dlp ETA convention).
const kEtaEmaAlpha = 0.15;

/// Max retained speed samples per download (60 × 8 B ≈ 0.5 KB).
const kSpeedHistoryCap = 60;

/// Minimum smoothed samples before a derived ETA is shown.
const kEtaGraceSamples = 3;

/// Minimum elapsed time before a derived ETA is shown.
const kEtaGracePeriod = Duration(seconds: 2);

/// Per-download 'downloading' UI update cadence gate. yt-dlp HTTP hooks fire
/// per data block (tens of Hz); each event carries absolute counters so
/// dropping intermediates loses nothing — the next admitted event is latest.
const kProgressCoalesceWindow = Duration(seconds: 1);

/// Per-download smoother state. Lives in the notifier (transient, never
/// persisted); the display-ready ring buffer lives on [DownloadItem].
class _DownloadSmoother {
  double? smoothSpeed;
  double? smoothEta;
  int samples = 0;
  DateTime? firstSampleAt;
  DateTime? lastEmitAt;
  DateTime? lastHeartbeatAt;
  int lastEta = -1;
}

class DownloadNotifier extends StateNotifier<List<DownloadItem>> {
  final EngineService _engine;
  final DateTime Function() _clock;
  final Map<String, _DownloadSmoother> _smoothers = {};

  DownloadNotifier(this._engine, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now,
        super([]);

  List<DownloadItem> get completed =>
      state.where((d) => d.status == 'completed').toList();
  List<DownloadItem> get inProgress =>
      state.where((d) => d.status == 'downloading').toList();
  List<DownloadItem> get queuedItems =>
      state.where((d) => d.status == 'queued').toList();

  bool isDownloading(String url) {
    return state.any((d) => d.url == url && d.status == 'downloading');
  }

  /// True when the URL has any live slot (downloading, pending, or queued).
  /// Guards redownload-while-active collisions (engine also rejects with
  /// ERROR_ALREADY_ACTIVE as backstop).
  bool isActive(String url) {
    return state.any((d) =>
        d.url == url &&
        (d.status == 'downloading' ||
            d.status == 'pending' ||
            d.status == 'cancelling' ||
            d.status == 'queued'));
  }

  bool isActiveId(String id) {
    return state.any((d) =>
        d.id == id &&
        (d.status == 'downloading' ||
            d.status == 'pending' ||
            d.status == 'cancelling' ||
            d.status == 'queued'));
  }

  /// Update max concurrent downloads dynamically (1 to 5).
  Future<void> setMaxConcurrent(int maxConcurrent) async {
    try {
      await _engine.setConcurrency(maxConcurrent);
    } catch (_) {}
  }

  /// Push the user's concurrency preference to the engine backstop
  /// (desktop JSON-RPC + Android Chaquopy handlers; never throws).
  Future<void> syncConcurrency(int maxConcurrent) async {
    try {
      await _engine.setConcurrency(maxConcurrent);
    } catch (_) {}
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
          // Queued items promoted by the engine arrive here first.
          d.copyWith(
            status: (d.status == 'downloading' ||
                    d.status == 'pending' ||
                    d.status == 'queued')
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

    final eventType = event['event'] as String?;
    final downloadId = event['download_id'] as String?;
    if (downloadId == null) return;

    if (eventType == 'queued') {
      // Engine backstop parked this id (at-limit). Surface queue position
      // so the card can render "Queued #N" instead of a stalled 0%.
      state = [
        for (final d in state)
          if (d.id != downloadId)
            d
          else
            d.copyWith(status: 'queued'),
      ];
    } else if (eventType == 'downloading') {
      final downloaded = event['downloaded_bytes'] as int? ?? 0;
      final total = event['total_bytes'] as int? ?? 0;
      final progress = total > 0 ? downloaded / total : 0.0;
      final rawSpeed = (event['speed'] as num?)?.toDouble() ?? 0;
      final index = state.indexWhere((d) => d.id == downloadId);
      if (index == -1) return;
      // 1 Hz coalesce gate (part of the feature, not polish): per-block
      // HTTP callbacks would otherwise rebuild every watcher at tens of Hz
      // and repaint the sparkline per block.
      final now = _clock();
      final smoother =
          _smoothers.putIfAbsent(downloadId, _DownloadSmoother.new);
      final lastEmit = smoother.lastEmitAt;
      if (lastEmit != null &&
          now.difference(lastEmit) < kProgressCoalesceWindow) {
        return;
      }
      smoother.lastEmitAt = now;
      final current = state[index];
      final display = _admitSample(smoother, rawSpeed,
          downloadId: downloadId,
          downloaded: downloaded,
          total: total,
          now: now,
          previous: current.speedHistory);
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
              speed: display.speed,
              eta: display.eta,
              speedHistory: display.history,
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
      final thumbnailPath = event['thumbnail_path'] as String?;
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
              thumbnailPath: thumbnailPath ?? d.thumbnailPath,
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

  /// Admits one coalesced raw speed sample and returns the display values.
  ///
  /// Speed is EMA-filtered (α=[kSpeedEmaAlpha], seeded by the first sample);
  /// ETA is *derived* from remaining/smoothed-speed (raw ETA ratios are never
  /// smoothed directly) with a lighter second EMA (α=[kEtaEmaAlpha]).
  /// Grace: ETA stays unknown until [kEtaGraceSamples] samples or
  /// [kEtaGracePeriod] elapsed. Stall ticks (speed ≤ 0) draw an honest zero
  /// on the graph but hold the last speed/ETA readouts instead of flashing
  /// `--:--`. Unknown totals always yield unknown ETA.
  ({double speed, int eta, List<double> history}) _admitSample(
    _DownloadSmoother s,
    double rawSpeed, {
    required String downloadId,
    required int downloaded,
    required int total,
    required DateTime now,
    required List<double> previous,
  }) {
    s.firstSampleAt ??= now;
    final double displaySpeed;
    var history = <double>[];
    if (rawSpeed > 0) {
      s.samples += 1;
      s.smoothSpeed = s.smoothSpeed == null
          ? rawSpeed
          : kSpeedEmaAlpha * rawSpeed + (1 - kSpeedEmaAlpha) * s.smoothSpeed!;
      displaySpeed = s.smoothSpeed!;
      history = [...previous, displaySpeed];
      if (history.length > kSpeedHistoryCap) {
        history = history.sublist(history.length - kSpeedHistoryCap);
      }
    } else {
      displaySpeed = s.smoothSpeed ?? 0;
      history = [...previous, 0.0];
      if (history.length > kSpeedHistoryCap) {
        history = history.sublist(history.length - kSpeedHistoryCap);
      }
    }

    var eta = s.lastEta;
    final graceOk = s.samples >= kEtaGraceSamples ||
        now.difference(s.firstSampleAt!) >= kEtaGracePeriod;
    if (rawSpeed > 0 &&
        displaySpeed > 0 &&
        total > 0 &&
        graceOk &&
        s.smoothSpeed != null) {
      final remaining = total - downloaded;
      final derived = remaining <= 0 ? 0 : (remaining / displaySpeed).round();
      s.smoothEta = s.smoothEta == null
          ? derived.toDouble()
          : kEtaEmaAlpha * derived + (1 - kEtaEmaAlpha) * s.smoothEta!;
      eta = s.smoothEta!.round();
      if (eta < 0) eta = 0;
      s.lastEta = eta;
    } else if (s.samples == 0) {
      eta = -1;
      s.lastEta = -1;
    }

    // Throttled heartbeat to SQLite (~5s cadence) for DB-driven resume continuity.
    if (downloaded > 0 || total > 0) {
      if (s.lastHeartbeatAt == null ||
          now.difference(s.lastHeartbeatAt!) >= const Duration(seconds: 5)) {
        s.lastHeartbeatAt = now;
        DownloadHistoryDb.instance
            .updateHeartbeat(
              downloadId,
              bytesDownloaded: downloaded,
              totalBytes: total > 0 ? total : null,
              progress: total > 0 ? (downloaded / total).clamp(0.0, 0.99) : 0.0,
              now: now.toIso8601String(),
            )
            .catchError((_) => 0);
      }
    }

    return (speed: displaySpeed, eta: eta, history: history);
  }

  void _persistRecord(DownloadItem item) {
    try {
      final configJson =
          item.config != null ? jsonEncode(item.config) : null;
      final qPos = item.queuePosition ??
          (state.indexWhere((d) => d.id == item.id) >= 0
              ? state.indexWhere((d) => d.id == item.id)
              : null);
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
        thumbnailPath: item.thumbnailPath,
        configJson: configJson,
        queuePosition: qPos,
        attempts: item.attempts,
        lastErrorType: item.errorType,
        lastErrorMessage: item.errorMessage,
        bytesDownloaded: item.downloadedBytes,
        totalBytes: item.totalBytes > 0 ? item.totalBytes : null,
        updatedAt: DateTime.now().toIso8601String(),
      );
      DownloadHistoryDb.instance.insert(record).catchError((_) => 0);
    } catch (_) {}
  }

  /// Sweeps lingering active/queued downloads in SQLite to 'interrupted' on
  /// startup and re-enqueues them if attempts < 3.
  Future<int> restoreInterruptedDownloads({bool autoResume = true}) async {
    final count = await DownloadHistoryDb.instance.sweepActiveToInterrupted();
    if (!autoResume) return count;

    final records = await DownloadHistoryDb.instance.getInterrupted(limit: 50);
    int resumed = 0;
    for (final record in records) {
      Map<String, dynamic> config = {};
      if (record.configJson != null && record.configJson!.isNotEmpty) {
        try {
          config = jsonDecode(record.configJson!) as Map<String, dynamic>;
        } catch (_) {}
      }

      final attempts = record.attempts;
      if (attempts >= 3) {
        // Cap reached: surface as interrupted in memory for manual user resume
        if (!state.any((d) => d.id == record.id)) {
          state = [
            ...state,
            DownloadItem(
              id: record.id,
              title: record.title,
              url: record.url,
              status: 'interrupted',
              progress: record.progress,
              downloadedBytes: record.bytesDownloaded,
              totalBytes: record.totalBytes ?? record.fileSize ?? 0,
              config: config,
              thumbnailUrl: record.thumbnailUrl,
              thumbnailPath: record.thumbnailPath,
              attempts: attempts,
              queuePosition: record.queuePosition,
            ),
          ];
        }
        continue;
      }

      // Auto-resume: increment attempt and re-start
      final nextAttempts = attempts + 1;
      await DownloadHistoryDb.instance.update(record.copyWith(
        attempts: nextAttempts,
        status: 'queued',
        updatedAt: DateTime.now().toIso8601String(),
      ));

      final item = DownloadItem(
        id: record.id,
        title: record.title,
        url: record.url,
        status: 'queued',
        progress: record.progress,
        downloadedBytes: record.bytesDownloaded,
        totalBytes: record.totalBytes ?? record.fileSize ?? 0,
        config: config,
        thumbnailUrl: record.thumbnailUrl,
        thumbnailPath: record.thumbnailPath,
        attempts: nextAttempts,
        queuePosition: record.queuePosition,
      );

      if (!state.any((d) => d.id == record.id)) {
        state = [...state, item];
      }

      _engine
          .startDownload(
        url: record.url,
        downloadId: record.id,
        config: config,
        networkType: config['network_type']?.toString() ?? 'wifi',
      )
          .then((result) {
        if (result['queued'] == true) {
          state = [
            for (final d in state)
              if (d.id != record.id) d else d.copyWith(status: 'queued'),
          ];
        }
      }).catchError((_) {});
      resumed++;
    }
    return resumed;
  }

  void resumeInterrupted(String id) {
    redownload(id, fresh: false);
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
    redownload(id, fresh: false);
  }

  /// Redownload a terminal item reusing the same id (history-row stability).
  /// Terminal-only: active (downloading/pending/queued) ids are refused so
  /// the engine never sees an id collision (orphaned thread + interleaved
  /// progress under one id).
  ///
  /// [fresh] (completed downloads): merges `force_overwrite: true` +
  /// `ignore_archive: true` into the stored config so an intact file is
  /// actually re-fetched instead of hitting the "already downloaded" skip
  /// or the archive skip (Seal #2065 trap). Failed/cancelled retries keep
  /// resume-capable defaults so partial `.part` data is reused.
  void redownload(String id, {bool fresh = false}) {
    final index = state.indexWhere((d) => d.id == id);
    if (index == -1) return;

    final item = state[index];
    // Same-id reuse is only safe from a terminal state. The engine rejects
    // active-id restarts (ERROR_ALREADY_ACTIVE); guard here too so the UI
    // explains instead of silently failing.
    if (item.status == 'downloading' ||
        item.status == 'pending' ||
        item.status == 'cancelling' ||
        item.status == 'queued') {
      AppLogger.warn('Retry blocked: $id is still active (${item.status})',
          tag: 'download');
      return;
    }

    final config = Map<String, dynamic>.from(item.config ?? <String, dynamic>{});
    if (fresh) {
      config['force_overwrite'] = true;
      config['ignore_archive'] = true;
    }

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
            config: config,
          ),
    ];

    _engine.startDownload(
      url: item.url,
      downloadId: id,
      config: config,
      networkType: item.networkType ?? 'wifi',
    ).then((result) {
      // Engine backstop may park this as queued (at-limit): reflect it so
      // the card renders Queued instead of a stalled 0%.
      if (result['queued'] == true) {
        state = [
          for (final d in state)
            if (d.id != id) d else d.copyWith(status: 'queued'),
        ];
      }
      if (result['success'] != true &&
          result['error_type'] == 'ERROR_ALREADY_ACTIVE') {
        AppLogger.warn('Redownload rejected: $id already active',
            tag: 'download');
      }
    }).catchError((_) {});
  }

  /// "Extract audio" (source re-fetch variant): enqueues a NEW audio-only
  /// download of the same URL (best audio → single encode from source).
  /// Returns the new download id, or null when the source item is unknown.
  /// Local-file extraction (zero bandwidth) is the follow-up; this path
  /// reuses the proven pipeline and needs no ffmpeg-direct work.
  Future<String?> downloadAudioFromSource(String id) async {
    final index = state.indexWhere((d) => d.id == id);
    if (index == -1) return null;
    final item = state[index];
    final newId = _uuid.v4();
    final config = Map<String, dynamic>.from(item.config ?? <String, dynamic>{});
    config['audio_only'] = true;
    // Fresh artifact: never hit the completed-file skip or archive skip.
    config['force_overwrite'] = true;
    config['ignore_archive'] = true;
    Map<String, dynamic> result;
    try {
      result = await _engine.startDownload(
        url: item.url,
        downloadId: newId,
        config: config,
        networkType: item.networkType ?? 'wifi',
      );
    } catch (_) {
      return null;
    }
    if (result['success'] != true) return null;
    addDownload(DownloadItem(
      id: newId,
      title: '${item.title} (audio)',
      url: item.url,
      status: result['queued'] == true ? 'queued' : 'downloading',
      config: config,
      networkType: item.networkType ?? 'wifi',
      thumbnailUrl: item.thumbnailUrl,
    ));
    return newId;
  }

  /// Remove the history row only — the file on disk is left untouched.
  Future<void> removeFromHistory(String id) async {
    state = state.where((d) => d.id != id).toList();
    try {
      await DownloadHistoryDb.instance.delete(id);
    } catch (_) {}
    AppLogger.info('Removed from history: $id', tag: 'download');
  }

  /// Delete the downloaded file (if present and the item is terminal) AND
  /// remove the history row. Active items are refused — Cancel first.
  /// Returns true when the row was removed. Never throws.
  Future<bool> deleteFileAndHistory(String id) async {
    final index = state.indexWhere((d) => d.id == id);
    if (index == -1) return false;
    final item = state[index];
    if (item.status == 'downloading' ||
        item.status == 'pending' ||
        item.status == 'cancelling' ||
        item.status == 'queued') {
      AppLogger.warn('Delete blocked: $id is still active (${item.status})',
          tag: 'download');
      return false;
    }
    var deletedFile = false;
    final path = item.filePath;
    if (path != null && path.isNotEmpty) {
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
          deletedFile = true;
        }
      } catch (_) {}
    }
    state = state.where((d) => d.id != id).toList();
    try {
      await DownloadHistoryDb.instance.delete(id);
    } catch (_) {}
    AppLogger.info(
        'Deleted ${deletedFile ? 'file + ' : ''}history: $id', tag: 'download');
    return true;
  }

  /// Clear the engine download-archive file (recovery when re-downloads are
  /// skipped as "already recorded in the archive"). Never throws.
  Future<Map<String, dynamic>> clearArchive() async {
    try {
      return await _engine.clearArchive();
    } catch (_) {
      return {'success': false};
    }
  }

  void cancelDownload(String id) {
    _engine.cancelDownload(id);
    // T1-3: honest intermediate — the worker may still be winding down
    // (extractor/merge/socket/aria2c are hook-blind). The terminal
    // 'cancelled' event finalizes this; error fields are set there, not here.
    state = [
      for (final d in state)
        if (d.id != id)
          d
        else
          d.copyWith(
            status: 'cancelling',
            speed: 0,
            eta: -1,
            clearStage: true,
            clearStageLabel: true,
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
  // Auto-sweep and restore interrupted downloads across process restart / LMK
  notifier.restoreInterruptedDownloads();
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
