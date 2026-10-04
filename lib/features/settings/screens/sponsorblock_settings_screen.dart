import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/text_styles.dart';
import '../../../providers/settings_provider.dart';

class SponsorBlockSettingsScreen extends ConsumerWidget {
  const SponsorBlockSettingsScreen({super.key});

  static const _categories = [
    ('Sponsor', 'sponsor'),
    ('Intro/Interstitial', 'intro'),
    ('Endcards/Credits', 'outro'),
    ('Unpaid Promotion', 'selfpromo'),
    ('Interaction Reminder', 'interaction'),
    ('Preview/Recap', 'preview'),
    ('Music', 'music_offtopic'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('SponsorBlock'),
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.primary,
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  'Skip sponsored segments, intros, endcards, and other unwanted video sections automatically using the SponsorBlock database.',
                  style: textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'CATEGORIES TO SKIP',
                style: textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(height: 12),
              ..._categories.map((cat) {
                final label = cat.$1;
                final code = cat.$2;
                final selected = settings.sponsorBlockCats.contains(code);
                return _SponsorBlockToggle(
                  icon: _iconFor(code),
                  title: label,
                  value: selected,
                  onChanged: (val) {
                    final notifier = ref.read(settingsProvider.notifier);
                    final current =
                        List<String>.from(settings.sponsorBlockCats);
                    if (val) {
                      current.add(code);
                    } else {
                      current.remove(code);
                    }
                    notifier.setSponsorBlockCats(current);
                  },
                  colorScheme: colorScheme,
                );
              }),
              const SizedBox(height: 24),
              Text(
                'Categories selected: ${settings.sponsorBlockCats.length}',
                style: textTheme.mono.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 12,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static IconData _iconFor(String code) {
    switch (code) {
      case 'sponsor':
        return Icons.work_off;
      case 'intro':
        return Icons.gavel;
      case 'outro':
        return Icons.credit_score;
      case 'selfpromo':
        return Icons.campaign;
      case 'interaction':
        return Icons.notifications_off;
      case 'preview':
        return Icons.replay;
      case 'music_offtopic':
        return Icons.music_off;
      default:
        return Icons.block;
    }
  }
}

class _SponsorBlockToggle extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;
  final ColorScheme colorScheme;

  const _SponsorBlockToggle({
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Semantics(
      label: '$title, ${value ? 'enabled' : 'disabled'}',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Semantics(
              label: title,
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(icon, color: colorScheme.primary, size: 20),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(title, style: textTheme.bodyLarge),
            ),
            Switch.adaptive(
              value: value,
              onChanged: onChanged,
              activeTrackColor: colorScheme.primary,
              inactiveTrackColor: colorScheme.surfaceContainerHighest,
              thumbColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.selected)) {
                  return colorScheme.onPrimary;
                }
                return colorScheme.outline;
              }),
            ),
          ],
        ),
      ),
    );
  }
}
