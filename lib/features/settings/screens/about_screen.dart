import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/engine/engine_provider.dart';

/// Contact + repository surface. Tapping opens the page in whatever handles
/// it (GitHub app if installed, else browser; mail app for email) and only
/// falls back to clipboard copy when nothing can open it.
class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  static const _repoUrl = 'https://github.com/OnlyXianzo/Grablytic';
  static const _profileUrl = 'https://github.com/OnlyXianzo';
  static const _feedbackEmail = 'xianzo.help@gmail.com';

  Future<void> _openOrCopy(BuildContext context, WidgetRef ref, String target) async {
    bool opened = false;
    try {
      final res = await ref.read(engineProvider).openUrl(target);
      opened = res['success'] == true;
    } catch (_) {}
    if (!context.mounted) return;
    if (opened) return;
    await Clipboard.setData(ClipboardData(text: target));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Nothing could open it — copied instead:\n$target')),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('About'),
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.primary,
        elevation: 0,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          children: [
            const SizedBox(height: 24),
            Center(
              child: Column(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: Image.asset(
                      'assets/brand/grablytic_logo.png',
                      width: 96,
                      height: 96,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Grablytic',
                    style: textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.primary,
                    ),
                  ),
                  Text(
                    'by The Only',
                    style: textTheme.bodyLarge?.copyWith(
                      color: colorScheme.outline,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Version 0.0.1-beta (Build 1)',
                    style: textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 40),
            _buildSectionHeader(context, 'CONTRIBUTE & HELP'),
            const SizedBox(height: 12),
            Card(
              elevation: 0,
              color: colorScheme.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.3),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Grablytic is a local-first, zero-knowledge open source media acquisition engine. We do not track, collect, or store any of your data.',
                      style: textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Help us keep the project alive by contributing code, reporting bugs, or starring the repository on GitHub!',
                      style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 20),
                    ElevatedButton.icon(
                      onPressed: () => _openOrCopy(context, ref, _repoUrl),
                      icon: Semantics(label: 'GitHub star', child: Icon(Icons.star_border)),
                      label: const Text('Open repository on GitHub'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: colorScheme.primary,
                        foregroundColor: colorScheme.onPrimary,
                        minimumSize: const Size(double.infinity, 48),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () => _openOrCopy(context, ref, _profileUrl),
                      icon: const Icon(Icons.person_outline),
                      label: const Text('Open @OnlyXianzo profile'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 48),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            _buildSectionHeader(context, 'SUPPORT & FEEDBACK'),
            const SizedBox(height: 12),
            ListTile(
              leading: Semantics(label: 'Feedback', child: Icon(Icons.feedback_outlined)),
              title: const Text('Send Feedback'),
              subtitle: const Text('Report bugs or request features'),
              trailing: Semantics(label: 'Open', child: Icon(Icons.chevron_right)),
              onTap: () => _openOrCopy(context, ref, 'mailto:$_feedbackEmail'),
            ),
            const Divider(),
            ListTile(
              leading: Semantics(label: 'Licenses', child: Icon(Icons.policy_outlined)),
              title: const Text('Open Source Licenses'),
              subtitle: const Text('Third-party software notices'),
              trailing: Semantics(label: 'Open', child: Icon(Icons.chevron_right)),
              onTap: () {
                showLicensePage(
                  context: context,
                  applicationName: 'Grablytic',
                  applicationVersion: '0.0.1-beta',
                  applicationIcon: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Icon(Icons.cloud_download, color: colorScheme.primary, size: 48),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Text(
      title,
      style: textTheme.labelSmall?.copyWith(
        color: colorScheme.primary,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.5,
      ),
    );
  }
}
