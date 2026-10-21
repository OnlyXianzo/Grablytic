import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/engine/engine_provider.dart';
import '../../../core/utils/app_logger.dart';
import '../../../core/utils/crash_reporter.dart';
import '../../../core/utils/pending_report.dart';
import '../../../core/theme/text_styles.dart';
import '../../../core/utils/notification_helper.dart';

/// "Report a problem" — the one place a non-technical user can say what
/// went wrong and send it.
///
/// Deliberately short: a sentence, one of five categories, and a single
/// button. Everything technical (version, platform, log excerpt, stack
/// trace) is gathered automatically and shown behind "What will be
/// included", not asked for.
///
/// The screen never claims a report was submitted unless GitHub confirmed
/// it. On a stock build there is no token, so the real path is a prefilled
/// GitHub page opened in the browser — the user presses Submit there, and
/// the copy says exactly that.
class ReportProblemScreen extends ConsumerStatefulWidget {
  const ReportProblemScreen({
    super.key,
    this.initialCategory = ReportCategory.other,
    this.reviewReportId,
    this.attachLogs = true,
    this.autoSend = false,
  });

  /// Pre-selects a category (the recovery prompt passes `crash`).
  final ReportCategory initialCategory;

  /// When set, the screen opens on an existing queued report — the crash
  /// the recovery prompt is offering to send — instead of a blank form.
  final String? reviewReportId;

  /// Whether the diagnostic excerpt is attached. Off only when the caller
  /// already has the report text.
  final bool attachLogs;

  /// Sends as soon as a queued report is loaded.
  ///
  /// Set by the recovery banner's "Send report" action — the user already
  /// chose to send, so asking them to press a second button would be the
  /// kind of confirmation that teaches people to tap through dialogs.
  final bool autoSend;

  @override
  ConsumerState<ReportProblemScreen> createState() =>
      _ReportProblemScreenState();
}

enum _Phase { editing, preparing, sending, handedOff, submitted, failed }

class _ReportProblemScreenState extends ConsumerState<ReportProblemScreen> {
  final _controller = TextEditingController();
  late ReportCategory _category = widget.initialCategory;
  _Phase _phase = _Phase.editing;
  PendingReport? _report;
  ReportOutcome? _outcome;
  String? _localError;
  bool _showDetails = false;

