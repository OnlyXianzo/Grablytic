import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/utils/app_logger.dart';
import '../../../core/theme/text_styles.dart';

class LogViewerScreen extends StatefulWidget {
  const LogViewerScreen({super.key});

  @override
  State<LogViewerScreen> createState() => _LogViewerScreenState();
}

class _LogViewerScreenState extends State<LogViewerScreen> {
  List<File> _logFiles = [];
  File? _selectedFile;
  String _logContent = 'Loading logs...';
  bool _isLoading = true;

  // Settings state
  bool _loggingEnabled = AppLogger.isEnabled;
  int _retentionDays = AppLogger.retentionDays;

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
        // Default to the newest log file
        _selectedFile = files.first;
      } else {
        _selectedFile = null;
        _logContent = 'No logs recorded yet.';
      }
      _isLoading = false;
    });

    if (_selectedFile != null) {
      await _readLogContent(_selectedFile!);
    }
  }

  Future<void> _readLogContent(File file) async {
    setState(() => _isLoading = true);
    final content = await AppLogger.readLogFile(file);
    setState(() {
      _logContent = content.isEmpty ? 'Log file is empty.' : content;
      _isLoading = false;
    });
  }

  void _copyToClipboard(String text, String successMessage) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(successMessage)),
    );
  }

  void _copyAiPrompt() {
    // We get a truncated chunk of logs (last 15,000 characters) so it fits AI context windows cleanly
    final truncatedLog = _logContent.length > 15000
        ? '... [TRUNCATED FOR LENGTH] ...\n${_logContent.substring(_logContent.length - 15000)}'
        : _logContent;

    final systemPrompt = '''
Please analyze the following error logs from the TrueStream Android/desktop media downloader app.
Explain what the bug is, why it happened, and what went wrong. Provide a formatted GitHub Issue description following standard bug report templates so I can paste it into GitHub Issues for review.

SYSTEM LOG DETAILS:
$truncatedLog
''';

    _copyToClipboard(
      systemPrompt,
      'System prompt and log content copied! Paste this into any AI (Gemini, Grok, ChatGPT, Claude) to generate your GitHub Issue.',
    );
  }

  void _openGithubIssues() {
    // Copy the repo link to clipboard as a fallback
    Clipboard.setData(const ClipboardData(text: 'https://github.com/OnlyXianzo/TrueStream/issues/new'));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('GitHub link copied! Open your browser and paste to create the issue.'),
      ),
    );
  }

  void _confirmDeleteAll() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete All Logs'),
        content: const Text('Are you sure you want to permanently delete all log files? This cannot be undone.'),
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
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics & Logs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadLogFiles,
            tooltip: 'Refresh',
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _confirmDeleteAll,
            tooltip: 'Delete All Logs',
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Controls section
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Card(
                elevation: 0,
                color: colorScheme.surfaceContainerHigh.withAlpha(80),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: colorScheme.outlineVariant.withAlpha(80),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      // Toggle Logging & Retention Slider
                      Row(
                        children: [
                          Icon(Icons.bug_report, color: colorScheme.primary, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Enable Diagnostics Logging',
                              style: textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                          Switch(
                            value: _loggingEnabled,
                            onChanged: (val) async {
                              await AppLogger.setEnabled(val);
                              setState(() {
                                _loggingEnabled = val;
                              });
                            },
                          ),
                        ],
                      ),
                      const Divider(height: 24),
                      Row(
                        children: [
                          Icon(Icons.calendar_today, color: colorScheme.primary, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Keep logs for $_retentionDays days',
                                  style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                                ),
                                Text(
                                  'Older logs will be automatically deleted',
                                  style: textTheme.bodySmall?.copyWith(color: colorScheme.outline),
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
                        onChanged: _loggingEnabled
                            ? (val) async {
                                final days = val.toInt();
                                await AppLogger.setRetentionDays(days);
                                setState(() {
                                    _retentionDays = days;
                                });
                              }
                            : null,
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Select Log File Dropdown
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Row(
                children: [
                  Text(
                    'Log File:',
                    style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerLowest,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: colorScheme.outlineVariant),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<File>(
                          value: _selectedFile,
                          isExpanded: true,
                          hint: const Text('Select a log file'),
                          items: _logFiles.map((file) {
                            final name = file.path.split('/').last;
                            return DropdownMenuItem<File>(
                              value: file,
                              child: Text(
                                name,
                                style: textTheme.bodyMedium,
                              ),
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

            // Guidance banner
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer.withAlpha(40),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: colorScheme.primary.withAlpha(80)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.help_outline, size: 16, color: colorScheme.primary),
                        const SizedBox(width: 6),
                        Text(
                          'Troubleshooting Flow',
                          style: textTheme.labelLarge?.copyWith(
                            color: colorScheme.primary,
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
                      style: textTheme.bodySmall?.copyWith(height: 1.4),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Log Console
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: colorScheme.outlineVariant),
                  ),
                  child: _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : SingleChildScrollView(
                          padding: const EdgeInsets.all(12),
                          child: SelectableText(
                            _logContent,
                            style: textTheme.mono.copyWith(
                              color: Colors.lightGreenAccent,
                              fontSize: 12,
                              height: 1.4,
                            ),
                          ),
                        ),
                ),
              ),
            ),

            // Bottom Buttons
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _copyAiPrompt,
                      icon: const Icon(Icons.psychology_outlined),
                      label: const Text('Copy Prompt for AI'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
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
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
