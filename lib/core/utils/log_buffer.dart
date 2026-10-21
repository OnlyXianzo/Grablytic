import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'log_entry.dart';

class LogBuffer {
  final int maxEntries;
  final int maxEntriesPerDownload;
  final int maxRetainedDownloads;

  // O(1) eviction: List.removeAt(0) memmoves up to 5000 entries per log
  // line at tens-of-Hz engine rates. Queues drop the oldest in constant
  // time; iteration order stays insertion-ordered so all views behave
  // exactly as before.
  final Queue<LogEntry> _entries = ListQueue<LogEntry>();
  final Map<String, Queue<LogEntry>> _perDownloadEntries = {};
  final LinkedHashSet<String> _downloadLru = LinkedHashSet<String>();

  final StreamController<LogEntry> _controller =
      StreamController<LogEntry>.broadcast();
  LogLevel _minLevel = LogLevel.debug;
  String? _tagFilter;
  String? _searchFilter;
  String? _sourceFilter; // 'engine', 'ui', or null (all)

  /// Ceiling, written down because it is a product and not a bound:
  /// `maxEntries + maxRetainedDownloads * maxEntriesPerDownload`
  /// = 30,000 objects with the desktop defaults, 4,000 on Android.
  ///
  /// The per-download queues are what made the old numbers add up to
  /// something no single constant described.
  LogBuffer({
    this.maxEntries = 5000,
    this.maxEntriesPerDownload = 500,
    this.maxRetainedDownloads = 50,
  });

  /// Mobile default: a phone does not need a 5,000-line ring, and the
  /// per-download queues are the ones that multiply. ~4,000 entries here
  /// against ~30,000 on desktop.
  factory LogBuffer.forThisPlatform() {
    // `defaultTargetPlatform` instead of `Platform.isAndroid`: it is pure
    // Dart (no dart:io probe that throws on hosts without a platform),
    // and it is overridable in tests.
    final mobile =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    return mobile
        ? LogBuffer(
            maxEntries: 2000,
            maxEntriesPerDownload: 200,
            maxRetainedDownloads: 10,
          )
        : LogBuffer();
  }

  Stream<LogEntry> get stream => _controller.stream;

  /// Live, unmodifiable view — no copy.
  ///
  /// `List.unmodifiable(_entries)` allocated a fresh 5,000-element list on
  /// every read, and the log screen reads it on every rebuild.
  Iterable<LogEntry> get view => UnmodifiableListView(_entries);

  /// Bounded copy, newest [limit] entries, oldest-first.
  ///
  /// For callers that render: they get at most [limit] entries no matter
  /// how large the ring has grown.
  List<LogEntry> snapshot({int limit = 500}) {
    if (_entries.length <= limit) return List<LogEntry>.of(_entries);
    return List<LogEntry>.of(_entries.skip(_entries.length - limit));
  }

  /// The newest [limit] entries that satisfy [test], oldest-first.
  ///
  /// #95: the live log view used to take `snapshot(limit)` FIRST and filter
  /// afterwards, so a filter that matched older lines showed a shorter list
  /// than the ring holds — on desktop the ring is bigger than the render
  /// budget, so matches silently fell off the top. This walks the whole ring
  /// once, newest-to-oldest, and keeps only the matches it will render: O(n)
  /// time, O(limit) memory, and the newest match always wins a slot.
  List<LogEntry> filter({
    required bool Function(LogEntry entry) test,
    int limit = 2000,
  }) {
    if (limit <= 0) return <LogEntry>[];
    final matches = ListQueue<LogEntry>();
    for (final entry in _entries) {
      if (!test(entry)) continue;
      if (matches.length == limit) matches.removeFirst();
      matches.add(entry);
    }
    return List<LogEntry>.of(matches);
  }

  /// Read-only copy of every retained entry.
  ///
  /// Unmodifiable on purpose (a caller that appends to this would be
  /// writing into a copy and silently losing the write). Allocates — use
  /// [view] or [snapshot] on any path a user can trigger.
  List<LogEntry> get entries => List<LogEntry>.unmodifiable(_entries);

