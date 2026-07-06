import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/theme/text_styles.dart';
import '../../../providers/batch_provider.dart';
import 'batch_download_screen.dart';

class BatchImportDialog extends ConsumerStatefulWidget {
  const BatchImportDialog({super.key});

  @override
  ConsumerState<BatchImportDialog> createState() => _BatchImportDialogState();
}

class _BatchImportDialogState extends ConsumerState<BatchImportDialog> {
  final _controller = TextEditingController();
  final Set<String> _selectedUrls = {};
  List<String> _parsedUrls = [];
  bool _hasParsed = false;
  bool _importing = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool _isValidUrl(String url) {
    return url.startsWith('http://') || url.startsWith('https://');
  }

  void _parseUrls() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    final urls = text
        .split(RegExp(r'[\n\r]+'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .map((l) {
          final m = RegExp(r'https?://[^\s]+').firstMatch(l);
          return m?.group(0) ?? l;
        })
        .where((u) => _isValidUrl(u))
        .toList();

    setState(() {
      _parsedUrls = urls;
      _selectedUrls.addAll(urls);
      _hasParsed = true;
    });
  }

  void _toggleUrl(String url) {
    setState(() {
      if (_selectedUrls.contains(url)) {
        _selectedUrls.remove(url);
      } else {
        _selectedUrls.add(url);
      }
    });
  }

  void _selectAllToggle() {
    setState(() {
      if (_selectedUrls.length == _parsedUrls.length) {
        _selectedUrls.clear();
      } else {
        _selectedUrls.addAll(_parsedUrls);
      }
    });
  }

  void _importSelected() {
    setState(() => _importing = true);
    final batchItems = _selectedUrls
        .map((url) => BatchItem(url: url, title: url))
        .toList();

    if (mounted) {
      Navigator.pop(context);
      if (batchItems.isNotEmpty) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => BatchDownloadScreen(items: batchItems),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return AlertDialog(
      backgroundColor: colorScheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(Icons.dashboard_customize, color: colorScheme.primary, size: 24),
          const SizedBox(width: 12),
          Text('Batch Import', style: textTheme.titleMedium),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: _hasParsed ? _buildUrlList(colorScheme, textTheme) : _buildInputField(colorScheme, textTheme),
      ),
      actions: [
        TextButton(
          onPressed: _importing ? null : () => Navigator.pop(context),
          style: TextButton.styleFrom(foregroundColor: colorScheme.outline),
          child: const Text('Cancel'),
        ),
        if (_hasParsed)
          ElevatedButton(
            onPressed: (_selectedUrls.isEmpty || _importing) ? null : _importSelected,
            style: ElevatedButton.styleFrom(
              backgroundColor: colorScheme.primary,
              foregroundColor: colorScheme.onPrimary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: Text('Import Selected (${_selectedUrls.length})'),
          ),
      ],
    );
  }

  Widget _buildInputField(ColorScheme colorScheme, TextTheme textTheme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _controller,
          maxLines: 6,
          minLines: 3,
          decoration: InputDecoration(
            labelText: 'Add URLs',
            hintText: 'Paste multiple URLs, one per line...',
            labelStyle: GoogleFonts.instrumentSans(
              color: colorScheme.primary,
              fontWeight: FontWeight.w500,
            ),
            hintStyle: TextStyle(color: colorScheme.outline.withValues(alpha: 0.4)),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.4)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: colorScheme.primary),
            ),
          ),
          style: GoogleFonts.instrumentSans(color: colorScheme.onSurface),
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: _parseUrls,
            icon: const Icon(Icons.playlist_add_check, size: 18),
            label: const Text('Parse URLs'),
          ),
        ),
      ],
    );
  }

  Widget _buildUrlList(ColorScheme colorScheme, TextTheme textTheme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '${_parsedUrls.length} URL${_parsedUrls.length == 1 ? '' : 's'} found',
              style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
            const Spacer(),
            TextButton(
              onPressed: _selectAllToggle,
              style: TextButton.styleFrom(
                foregroundColor: colorScheme.primary,
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                _selectedUrls.length == _parsedUrls.length ? 'Deselect All' : 'Select All',
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Flexible(
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _parsedUrls.length,
            itemBuilder: (context, index) {
              final url = _parsedUrls[index];
              final isSelected = _selectedUrls.contains(url);
              return InkWell(
                onTap: () => _toggleUrl(url),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Checkbox(
                        value: isSelected,
                        onChanged: (_) => _toggleUrl(url),
                        activeColor: colorScheme.primary,
                        checkColor: colorScheme.onPrimary,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          url,
                          style: textTheme.mono.copyWith(fontSize: 12),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
