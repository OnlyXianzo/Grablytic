import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/utils/log_entry.dart';
import '../../../providers/log_provider.dart';

class LiveLogView extends ConsumerStatefulWidget {
  const LiveLogView({super.key});

  @override
  ConsumerState<LiveLogView> createState() => _LiveLogViewState();
}

class _LiveLogViewState extends ConsumerState<LiveLogView> {
  String _searchQuery = '';
  LogLevel? _levelFilter;
  String? _sourceFilter;
  bool _autoScroll = true;
  int? _expandedIndex;
  final ScrollController _scrollController = ScrollController();
  StreamSubscription<LogEntry>? _bufferSub;

  @override
  void initState() {
    super.initState();
    _bufferSub = ref.read(logBufferProvider).stream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _bufferSub?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  Color _levelColor(LogLevel level) {
    switch (level) {
      case LogLevel.debug:
        return Colors.grey;
      case LogLevel.info:
        return Colors.blue;
      case LogLevel.warn:
        return Colors.orange;
      case LogLevel.error:
        return Colors.red;
      case LogLevel.fatal:
        return Colors.purple;
    }
  }

  String _levelLabel(LogLevel level) => level.name.toUpperCase();

  void _exportLiveLogs() {
    final buffer = ref.read(logBufferProvider);
    final entries = _filtered(buffer.entries);
    final text = entries.map((e) => e.formattedLine).join('\n');
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Exported ${entries.length} log entries to clipboard.')),
    );
  }

  List<LogEntry> _filtered(List<LogEntry> entries) {
    return entries.where((e) {
      if (_levelFilter != null && e.level != _levelFilter) return false;
      if (_sourceFilter != null && e.source != _sourceFilter) return false;
      if (_searchQuery.isNotEmpty &&
          !e.message.toLowerCase().contains(_searchQuery.toLowerCase())) {
        return false;
      }
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final buffer = ref.read(logBufferProvider);
    final entries = _filtered(buffer.entries);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            decoration: InputDecoration(
              hintText: 'Search log messages...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        setState(() {
                          _searchQuery = '';
                          buffer.setSearchFilter(null);
                        });
                      },
                    )
                  : null,
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            onChanged: (v) {
              setState(() => _searchQuery = v);
              buffer.setSearchFilter(v.isEmpty ? null : v);
            },
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 36,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final level in LogLevel.values)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: FilterChip(
                    label: Text(
                      _levelLabel(level),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: _levelFilter == level ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    selected: _levelFilter == level,
                    selectedColor: _levelColor(level).withAlpha(50),
                    checkmarkColor: _levelColor(level),
                    onSelected: (sel) => setState(() => _levelFilter = sel ? level : null),
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              _buildFilterToggle('All', null, cs),
              const SizedBox(width: 8),
              _buildFilterToggle('Engine', 'engine', cs),
              const SizedBox(width: 8),
              _buildFilterToggle('UI', 'ui', cs),
              const Spacer(),
              Icon(Icons.vertical_align_bottom, size: 16, color: cs.onSurfaceVariant),
              const SizedBox(width: 4),
              Switch(
                value: _autoScroll,
                onChanged: (v) => setState(() => _autoScroll = v),
              ),
              Text('Auto-scroll', style: tt.bodySmall),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: entries.isEmpty
              ? Center(
                  child: Text(
                    _searchQuery.isNotEmpty || _levelFilter != null || _sourceFilter != null
                        ? 'No matching log entries.'
                        : 'No live logs yet.\nRun the app to see log entries here.',
                    textAlign: TextAlign.center,
                    style: tt.bodyMedium?.copyWith(color: cs.outline),
                  ),
                )
              : ListView.builder(
                  controller: _scrollController,
                  itemCount: entries.length,
                  itemBuilder: (ctx, i) {
                    final entry = entries[i];
                    return _buildLogItem(entry, _expandedIndex == i, i, cs, tt);
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: entries.isEmpty ? null : _exportLiveLogs,
              icon: const Icon(Icons.copy),
              label: Text('Export ${entries.length} entries'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFilterToggle(String label, String? value, ColorScheme cs) {
    final active = _sourceFilter == value;
    return GestureDetector(
      onTap: () => setState(() => _sourceFilter = active ? null : value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? cs.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: active ? cs.primary : cs.outlineVariant),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: active ? FontWeight.bold : FontWeight.normal,
            color: active ? cs.onPrimaryContainer : cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _buildLogItem(LogEntry entry, bool expanded, int index, ColorScheme cs, TextTheme tt) {
    final lc = _levelColor(entry.level);
    return GestureDetector(
      onTap: () => setState(() => _expandedIndex = expanded ? null : index),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        decoration: BoxDecoration(
          color: cs.surfaceContainerLow.withAlpha(60),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: cs.outlineVariant.withAlpha(80)),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 4,
                decoration: BoxDecoration(
                  color: lc,
                  borderRadius: const BorderRadius.horizontal(left: Radius.circular(8)),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            entry.formattedTimestamp,
                            style: TextStyle(fontSize: 11, color: cs.outline, fontFamily: 'monospace'),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: lc.withAlpha(40),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              _levelLabel(entry.level),
                              style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: lc),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: cs.tertiaryContainer.withAlpha(60),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              entry.logger,
                              style: TextStyle(fontSize: 10, color: cs.onTertiaryContainer),
                            ),
                          ),
                          const Spacer(),
                          Text(entry.source, style: TextStyle(fontSize: 10, color: cs.outline)),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(entry.message, style: tt.bodySmall?.copyWith(fontSize: 13)),
                      if (expanded) ...[
                        const SizedBox(height: 6),
                        if (entry.exception != null)
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(6),
                            margin: const EdgeInsets.only(top: 4),
                            decoration: BoxDecoration(
                              color: Colors.red.withAlpha(15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '⚠ ${entry.exception!}',
                              style: TextStyle(fontSize: 11, color: lc, fontFamily: 'monospace'),
                            ),
                          ),
                        if (entry.context.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              'Context: ${entry.context}',
                              style: TextStyle(fontSize: 11, color: cs.outline, fontFamily: 'monospace'),
                            ),
                          ),
                        if (entry.extra.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              'Extra: ${entry.extra}',
                              style: TextStyle(fontSize: 11, color: cs.outline, fontFamily: 'monospace'),
                            ),
                          ),
                        if (entry.traceId != null || entry.durationMs != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              '${entry.traceId != null ? "trace: ${entry.traceId}" : ""}'
                              '${entry.traceId != null && entry.durationMs != null ? " | " : ""}'
                              '${entry.durationMs != null ? "${entry.durationMs}ms" : ""}',
                              style: TextStyle(fontSize: 10, color: cs.outline, fontFamily: 'monospace'),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
              if (expanded)
                Icon(Icons.expand_less, size: 18, color: cs.outline)
              else
                Icon(Icons.expand_more, size: 18, color: cs.outline),
            ],
          ),
        ),
      ),
    );
  }
}
