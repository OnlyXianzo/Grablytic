import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
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
                  ClipOval(
                    child: Image.asset(
                      'assets/brand/truestream_logo.png',
                      width: 96,
                      height: 96,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'TrueStream',
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
                      'TrueStream is a local-first, zero-knowledge open source media acquisition engine. We do not track, collect, or store any of your data.',
                      style: textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Help us keep the project alive by contributing code, reporting bugs, or starring the repository on GitHub!',
                      style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 20),
                    ElevatedButton.icon(
                      onPressed: () {
                        Clipboard.setData(
                          const ClipboardData(
                            text: 'https://github.com/OnlyXianzo/TrueStream',
                          ),
                        );
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('GitHub repository link copied to clipboard!'),
                          ),
                        );
                      },
                      icon: Semantics(label: 'GitHub star', child: Icon(Icons.star_border)),
                      label: const Text('Star & Copy GitHub Link'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: colorScheme.primary,
                        foregroundColor: colorScheme.onPrimary,
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
              onTap: () {
                Clipboard.setData(
                  const ClipboardData(
                    text: 'feedback@theonly.com',
                  ),
                );
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Feedback email copied to clipboard!'),
                  ),
                );
              },
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
                  applicationName: 'TrueStream',
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
