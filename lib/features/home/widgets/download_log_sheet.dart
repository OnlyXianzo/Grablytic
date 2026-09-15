import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/text_styles.dart';
import '../../../core/utils/app_logger.dart';
import '../../../core/utils/log_entry.dart';
import '../../../providers/log_provider.dart';

/// Modal bottom sheet displaying logs scoped to an individual download.
///
/// Supports live streaming during active downloads, search, level filtering,
/// clipboard copying, and disk file fallback if the in-memory buffer rotated.
class DownloadLogSheet extends ConsumerStatefulWidget {
  final String downloadId;
  final String title;
  final String? status;
  final String? url;

  const DownloadLogSheet({
    super.key,
    required this.downloadId,
    required this.title,
    this.status,
    this.url,
  });

  /// Presents the per-download log sheet in a modal bottom sheet.
  static Future<void> show(
    BuildContext context, {
    required String downloadId,
    required String title,
    String? status,
    String? url,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DownloadLogSheet(
        downloadId: downloadId,
        title: title,
        status: status,
        url: url,
      ),
    );
  }

  @override
  ConsumerState<DownloadLogSheet> createState() => _DownloadLogSheetState();
}

class _DownloadLogSheetState extends ConsumerState<DownloadLogSheet> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  StreamSubscription<LogEntry>? _streamSub;

  String _searchQuery = '';
  LogLevel? _selectedLevel;
  bool _autoScroll = true;
  bool _isLoadingDisk = false;
  List<LogEntry> _diskFallbackEntries = [];
  int? _expandedIndex;
  // Loop-3: batch live updates at ~2 Hz (was setState per log event) and
  // cap rendered rows — a 500-row RichText rebuild at tens of Hz janked.
  Timer? _batch;
  static const int _maxRenderedRows = 200;

  @override
  void initState() {
    super.initState();
    _subscribeToStream();
    _checkAndLoadDiskLogs();
  }

  void _subscribeToStream() {
    final buffer = ref.read(logBufferProvider);
    _streamSub = buffer.streamForDownload(widget.downloadId).listen((_) {
      if (!mounted) return;
      _batch ??= Timer(const Duration(milliseconds: 500), () {
        _batch = null;
        if (!mounted) return;
        setState(() {});
        if (_autoScroll) {
          _scrollToBottom();
        }
      });
    });
  }

  Future<void> _checkAndLoadDiskLogs() async {
    final buffer = ref.read(logBufferProvider);
    final inMemory = buffer.forDownload(widget.downloadId);
    if (inMemory.isNotEmpty) return;

    // Buffer has no entries (e.g. after app restart) — search disk log files.
    setState(() => _isLoadingDisk = true);
    try {
      final files = await AppLogger.getLogFiles();
      if (files.isEmpty) {
        if (mounted) setState(() => _isLoadingDisk = false);
        return;
      }
      final diskEntries = <LogEntry>[];
      for (final file in files.take(3)) {
        final content = await AppLogger.readLogFile(file);
        for (final line in content.split('\n')) {
          if (line.contains(widget.downloadId)) {
            diskEntries.add(_parseDiskLine(line));
          }
        }
      }
      if (mounted) {
        setState(() {
          _diskFallbackEntries = diskEntries;
          _isLoadingDisk = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoadingDisk = false);
    }
  }

  LogEntry _parseDiskLine(String line) {
    var level = LogLevel.info;
    if (line.contains('[DEBUG]')) level = LogLevel.debug;
    if (line.contains('[WARN]')) level = LogLevel.warn;
    if (line.contains('[ERROR]')) level = LogLevel.error;
    if (line.contains('[FATAL]')) level = LogLevel.fatal;

    return LogEntry(
      timestamp: DateTime.now(),
      level: level,
      logger: 'disk',
      message: line,
      downloadId: widget.downloadId,
      source: 'engine',
    );
  }

  void _scrollToBottom() {
    // Loop-3: jumpTo, not animateTo — a 200 ms animation per live event
    // piled overlapping animations at tens of Hz. Instant follow is calmer
    // and cheaper; the full log stays available via scrollback/copy.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(
          _scrollController.position.maxScrollExtent,
        );
      }
    });
  }

  @override
  void dispose() {
    _batch?.cancel();
    _streamSub?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  List<LogEntry> _getEntries() {
    final buffer = ref.watch(logBufferProvider);
    var entries = buffer.forDownload(widget.downloadId);
    if (entries.isEmpty && _diskFallbackEntries.isNotEmpty) {
      entries = _diskFallbackEntries;
    }

    return entries.where((e) {
      if (_selectedLevel != null && e.level != _selectedLevel) return false;
      if (_searchQuery.isNotEmpty &&
          !e.message.toLowerCase().contains(_searchQuery.toLowerCase())) {
        return false;
      }
      return true;
    }).toList();
  }

  void _copyAllLogs(List<LogEntry> entries) {
    if (entries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No logs to copy')),
      );
      return;
    }
    final fullText = entries.map((e) => e.formattedLine).join('\n');
    Clipboard.setData(ClipboardData(text: fullText));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied ${entries.length} log lines to clipboard')),
    );
  }

  Color _levelColor(LogLevel level, ColorScheme cs) {
    switch (level) {
      case LogLevel.debug:
        return Colors.grey.shade400;
      case LogLevel.info:
        return Colors.blue.shade300;
      case LogLevel.warn:
        return Colors.orange.shade300;
      case LogLevel.error:
        return Colors.red.shade400;
      case LogLevel.fatal:
        return Colors.purple.shade300;
    }
  }

  Color _statusColor(String? status, ColorScheme cs) {
    switch (status?.toLowerCase()) {
      case 'downloading':
        return cs.primary;
      case 'completed':
        return Colors.green.shade400;
      case 'error':
        return cs.error;
      case 'queued':
      case 'pending':
        return Colors.amber.shade400;
      default:
        return cs.outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final entries = _getEntries();
    final height = MediaQuery.of(context).size.height * 0.85;

    return Container(
      height: height,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 10, offset: Offset(0, -2)),
        ],
      ),
      child: Column(
        children: [
          // Drag handle
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: cs.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                const Icon(Icons.terminal, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        style: tt.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          if (widget.status != null) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: _statusColor(widget.status, cs).withAlpha(40),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: _statusColor(widget.status, cs).withAlpha(120),
                                  width: 0.8,
                                ),
                              ),
                              child: Text(
                                widget.status!.toUpperCase(),
                                style: tt.mono.copyWith(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: _statusColor(widget.status, cs),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          Flexible(
                            child: GestureDetector(
                              onTap: () {
                                Clipboard.setData(ClipboardData(text: widget.downloadId));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Download ID copied to clipboard'),
                                    duration: Duration(seconds: 2),
                                  ),
                                );
                              },
                              child: Text(
                                'ID: ${widget.downloadId.length > 12 ? '${widget.downloadId.substring(0, 12)}…' : widget.downloadId}',
                                style: tt.mono.copyWith(
                                  fontSize: 11,
                                  color: cs.onSurfaceVariant,
                                  decoration: TextDecoration.underline,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  tooltip: 'Copy all logs',
                  onPressed: () => _copyAllLogs(entries),
                ),
                IconButton(
                  icon: Icon(
                    _autoScroll ? Icons.vertical_align_bottom : Icons.pause,
                    size: 18,
                    color: _autoScroll ? cs.primary : cs.outline,
                  ),
                  tooltip: _autoScroll ? 'Autoscroll enabled' : 'Autoscroll paused',
                  onPressed: () => setState(() => _autoScroll = !_autoScroll),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // Filter row: search + level chips
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: 'Filter log messages…',
                      prefixIcon: const Icon(Icons.search, size: 18),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 16),
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _searchQuery = '');
                              },
                            )
                          : null,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    onChanged: (v) => setState(() => _searchQuery = v),
                  ),
                ),
                const SizedBox(width: 8),
                PopupMenuButton<LogLevel?>(
                  tooltip: 'Filter by level',
                  icon: Icon(
                    Icons.filter_list,
                    size: 20,
                    color: _selectedLevel != null ? cs.primary : cs.outline,
                  ),
                  onSelected: (lvl) => setState(() => _selectedLevel = lvl),
                  itemBuilder: (ctx) => [
                    const PopupMenuItem(value: null, child: Text('ALL LEVELS')),
                    for (final lvl in LogLevel.values)
                      PopupMenuItem(
                        value: lvl,
                        child: Text(
                          lvl.name.toUpperCase(),
                          style: TextStyle(
                            color: _levelColor(lvl, cs),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),

          // Log list / content area
          Expanded(
            child: _isLoadingDisk
                ? const Center(child: CircularProgressIndicator())
                : entries.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.terminal, size: 48, color: cs.outline.withAlpha(120)),
                            const SizedBox(height: 12),
                            Text(
                              'No logs recorded for this download yet',
                              style: tt.bodyMedium?.copyWith(color: cs.outline),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Logs appear here as the engine processes the download.',
                              style: tt.labelSmall?.copyWith(color: cs.outline),
                            ),
                          ],
                        ),
                      )
                    : Container(
                        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.black.withAlpha(220),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: cs.outlineVariant.withAlpha(60)),
                        ),
                        child: Column(
                          children: [
                            if (entries.length > _maxRenderedRows)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Text(
                                  'Showing last $_maxRenderedRows of ${entries.length} lines — copy all for the full log',
                                  style: tt.mono.copyWith(
                                    fontSize: 10,
                                    color: Colors.grey.shade500,
                                  ),
                                ),
                              ),
                            Expanded(
                              child: ListView.builder(
                                controller: _scrollController,
                                // Loop-3 clamp: render the tail only. The full
                                // list stays in the buffer for copy/search.
                                itemCount: entries.length > _maxRenderedRows
                                    ? _maxRenderedRows
                                    : entries.length,
                                itemBuilder: (context, index) {
                                  final entry = entries[
                                      entries.length -
                                          (entries.length > _maxRenderedRows
                                              ? _maxRenderedRows
                                              : entries.length) +
                                          index];
                            final isExpanded = _expandedIndex == index;
                            final col = _levelColor(entry.level, cs);

                            final t = entry.timestamp.toLocal();
                            String two(int n) => n.toString().padLeft(2, '0');
                            final timeStr =
                                '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';

                            return InkWell(
                              onTap: () {
                                setState(() {
                                  _expandedIndex = isExpanded ? null : index;
                                });
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 2.5),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    RichText(
                                      text: TextSpan(
                                        style: tt.mono.copyWith(
                                          fontSize: 11.5,
                                          height: 1.35,
                                          color: Colors.white70,
                                        ),
                                        children: [
                                          TextSpan(
                                            text: '[$timeStr] ',
                                            style: TextStyle(color: Colors.grey.shade500),
                                          ),
                                          TextSpan(
                                            text: '[${entry.level.name.toUpperCase()}] ',
                                            style: TextStyle(
                                              color: col,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          TextSpan(
                                            text: '[${entry.logger}] ',
                                            style: TextStyle(color: Colors.blueGrey.shade300),
                                          ),
                                          TextSpan(
                                            text: entry.message,
                                            style: TextStyle(
                                              color: entry.level == LogLevel.error ||
                                                      entry.level == LogLevel.fatal
                                                  ? Colors.red.shade200
                                                  : Colors.white,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (entry.exception != null &&
                                        (isExpanded || entry.level == LogLevel.error)) ...[
                                      const SizedBox(height: 2),
                                      Padding(
                                        padding: const EdgeInsets.only(left: 12),
                                        child: Text(
                                          '⚠ ${entry.exception}',
                                          style: tt.mono.copyWith(
                                            fontSize: 10.5,
                                            color: Colors.red.shade300,
                                            height: 1.3,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                              ),
                            ],
                          ),
                        ),
          ),
        ],
      ),
    );
  }
}