  @override
  void initState() {
    super.initState();
    if (widget.reviewReportId != null) {
      _loadExisting(widget.reviewReportId!);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadExisting(String id) async {
    final reporter = CrashReporter.instance;
    if (reporter == null) return;
    PendingReport? found;
    for (final report in await reporter.pending()) {
      if (report.id == id) {
        found = report;
        break;
      }
    }
    // Values are read out here: a local that is assigned after its
    // declaration is not promotable inside the closure below.
    final report = found;
    if (!mounted || report == null) return;
    final category = report.category;
    final summary = report.summary;
    setState(() {
      _report = report;
      _category = category;
      _controller.text = summary;
    });
    if (widget.autoSend) await _send();
  }

  bool get _canSend =>
      _phase != _Phase.preparing &&
      _phase != _Phase.sending &&
      (_report != null || _controller.text.trim().length >= 4);

  Future<void> _send() async {
    final reporter = CrashReporter.instance;
    if (reporter == null) {
      setState(() => _localError = 'Reporting is not available in this build.');
      return;
    }
    setState(() {
      _phase = _Phase.preparing;
      _localError = null;
    });

    PendingReport? report = _report;
    report ??= await reporter.buildManual(
      summary: _controller.text,
      category: _category,
      includeLog: widget.attachLogs,
    );
    if (!mounted) return;
    if (report == null) {
      setState(() {
        _phase = _Phase.editing;
        _localError = 'Could not prepare the report. Your text is still here.';
      });
      return;
    }

    setState(() {
      _report = report;
      _phase = _Phase.sending;
    });
    final outcome = await reporter.submit(report);
    if (!mounted) return;
    setState(() {
      _outcome = outcome;
      switch (outcome.status) {
        case ReportSubmission.created:
        case ReportSubmission.duplicate:
          _phase = _Phase.submitted;
          break;
        case ReportSubmission.needsBrowser:
          _phase = _Phase.handedOff;
          break;
        case ReportSubmission.failed:
          _phase = _Phase.failed;
          break;
      }
    });
    final url = outcome.url;
    if (url != null && _phase == _Phase.handedOff) {
      // Handed to the browser AFTER the state is set: a slow or missing
      // browser then leaves the user on a screen that still explains the
      // report and offers the copy button, instead of a spinner.
      try {
        await ref.read(engineProvider).openUrl(url);
      } catch (e) {
        AppLogger.warn('Could not open the GitHub page: $e',
            tag: 'report-problem');
      }
    }
  }

  Future<void> _copyReport() async {
    final report = _report;
    final reporter = CrashReporter.instance;
    if (report == null || reporter == null) return;
    await Clipboard.setData(ClipboardData(text: reporter.preview(report)));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      styledSnackBar(context, 'Report copied to clipboard.'),
    );
  }

  Future<void> _discard() async {
    final report = _report;
    if (report != null) await CrashReporter.instance?.dismiss(report.id);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Report a problem')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
          children: [
            if (_phase == _Phase.submitted)
              _ResultCard(
                icon: Icons.check_circle_outline,
                tone: cs.primary,
                title: 'Report sent',
                body: _outcome?.status == ReportSubmission.duplicate
                    ? 'This has already been reported. The existing issue is open.'
                    : 'Thank you — the issue is filed and a maintainer will see it.',
                url: _outcome?.url,
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Done'),
                  ),
                ],
              )
            else if (_phase == _Phase.handedOff)
              _ResultCard(
                icon: Icons.open_in_browser,
                tone: cs.primary,
                title: 'Finish on GitHub',
                body:
                    'A prefilled issue is open in your browser. Press Submit there '
                    'to file it — the app cannot see whether you did, so this '
                    'report stays in your list until you remove it.',
                url: _outcome?.url,
                actions: [
                  TextButton(
                    onPressed: _copyReport,
                    child: const Text('Copy report'),
                  ),
                  TextButton(
                    onPressed: _discard,
                    child: const Text('Remove'),
                  ),
                ],
              )
            else if (_phase == _Phase.failed)
              _ResultCard(
                icon: Icons.cloud_off_outlined,
                tone: cs.error,
                title: 'Not sent',
                body:
                    'The report could not be filed right now. It is saved, so '
                    'nothing you wrote is lost — try again when you are online.',
                actions: [
                  TextButton(
                    onPressed: _copyReport,
                    child: const Text('Copy report'),
                  ),
                  FilledButton(
                    onPressed: _canSend ? _send : null,
                    child: const Text('Try again'),
                  ),
                ],
              )
            else ...[
              Text(
                'What went wrong?',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontFamily: 'BricolageGrotesque',
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Plain words are fine. The technical details are attached for you.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _controller,
                minLines: 3,
                maxLines: 6,
                maxLength: 1200,
                textCapitalization: TextCapitalization.sentences,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText: 'The download stopped at 40% and never resumed.',
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Category',
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final category in ReportCategory.values)
                    ChoiceChip(
                      label: Text(category.label),
                      selected: _category == category,
                      onSelected: (_) => setState(() => _category = category),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _category.hint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              _DiagnosticsCard(
                expanded: _showDetails,
                onToggle: () => setState(() => _showDetails = !_showDetails),
                report: _report,
                includeLog: widget.attachLogs,
              ),
              if (_localError != null) ...[
                const SizedBox(height: 12),
                Text(
                  _localError!,
                  style: theme.textTheme.bodySmall?.copyWith(color: cs.error),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _canSend ? _send : null,
                icon: _phase == _Phase.preparing || _phase == _Phase.sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_outlined, size: 18),
                label: Text(
                  _phase == _Phase.preparing
                      ? 'Preparing diagnostics…'
                      : _phase == _Phase.sending
                          ? 'Sending…'
                          : 'Send report',
                ),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Reports are public GitHub issues. Account names, tokens, '
                'cookies and auth headers are removed before anything leaves '
                'this device. Nothing is ever sent without you pressing Send.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// "What will be included" — the review step, and the only place technical
/// detail is shown.
class _DiagnosticsCard extends StatelessWidget {
  const _DiagnosticsCard({
    required this.expanded,
    required this.onToggle,
    required this.report,
    required this.includeLog,
  });

  final bool expanded;
  final VoidCallback onToggle;
  final PendingReport? report;
  final bool includeLog;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.25)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
              child: Row(
                children: [
                  Icon(Icons.description_outlined, size: 18, color: cs.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'What will be included',
                          style: theme.textTheme.titleSmall,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'App version, platform, and a short excerpt of the '
                          '${includeLog ? 'recent app log' : 'error'} — no '
                          'download history, no files, no cookies.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    color: cs.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Divider(height: 1),
                  const SizedBox(height: 12),
                  if (report == null)
                    Text(
                      'The full text appears here once the report is prepared '
                      '(the Send button gathers it). Nothing is sent until '
                      'then.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    )
                  else
                    Container(
                      width: double.infinity,
                      constraints: const BoxConstraints(maxHeight: 260),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: SingleChildScrollView(
                        child: SelectableText(
                          '${report!.title}\n\n${report!.body}',
                          style: theme.textTheme.mono.copyWith(
                            fontSize: 11,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.icon,
    required this.tone,
    required this.title,
    required this.body,
    required this.actions,
    this.url,
  });

  final IconData icon;
  final Color tone;
  final String title;
  final String body;
  final String? url;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: tone, size: 32),
          const SizedBox(height: 12),
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(body, style: theme.textTheme.bodyMedium),
          if (url != null) ...[
            const SizedBox(height: 10),
            SelectableText(
              url!,
              style: theme.textTheme.bodySmall?.copyWith(color: cs.primary),
            ),
          ],
          const SizedBox(height: 16),
          Wrap(spacing: 8, alignment: WrapAlignment.end, children: actions),
        ],
      ),
    );
  }
}
