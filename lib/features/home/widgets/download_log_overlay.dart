import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/text_styles.dart';
import '../../../core/utils/log_entry.dart';
import '../../../providers/log_provider.dart';
import 'download_log_sheet.dart';

/// Live engine-log strip for one download (ytdlnis-style).
///
/// Seal/ytdlnis parity: the download card itself shows friendly status
/// (stage + progress + speed — rendered by the parent), never raw terminal
/// text. Raw logs live behind this details affordance: collapsed shows a
/// compact "View logs (N)" button; tap expands to the last 60 lines with
/// autoscroll + a jump to the full [DownloadLogSheet] (search/filter/copy).
/// Empty renders nothing.
class DownloadLogOverlay extends ConsumerStatefulWidget {
  final String downloadId;
  final bool visible;

  const DownloadLogOverlay({
    super.key,
    required this.downloadId,
    required this.visible,
  });

  @override
  ConsumerState<DownloadLogOverlay> createState() =>
      _DownloadLogOverlayState();
}

class _DownloadLogOverlayState extends ConsumerState<DownloadLogOverlay> {
  StreamSubscription<LogEntry>? _sub;
  bool _expanded = false;
  final ScrollController _scroll = ScrollController();
  // Loop-3 batching: engine log events arrive at tens of Hz; the collapsed
  // view shows the last 8 lines, so refreshing at ~2 Hz loses nothing and
  // avoids a setState storm multiplied by every mounted card.
  Timer? _batch;

  static const int _collapsedLines = 8;
  static const int _expandedLines = 60;

  @override
  void initState() {
    super.initState();
    // Scoped subscription: only this download's entries wake this card
    // (previously the GLOBAL stream rebuilt every card on every app-wide
    // log line — the top UI amplifier in the 10+ hang).
    _sub = ref
        .read(logBufferProvider)
        .streamForDownload(widget.downloadId)
        .listen((_) {
      if (!mounted || !widget.visible) return;
      _batch ??= Timer(const Duration(milliseconds: 500), () {
        _batch = null;
        if (!mounted) return;
        setState(() {});
        if (_expanded) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scroll.hasClients) {
              _scroll.jumpTo(_scroll.position.maxScrollExtent);
            }
          });
        }
      });
    });
  }

  @override
  void dispose() {
    _batch?.cancel();
    _sub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  List<LogEntry> _linesForDownload(List<LogEntry> scoped) {
    // Scoped to this download via the per-download store (survives global
    // buffer eviction). `downloadId` covers top-level/context/extra forms.
    final mine = scoped.where((e) =>
        e.source == 'engine' &&
        (e.downloadId == widget.downloadId ||
            e.traceId == widget.downloadId));
    final list = mine.toList();
    final cap = _expanded ? _expandedLines : _collapsedLines;
    if (list.length <= cap) return list;
    return list.sublist(list.length - cap);
  }

  String _clock(LogEntry e) {
    final t = e.timestamp.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible) return const SizedBox.shrink();
    final allForDownload =
        ref.watch(logBufferProvider).forDownload(widget.downloadId);
    if (allForDownload.isEmpty) return const SizedBox.shrink();
    final totalCount = allForDownload.length;
    final lines = _linesForDownload(allForDownload);
    final textTheme = Theme.of(context).textTheme;
    final brightness = Theme.of(context).brightness;
    final infoColor = GrablyticLogColors.info(brightness);
    final warnColor = GrablyticLogColors.warning(brightness);

    Widget line(LogEntry e) {
      final Color color;
      switch (e.level) {
        case LogLevel.error:
        case LogLevel.fatal:
          color = Theme.of(context).colorScheme.error;
          break;
        case LogLevel.warn:
          color = warnColor;
          break;
        case LogLevel.info:
          color = infoColor;
          break;
        case LogLevel.debug:
          color = Theme.of(context).colorScheme.outline;
          break;
      }
      return Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Text.rich(
          TextSpan(
            style: textTheme.mono.copyWith(
              fontSize: 12,
              height: 1.55,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            children: [
              TextSpan(
                text: '${_clock(e)} ',
                style: TextStyle(
                  color:
                      Theme.of(context).colorScheme.outline,
                ),
              ),
              TextSpan(
                text: e.message,
                style: TextStyle(color: color),
              ),
            ],
          ),
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
        ),
      );
    }

    return Semantics(
      button: true,
      label: _expanded
          ? 'Collapse live download logs'
          : 'Expand live download logs',
      child: GestureDetector(
        onTap: () => setState(() => _expanded = !_expanded),
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: Theme.of(context)
                    .colorScheme
                    .outlineVariant
                    .withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.terminal,
                      size: 18,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                  const SizedBox(width: 10),
                  Text(
                    _expanded ? 'LIVE LOG' : 'View logs ($totalCount)',
                    style: textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const Spacer(),
                  if (_expanded)
                    GestureDetector(
                      onTap: () {
                        DownloadLogSheet.show(
                          context,
                          downloadId: widget.downloadId,
                          title: 'Download Log',
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Icon(
                          Icons.open_in_new,
                          size: 16,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
              // Collapsed: friendly affordance only (no raw terminal text —
              // Seal shows status + bar on the card, ytdlnis keeps logs in
              // the details sheet). Expanded: last 60 lines + full sheet.
              if (_expanded) ...[
                const SizedBox(height: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 180),
                  child: ListView(
                    controller: _scroll,
                    shrinkWrap: true,
                    children: lines.map(line).toList(),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
