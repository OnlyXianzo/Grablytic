import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import '../../../core/utils/app_version.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/engine/engine_provider.dart';
import '../../../core/utils/app_logger.dart';
import '../../../core/utils/crash_reports.dart';
import '../../../core/utils/github_reporter.dart';
import '../../../core/utils/pending_report.dart';
import '../../../providers/settings_provider.dart';

/// Short, user-reviewed report composer. GitHub itself performs the final
/// authenticated submission; Grablytic never embeds or asks for a token.
class ReportProblemScreen extends ConsumerStatefulWidget {
  const ReportProblemScreen({
    super.key,
    this.initialTitle,
    this.initialBody,
    this.queuedReportId,
    this.submitImmediately = false,
  });

  final String? initialTitle;
  final String? initialBody;

  /// The queued crash this screen represents.
  ///
  /// Passed explicitly by the recovery banner, which shows a report from
  /// the queue: without it the screen cannot dismiss that entry after the
  /// GitHub draft opens, and the banner offers the same crash again three
  /// days later.
  final String? queuedReportId;

  final bool submitImmediately;

  @override
  ConsumerState<ReportProblemScreen> createState() => _ReportProblemScreenState();
}

class _ReportProblemScreenState extends ConsumerState<ReportProblemScreen> {
  static const _draftKey = 'pending_bug_report';
  static const List<String> _categories = ReportCategory.all;
  final _description = TextEditingController();
  String _category = _categories.first;
  String _diagnostics = 'Preparing diagnostics…';
  bool _includeDiagnostics = true;
  bool _preparing = true;
  bool _opening = false;
  String? _stateMessage;
  String? _savedTitle;
  String? _savedBody;

  /// The queued crash this screen was opened for, if any. Kept so "Clear
  /// saved draft" can take it out of the crash queue as well — before, the
  /// same text lived in two places and only one of them was cleared.
  String? _queuedReportId;

