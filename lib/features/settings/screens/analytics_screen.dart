import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/utils/local_analytics.dart';

/// Strictly local analytics dashboard (T21).
///
/// Everything shown here lives on this device (SharedPreferences JSON) —
/// no network, no SDK. Incognito jobs are never recorded.
class AnalyticsScreen extends ConsumerStatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  ConsumerState<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends ConsumerState<AnalyticsScreen> {
  int? _rangeDays = 30;
  int _reload = 0;

  int? get _sinceMs => _rangeDays == null
      ? null
      : DateTime.now()
            .subtract(Duration(days: _rangeDays!))
            .millisecondsSinceEpoch;

  Future<void> _clear() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Clear analytics?'),
        content: const Text(
          'All locally stored counts and the failed-job list will be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (go == true) {
      await LocalAnalytics.clear();
      if (mounted) setState(() => _reload++);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Analytics')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
        children: [
          Text(
            'On this device only — no tracking, no uploads.',
            style: textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          SegmentedButton<int?>(
            segments: const [
              ButtonSegment(value: 7, label: Text('7 days')),
              ButtonSegment(value: 30, label: Text('30 days')),
              ButtonSegment(value: null, label: Text('All')),
            ],
            selected: {_rangeDays},
            onSelectionChanged: (v) => setState(() => _rangeDays = v.first),
          ),
          const SizedBox(height: 16),
          FutureBuilder<Map<String, int>>(
            key: ValueKey('summary-$_rangeDays-$_reload'),
            future: LocalAnalytics.summary(sinceMs: _sinceMs),
            builder: (context, snap) {
              final s =
                  snap.data ??
                  const {
                    'shares': 0,
                    'pastes': 0,
                    'success': 0,
                    'retries': 0,
                    'failures': 0,
                    'youtube': 0,
                    'instagram': 0,
                    'other': 0,
                  };
              return Column(
                children: [
                  Row(
                    children: [
                      _stat(context, 'Shares', s['shares'] ?? 0),
                      const SizedBox(width: 12),
                      _stat(context, 'Pastes', s['pastes'] ?? 0),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      _stat(context, 'Success', s['success'] ?? 0),
                      const SizedBox(width: 12),
                      _stat(context, 'Retries', s['retries'] ?? 0),
                      const SizedBox(width: 12),
                      _stat(context, 'Failures', s['failures'] ?? 0),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      _stat(context, 'YouTube', s['youtube'] ?? 0),
                      const SizedBox(width: 12),
                      _stat(context, 'Instagram', s['instagram'] ?? 0),
                      const SizedBox(width: 12),
                      _stat(context, 'Other', s['other'] ?? 0),
                    ],
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 24),
          Text(
            'FAILED JOBS',
            style: textTheme.labelSmall?.copyWith(
              color: colorScheme.primary,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 8),
          FutureBuilder<List<Map<String, dynamic>>>(
            key: ValueKey('failures-$_rangeDays-$_reload'),
            future: LocalAnalytics.failures(sinceMs: _sinceMs),
            builder: (context, snap) {
              final items = snap.data ?? [];
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(),
                  ),
                );
              }
              if (items.isEmpty) {
                return Card(
                  elevation: 0,
                  color: colorScheme.surfaceContainerLow,
                  child: const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No failed jobs in this range.'),
                  ),
                );
              }
              return Column(
                children: [
                  for (final f in items)
                    Card(
                      elevation: 0,
                      color: colorScheme.surfaceContainerLow,
                      child: ListTile(
                        leading: const Icon(Icons.error_outline),
                        title: Text(
                          (f['title'] as String? ?? '').isEmpty
                              ? (f['jobId'] as String? ?? 'Job')
                              : f['title'] as String,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${f['domain'] ?? 'other'}'
                          '${(f['errorType'] as String? ?? '').isNotEmpty ? ' · ${f['errorType']}' : ''}',
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _clear,
              icon: const Icon(Icons.delete_sweep_outlined),
              label: const Text('Clear analytics'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stat(BuildContext context, String label, int value) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: colorScheme.outlineVariant.withValues(alpha: 0.25),
          ),
        ),
        child: Column(
          children: [
            Text(
              '$value',
              style: textTheme.headlineSmall?.copyWith(
                color: colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(label, style: textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
