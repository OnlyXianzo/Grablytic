import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/utils/app_logger.dart';
import '../../../core/utils/github_reporter.dart';
import '../../../core/engine/engine_provider.dart';
import '../../../core/theme/text_styles.dart';
import '../../../providers/log_provider.dart';
import '../widgets/live_log_view.dart';

class LogViewerScreen extends ConsumerStatefulWidget {
  const LogViewerScreen({super.key});

  @override
  ConsumerState<LogViewerScreen> createState() => _LogViewerScreenState();
}

class _LogViewerScreenState extends ConsumerState<LogViewerScreen> {
  List<File> _logFiles = [];
  File? _selectedFile;
  String _logContent = 'Loading logs...';
  bool _isLoading = true;
  bool _loggingEnabled = AppLogger.isEnabled;
  int _retentionDays = AppLogger.retentionDays;
  int _selectedTab = 0;
  bool _includeFullLog = false;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _loadLogFiles();
  }

  Future<void> _loadLogFiles() async {
    setState(() => _isLoading = true);
    final files = await AppLogger.getLogFiles();
    setState(() {
      _logFiles = files;
      if (files.isNotEmpty) {
        _selectedFile = files.first;
      } else {
        _selectedFile = null;
        _logContent = 'No logs recorded yet.';
      }
      _isLoading = false;
    });
    if (_selectedFile != null) await _readLogContent(_selectedFile!);
  }

  Future<void> _readLogContent(File file) async {
    setState(() => _isLoading = true);
    final content = await AppLogger.readLogFile(file);
    setState(() {
      _logContent = content.isEmpty ? 'Log file is empty.' : content;
      _isLoading = false;
    });
  }

  void _copyToClipboard(String text, String msg) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _copyAiPrompt() {
    final truncated = _logContent.length > 15000
        ? '... [TRUNCATED FOR LENGTH] ...\n${_logContent.substring(_logContent.length - 15000)}'
        : _logContent;
    _copyToClipboard(
      'Please analyze the following error logs from the Grablytic Android/desktop media downloader app.\n'
      'Explain what the bug is, why it happened, and what went wrong. Provide a formatted GitHub Issue '
      'description following standard bug report templates so I can paste it into GitHub Issues for review.\n\n'
      'SYSTEM LOG DETAILS:\n$truncated',
      'System prompt and log content copied! Paste this into any AI (Gemini, Grok, ChatGPT, Claude) '
      'to generate your GitHub Issue.',
    );
  }

  void _openGithubIssues() {
    Clipboard.setData(
      const ClipboardData(text: 'https://github.com/OnlyXianzo/Grablytic/issues/new'),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('GitHub link copied! Open your browser and paste to create the issue.'),
      ),
    );
  }

  bool _reporting = false;

  /// Manual GitHub report flow (STEP 3C): flushes logs, dedups, posts.
  /// Falls back to copying the formatted body when no token is configured.
  Future<void> _reportToGithub() async {
    if (_reporting) return;
    setState(() => _reporting = true);
    try {
      final reporter = GithubReporter();
      final fileName =
          _selectedFile != null ? _selectedFile!.path.split('/').last : 'none';
      final result = await reporter.reportManual(
        userSummary: _selectedFile != null
            ? 'Log report from $fileName'
            : 'Manual log report from Diagnostics screen',
        userSteps: 'Filed manually from Diagnostics & Logs screen.',
        fullLog: _includeFullLog,
        context: {
          'log_file': fileName,
          'full_log': _includeFullLog,
        },
      );
      if (!mounted) return;
      switch (result.status) {
        case GithubReportStatus.created:
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Issue filed: ${result.url}')),
          );
          break;
        case GithubReportStatus.duplicate:
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Duplicate exists: ${result.url}')),
          );
          break;
        case GithubReportStatus.manualNeeded:
          await Clipboard.setData(ClipboardData(
              text: '${result.title}\n\n${result.body}'));
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  'No token configured — issue text copied. Paste it at github.com/OnlyXianzo/Grablytic/issues/new'),
              duration: Duration(seconds: 5),
            ),
          );
          break;
        case GithubReportStatus.failed:
          await Clipboard.setData(ClipboardData(
              text: '${result.title}\n\n${result.body}'));
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Upload failed — issue text copied for manual filing.')),
          );
          break;
      }
    } finally {
      if (mounted) setState(() => _reporting = false);
    }
  }

  /// Copies the selected log file to a user-visible folder
  /// (external app dir on Android — no permission needed; Downloads on
  /// desktop) and shows the destination path.
  Future<void> _exportLogFile() async {
    if (_exporting || _selectedFile == null) return;
    setState(() => _exporting = true);
    try {
      await AppLogger.flushNow();
      final dest = await AppLogger.exportLogFile(_selectedFile!);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(dest.startsWith('ERROR:')
              ? dest
              : 'Log exported to:\n$dest'),
          duration: const Duration(seconds: 5),
        ),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// Saves the selected log into the PUBLIC Downloads folder
  /// (Download/Grablytic-logs/ via MediaStore on Android 10+), which IS
  /// browsable in any file manager — unlike app-private dirs on Android
  /// 12+. Falls back to the external-app-dir export on failure.
  Future<void> _saveToDownloads() async {
    if (_exporting || _selectedFile == null) return;
    setState(() => _exporting = true);
    try {
      await AppLogger.flushNow();
      final file = _selectedFile!;
      final name = file.path.split('/').last;
      final engine = ref.read(engineProvider);
      final res = await engine.exportLogToDownloads(
        sourcePath: file.path,
        displayName: name,
      );
      String msg;
      if (res['success'] == true && res['path'] != null) {
        msg = 'Saved to Downloads:\n${res['path']}';
      } else {
        final fallback = await AppLogger.exportLogFile(file);
        msg = fallback.startsWith('ERROR:')
            ? fallback
            : 'Downloads unavailable — exported instead to:\n$fallback';
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 5)),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _confirmDeleteAll() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete All Logs'),
        content: const Text(
          'Are you sure you want to permanently delete all log files? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await AppLogger.deleteAllLogs();
              await _loadLogFiles();
            },
            child: const Text('Delete All'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics & Logs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              if (_selectedTab == 0) {
                _loadLogFiles();
              } else {
                setState(() {});
              }
            },
            tooltip: 'Refresh',
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _selectedTab == 0
                ? _confirmDeleteAll
                : () {
                    ref.read(logBufferProvider).clear();
                    setState(() {});
                  },
            tooltip: _selectedTab == 0 ? 'Delete All Logs' : 'Clear Live Logs',
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildSettingsCard(cs, tt),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(
                      value: 0,
                      label: Text('File Logs'),
                      icon: Icon(Icons.description),
                    ),
                    ButtonSegment(
                      value: 1,
                      label: Text('Live Stream'),
                      icon: Icon(Icons.stream),
                    ),
                  ],
                  selected: {_selectedTab},
                  onSelectionChanged: (v) => setState(() => _selectedTab = v.first),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _selectedTab == 0
                  ? _buildFileLogsTab(cs, tt)
                  : const LiveLogView(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingsCard(ColorScheme cs, TextTheme tt) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Card(
        elevation: 0,
        color: cs.surfaceContainerHigh.withAlpha(80),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                children: [
                  Icon(Icons.bug_report, color: cs.primary, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Enable Diagnostics Logging',
                      style: tt.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Switch(
                    value: _loggingEnabled,
                    onChanged: (val) async {
                      await AppLogger.setEnabled(val);
                      setState(() => _loggingEnabled = val);
                    },
                  ),
                ],
              ),
              const Divider(height: 24),
              Row(
                children: [
                  Icon(Icons.calendar_today, color: cs.primary, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Keep logs for $_retentionDays days',
                          style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                        ),
                        Text(
                          'Older logs will be automatically deleted',
                          style: tt.bodySmall?.copyWith(color: cs.outline),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              Slider(
                value: _retentionDays.toDouble(),
                min: 1,
                max: 30,
                divisions: 29,
                label: '$_retentionDays days',
                // onChanged = live label only (cheap setState). Persisting
                // here would write prefs + rescan the log dir on every drag
                // tick — persistence happens once in onChangeEnd.
                onChanged: _loggingEnabled
                    ? (val) {
                        setState(() => _retentionDays = val.toInt());
                      }
                    : null,
                onChangeEnd: _loggingEnabled
                    ? (val) async {
                        final days = val.toInt();
                        if (days == AppLogger.retentionDays) return;
                        await AppLogger.setRetentionDays(days);
                        if (!mounted) return;
                        setState(() => _retentionDays = days);
                      }
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFileLogsTab(ColorScheme cs, TextTheme tt) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Text(
                'Log File:',
                style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerLowest,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: cs.outlineVariant),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<File>(
                      value: _selectedFile,
                      isExpanded: true,
                      hint: const Text('Select a log file'),
                      items: _logFiles.map((f) {
                        return DropdownMenuItem<File>(
                          value: f,
                          child: Text(f.path.split('/').last, style: tt.bodyMedium),
                        );
                      }).toList(),
                      onChanged: (File? val) {
                        if (val != null) {
                          setState(() => _selectedFile = val);
                          _readLogContent(val);
                        }
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cs.primaryContainer.withAlpha(40),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: cs.primary.withAlpha(80)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.help_outline, size: 16, color: cs.primary),
                    const SizedBox(width: 6),
                    Text(
                      'Troubleshooting Flow',
                      style: tt.labelLarge?.copyWith(
                        color: cs.primary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '1. Click "Copy Prompt for AI" to bundle your log and analysis directions.\n'
                  '2. Paste it in your favorite AI (Gemini, Claude, Grok, ChatGPT).\n'
                  '3. Copy the bug description generated by the AI.\n'
                  '4. Click "Copy GitHub Link" and file/paste the issue there.',
                  style: tt.bodySmall?.copyWith(height: 1.4),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: cs.outlineVariant),
              ),
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(
                        _logContent,
                        style: tt.mono.copyWith(
                          color: Colors.lightGreenAccent,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            children: [
              Row(
                children: [
                  Icon(Icons.description_outlined,
                      size: 18, color: cs.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Include full log in report (default: tail only)',
                      style: tt.bodySmall,
                    ),
                  ),
                  Switch(
                    value: _includeFullLog,
                    onChanged: (val) =>
                        setState(() => _includeFullLog = val),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: (_exporting || _selectedFile == null)
                      ? null
                      : _exportLogFile,
                  icon: _exporting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child:
                              CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.file_download_outlined),
                  label: Text(
                      _exporting ? 'Exporting…' : 'Export log file'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: (_exporting || _selectedFile == null)
                          ? null
                          : _saveToDownloads,
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('Save to Downloads'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _reporting ? null : _reportToGithub,
                      icon: _reporting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.bug_report_outlined),
                      label: Text(
                          _reporting ? 'Reporting…' : 'Report to GitHub'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ),
              ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _copyAiPrompt,
                      icon: const Icon(Icons.psychology_outlined),
                      label: const Text('Copy Prompt for AI'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _openGithubIssues,
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('Copy GitHub Link'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