  @override
  void initState() {
    super.initState();
    _description.text = widget.initialTitle ?? '';
    _savedBody = widget.initialBody;
    _queuedReportId = widget.queuedReportId;
    _prepare();
  }

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  Future<void> _prepare() async {
    String? crashBody = widget.initialBody;
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      final raw = prefs.getString(_draftKey);
      if (raw != null && widget.initialBody == null) {
        final saved = jsonDecode(raw);
        if (saved is Map) {
          _description.text = saved['description']?.toString() ?? _description.text;
          _category = _categories.contains(saved['category'])
              ? saved['category'].toString()
              : _category;
          _savedTitle = saved['title']?.toString();
          _savedBody = saved['body']?.toString();
          _stateMessage = 'Your last report draft is ready to retry.';
        }
      } else if (crashBody == null) {
        // A crash captured last session lives in the report queue, not in
        // the preferences blob: the queue is what survives a process that
        // died, and it is written even when automatic reporting is off.
        final queued =
            await CrashReports.instance?.pending() ?? const <PendingReport>[];
        for (final report in queued) {
          if (!report.isCrash) continue;
          _queuedReportId = report.id;
          crashBody = report.body;
          _savedBody = report.body;
          _description.text = 'The app encountered a problem and restarted.';
          _category = ReportCategory.crash;
          _stateMessage = 'A saved crash report is ready to review.';
          break;
        }
      }
      await AppLogger.flushNow();
      final tail = await AppLogger.readLogTail();
      final safeTail = GithubReporter.sanitizeForReport(tail, maxLength: 2500);
      final version = AppVersion.value;
      final platform = '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
      final timestamp = DateTime.now().toUtc().toIso8601String();
      _diagnostics = crashBody != null
          ? 'Previous crash report (sanitized):\n${GithubReporter.sanitizeForReport(crashBody, maxLength: 3000)}'
          : 'Grablytic: $version\nBuild: ${GithubReporter.buildIdentifier}\nPlatform: ${GithubReporter.sanitizeForReport(platform, maxLength: 200)}\nTime (UTC): $timestamp\n\nRecent app logs (sanitized):\n${safeTail.isEmpty ? '(No recent logs available)' : safeTail}';
    } on Exception catch (e) {
      // Fail closed: do not include diagnostics that could not be sanitized.
      _diagnostics = 'Diagnostics could not be safely prepared and will not be included.';
      AppLogger.warn('Diagnostics not prepared: $e', tag: 'reporting');
    }
    if (mounted) {
      setState(() => _preparing = false);
      if (widget.submitImmediately) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _submit());
      }
    }
  }

  String _composeBody() {
    final description = GithubReporter.sanitizeForReport(_description.text.trim(), maxLength: 3000);
    final safeTitle = GithubReporter.sanitizeForReport(_description.text.trim(), maxLength: 90);
    final reportTitle =
        '[$_category] ${safeTitle.isEmpty ? 'Problem report' : safeTitle}';
    final body = '''### What happened?
${description.isEmpty ? '(No description provided)' : description}

### Category
$_category

### Diagnostics (reviewed in Grablytic)
${_includeDiagnostics ? _diagnostics : 'Not included by the user.'}

---
Submitted from Grablytic. Please review this report before creating the issue.''';
    _savedTitle = reportTitle;
    _savedBody = body;
    return body;
  }

  Future<void> _submit() async {
    if (_preparing || _opening) return;
    if (_description.text.trim().isEmpty) {
      setState(() => _stateMessage = 'Please briefly describe what went wrong.');
      return;
    }
    setState(() {
      _opening = true;
      _stateMessage = 'Preparing a private, reviewable GitHub draft…';
    });
    final body = _composeBody();
    final title = _savedTitle!;
    try {
      await ref.read(sharedPreferencesProvider).setString(
        _draftKey,
        jsonEncode({
          'description': GithubReporter.sanitizeForReport(_description.text.trim(), maxLength: 3000),
          'category': _category,
          'title': title,
          'body': body,
        }),
      );
      final uri = Uri.https('github.com', '/OnlyXianzo/Grablytic/issues/new', {
        'title': title,
        'body': body,
        'labels': 'bug',
      });
      final result = await ref.read(engineProvider).openUrl(uri.toString());
      final opened = result['success'] == true;
      if (opened) {
        // The user has the draft in their browser, and the same text is
        // saved under `_draftKey`, so the queue entry has done its job.
        // Leaving it queued would re-offer the crash every three days.
        final queued = _queuedReportId;
        if (queued != null) {
          await CrashReports.instance?.dismiss(queued);
          _queuedReportId = null;
        }
      }
      if (!mounted) return;
      setState(() {
        _stateMessage = opened
            ? 'GitHub opened with your draft. Review it there and tap “Submit new issue” to send it. Your draft is saved here if you need to retry.'
            : 'Could not open GitHub. Your sanitized draft is saved; try again when online or open github.com/OnlyXianzo/Grablytic/issues/new.';
      });
    } on Exception catch (e) {
      if (mounted) {
        setState(() => _stateMessage = 'Could not open GitHub. Your sanitized draft is saved so you can retry later.');
      }
      AppLogger.warn('Could not open the GitHub form: $e', tag: 'reporting');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _clearDraft() async {
    await ref.read(sharedPreferencesProvider).remove(_draftKey);
    final queued = _queuedReportId;
    if (queued != null) {
      await CrashReports.instance?.dismiss(queued);
      _queuedReportId = null;
    }
    if (!mounted) return;
    setState(() {
      _savedTitle = null;
      _savedBody = null;
      _stateMessage = 'Saved draft cleared.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Report a problem')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        children: [
          Text('Tell us what went wrong', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text('A short description is enough. Nothing is sent until you review and submit it on GitHub.', style: TextStyle(color: colors.onSurfaceVariant)),
          const SizedBox(height: 20),
          DropdownButtonFormField<String>(
            initialValue: _category,
            decoration: const InputDecoration(labelText: 'Category', border: OutlineInputBorder()),
            items: _categories.map((value) => DropdownMenuItem(value: value, child: Text(value))).toList(),
            onChanged: (value) { if (value != null) setState(() => _category = value); },
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _description,
            minLines: 3,
            maxLines: 6,
            maxLength: 3000,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'What happened?',
              hintText: 'For example: the download stopped after I tapped Start.',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Include sanitized diagnostics'),
            subtitle: const Text('App version, platform, time, and a short log excerpt. Review below.'),
            value: _includeDiagnostics,
            onChanged: _preparing ? null : (value) => setState(() => _includeDiagnostics = value),
          ),
          Card(
            child: ExpansionTile(
              initiallyExpanded: false,
              leading: const Icon(Icons.privacy_tip_outlined),
              title: Text(_preparing ? 'Preparing diagnostics…' : 'Review included information'),
              subtitle: const Text('URLs and local paths are removed; secrets are masked.'),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [SelectableText(_preparing ? 'Preparing…' : _diagnostics, style: Theme.of(context).textTheme.bodySmall)],
            ),
          ),
          if (_stateMessage != null) ...[
            const SizedBox(height: 12),
            Semantics(liveRegion: true, child: Text(_stateMessage!, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colors.primary))),
          ],
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _preparing || _opening ? null : _submit,
            icon: _opening ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.open_in_new),
            label: Text(_opening ? 'Preparing report…' : 'Review and open GitHub'),
          ),
          if (_savedBody != null) ...[
            const SizedBox(height: 8),
            TextButton.icon(onPressed: _clearDraft, icon: const Icon(Icons.delete_outline), label: const Text('Clear saved draft')),
          ],
        ],
      ),
    );
  }
}
