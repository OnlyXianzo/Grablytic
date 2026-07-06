import 'dart:async';
import 'log_entry.dart';

class LogBuffer {
  final int maxEntries;
  final List<LogEntry> _entries = [];
  final StreamController<LogEntry> _controller =
      StreamController<LogEntry>.broadcast();
  LogLevel _minLevel = LogLevel.debug;
  String? _tagFilter;
  String? _searchFilter;
  String? _sourceFilter; // 'engine', 'ui', or null (all)

  LogBuffer({this.maxEntries = 5000});

  Stream<LogEntry> get stream => _controller.stream;
  List<LogEntry> get entries => List.unmodifiable(_entries);

  void add(LogEntry entry) {
    if (entry.level.index < _minLevel.index) return;
    if (_tagFilter != null && !entry.logger.contains(_tagFilter!)) return;
    if (_searchFilter != null &&
        !entry.message.toLowerCase().contains(_searchFilter!.toLowerCase())) {
      return;
    }
    if (_sourceFilter != null && entry.source != _sourceFilter) return;

    if (_entries.length >= maxEntries) {
      _entries.removeAt(0);
    }
    _entries.add(entry);
    _controller.add(entry);
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
  }

  List<LogEntry> filtered({
    LogLevel? minLevel,
    String? tag,
    String? search,
    String? source,
    int? limit,
  }) {
    var result = _entries.where((e) {
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

  void dispose() {
    _controller.close();
  }
}