  void add(LogEntry entry) {
    // Gate FIRST. This used to record into the per-download queues before
    // the level/tag/search/source filters ran, so an entry the user had
    // explicitly filtered out was retained anyway — the filters changed
    // what you saw, not what the app kept in memory.
    if (entry.level.index < _minLevel.index) return;
    if (_tagFilter != null && !entry.logger.contains(_tagFilter!)) return;
    if (_searchFilter != null && !entry.matches(_searchFilter!.toLowerCase())) {
      return;
    }
    if (_sourceFilter != null && entry.source != _sourceFilter) return;

    final did = entry.downloadId;
    if (did != null) {
      _recordForDownload(did, entry);
    }

    if (_entries.length >= maxEntries) {
      _entries.removeFirst();
    }
    _entries.add(entry);
    _controller.add(entry);
  }

  void _recordForDownload(String downloadId, LogEntry entry) {
    if (!_perDownloadEntries.containsKey(downloadId)) {
      if (_downloadLru.length >= maxRetainedDownloads) {
        final oldest = _downloadLru.first;
        _downloadLru.remove(oldest);
        _perDownloadEntries.remove(oldest);
      }
      _perDownloadEntries[downloadId] = ListQueue<LogEntry>();
      _downloadLru.add(downloadId);
    } else {
      // LRU touch in O(1): re-insertion moves the id to the newest end.
      _downloadLru.remove(downloadId);
      _downloadLru.add(downloadId);
    }

    final list = _perDownloadEntries[downloadId]!;
    if (list.length >= maxEntriesPerDownload) {
      list.removeFirst();
    }
    list.add(entry);
  }

  void setMinLevel(LogLevel level) {
    _minLevel = level;
  }

  void setTagFilter(String? tag) {
    _tagFilter = tag;
  }

  void setSearchFilter(String? query) {
    _searchFilter = query;
  }

  void setSourceFilter(String? source) {
    _sourceFilter = source;
  }

  void clear() {
    _entries.clear();
    _perDownloadEntries.clear();
    _downloadLru.clear();
  }

  void clearDownload(String downloadId) {
    _perDownloadEntries.remove(downloadId);
    _downloadLru.remove(downloadId);
  }

  List<LogEntry> getEntriesForDownload(
    String downloadId, {
    LogLevel? minLevel,
    int? limit,
  }) {
    final list = _perDownloadEntries[downloadId];
    if (list == null || list.isEmpty) {
      return const [];
    }
    var result = list.where((e) {
      if (minLevel != null && e.level.index < minLevel.index) return false;
      return true;
    }).toList();
    if (limit != null && result.length > limit) {
      result = result.sublist(result.length - limit);
    }
    return result;
  }

  Stream<LogEntry> streamForDownload(String downloadId) {
    return _controller.stream.where(
        (e) => e.downloadId == downloadId || e.traceId == downloadId);
  }

  List<LogEntry> filtered({
    LogLevel? minLevel,
    String? tag,
    String? search,
    String? source,
    String? downloadId,
    int? limit,
  }) {
    final Iterable<LogEntry> sourceList;
    if (downloadId != null) {
      sourceList = _perDownloadEntries[downloadId] ??
          _entries
              .where((e) =>
                  e.downloadId == downloadId || e.traceId == downloadId)
              .toList();
    } else {
      sourceList = _entries;
    }

    var result = sourceList.where((e) {
      if (minLevel != null && e.level.index < minLevel.index) return false;
      if (tag != null && !e.logger.contains(tag)) return false;
      if (search != null && !e.matches(search.toLowerCase())) {
        return false;
      }
      if (source != null && e.source != source) return false;
      return true;
    }).toList();
    if (limit != null && result.length > limit) {
      result = result.sublist(result.length - limit);
    }
    return result;
  }

  /// Convenience filter for retrieving all log entries tied to [downloadId].
  List<LogEntry> forDownload(
    String downloadId, {
    LogLevel? minLevel,
    String? search,
    int? limit,
  }) {
    return filtered(
      downloadId: downloadId,
      minLevel: minLevel,
      search: search,
      limit: limit,
    );
  }

  void dispose() {
    _controller.close();
  }
}
