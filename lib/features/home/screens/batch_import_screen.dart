import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/link_importer.dart';
import '../../../providers/batch_provider.dart';
import 'batch_download_screen.dart';

/// Batch file import: paste links or pick a `.txt`/`.csv` chunk file,
/// preview the parsed count, then start a batch.
///
/// Parsing is delegated to the pure [parseLinkImport] helper (no I/O).
/// Navigation wiring is intentionally left to the caller — this screen
/// pushes [BatchDownloadScreen] itself on Start but is not linked from
/// any route yet (orchestrator wires that up).
class BatchImportScreen extends ConsumerStatefulWidget {
  final String? playlistId;

  const BatchImportScreen({super.key, this.playlistId});

  @override
  ConsumerState<BatchImportScreen> createState() => _BatchImportScreenState();
}

class _BatchImportScreenState extends ConsumerState<BatchImportScreen> {
  final _controller = TextEditingController();
  bool _csvMode = false;
  String? _fileName;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  LinkImportResult get _result =>
      parseLinkImport(_controller.text, csvMode: _csvMode);

  Future<void> _pickFile() async {
    setState(() => _error = null);
    try {
      final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['txt', 'csv'],
        withData: true,
      );
      if (picked == null || picked.files.isEmpty) return;
      final file = picked.files.single;
      String? content;
      if (file.bytes != null) {
        content = utf8.decode(file.bytes!, allowMalformed: true);
      } else if (file.path != null) {
        content = await File(file.path!).readAsString();
      }
      if (content == null) {
        setState(() => _error = 'Could not read ${file.name}.');
        return;
      }
      final isCsv = file.extension?.toLowerCase() == 'csv';
      setState(() {
        _controller.text = content!;
        _fileName = file.name;
        _csvMode = isCsv;
      });
    } catch (e) {
      setState(() => _error = 'Could not pick file: $e');
    }
  }

  void _startBatch(LinkImportResult result) {
    final items = result.links
        .map((url) => BatchItem(url: url, title: url))
        .toList(growable: false);
    if (items.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BatchDownloadScreen(
          items: items,
          playlistId: widget.playlistId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final result = _result;
    final count = result.links.length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Batch Import'),
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.primary,
        elevation: 0,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              'Paste links or pick a chunk file (.txt) or Instagram '
              'exporter CSV. One URL per line for text; CSV cells are '
              'scanned for links and shortcodes.',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('batchImportInput'),
              controller: _controller,
              maxLines: 8,
              minLines: 4,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                labelText: 'Paste links',
                hintText: 'https://www.instagram.com/p/...\none per line',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                OutlinedButton.icon(
                  key: const Key('batchImportPickFile'),
                  onPressed: _pickFile,
                  icon: const Icon(Icons.upload_file_outlined, size: 18),
                  label: const Text('Pick file'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _fileName ?? 'No file picked',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                'CSV mode (Instagram exporter)',
                style: textTheme.bodyMedium,
              ),
              value: _csvMode,
              activeThumbColor: colorScheme.primary,
              onChanged: (v) => setState(() => _csvMode = v),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _error!,
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.error,
                  ),
                ),
              ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                count == 0
                    ? 'No links found yet'
                    : '$count link${count == 1 ? '' : 's'} ready'
                        '${result.overflowCount > 0 ? ' (+${result.overflowCount} over the $maxBatchLinks cap)' : ''}',
                key: const Key('batchImportCount'),
                style: textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              key: const Key('batchImportStart'),
              onPressed: count == 0 ? null : () => _startBatch(result),
              icon: const Icon(Icons.download_outlined),
              label: Text(
                count == 0 ? 'Start' : 'Start ($count)',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
