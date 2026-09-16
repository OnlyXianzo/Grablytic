import 'dart:async';
import 'dart:collection';
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

  LogBuffer({
    this.maxEntries = 5000,
    this.maxEntriesPerDownload = 500,
    this.maxRetainedDownloads = 50,
  });

  Stream<LogEntry> get stream => _controller.stream;
  List<LogEntry> get entries => List.unmodifiable(_entries);

  void add(LogEntry entry) {
    final did = entry.downloadId;
    if (did != null) {
      _recordForDownload(did, entry);
    }

    if (entry.level.index < _minLevel.index) return;
    if (_tagFilter != null && !entry.logger.contains(_tagFilter!)) return;
    if (_searchFilter != null &&
        !entry.message.toLowerCase().contains(_searchFilter!.toLowerCase())) {
      return;
    }
    if (_sourceFilter != null && entry.source != _sourceFilter) return;

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
      if (search != null &&
          !e.message.toLowerCase().contains(search.toLowerCase())) {
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
