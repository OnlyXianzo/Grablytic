import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:file_picker/file_picker.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../providers/settings_provider.dart';
import 'command_templates_screen.dart';
import 'presets_screen.dart';
import 'subtitle_settings_screen.dart';
import 'schedule_settings_screen.dart';
import 'sponsorblock_settings_screen.dart';
import 'about_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Settings',
                style: textTheme.headlineSmall?.copyWith(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Download',
                  style: textTheme.titleMedium?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _SettingSwitch(
                icon: Icons.cloud_outlined,
                title: 'Wi-Fi Only Downloads',
                subtitle: 'Prevent data usage for downloads',
                value: settings.wifiOnly,
                onChanged: () => ref.read(settingsProvider.notifier).toggleWifiOnly(),
                colorScheme: colorScheme,
              ).animate().fadeIn(duration: 300.ms).slideX(begin: 0.1),
              _SettingSwitch(
                icon: Icons.speed,
                title: 'Enable Turbo Download Mode',
                subtitle: 'Accelerate speed with multi-threading',
                value: settings.turboMode,
                onChanged: () => ref.read(settingsProvider.notifier).toggleTurboMode(),
                colorScheme: colorScheme,
              ).animate().fadeIn(delay: 80.ms, duration: 300.ms).slideX(begin: 0.1),
              _SettingNavItem(
                icon: Icons.folder_outlined,
                title: 'Download Path',
                subtitle: settings.downloadPath,
                colorScheme: colorScheme,
                onTap: () async {
                  try {
                    final selectedDirectory = await FilePicker.getDirectoryPath();
                    if (selectedDirectory != null && context.mounted) {
                      ref.read(settingsProvider.notifier).setDownloadPath(selectedDirectory);
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Error picking folder: $e')),
                      );
                    }
                  }
                },
              ).animate().fadeIn(delay: 160.ms, duration: 300.ms).slideX(begin: 0.1),
              _SettingSwitch(
                icon: Icons.air,
                title: 'Enable aria2c',
                subtitle: 'Multi-connection download acceleration',
                value: settings.aria2cEnabled,
                onChanged: () => ref.read(settingsProvider.notifier).setAria2cEnabled(!settings.aria2cEnabled),
                colorScheme: colorScheme,
              ).animate().fadeIn(delay: 180.ms, duration: 300.ms).slideX(begin: 0.1),
              if (settings.aria2cEnabled) ...[
                _Aria2cChunkSlider(
                  chunks: settings.aria2cChunks,
                  onChanged: (v) => ref.read(settingsProvider.notifier).setAria2cChunks(v),
                  colorScheme: colorScheme,
                ).animate().fadeIn(delay: 200.ms, duration: 300.ms).slideX(begin: 0.1),
                _Aria2cSpeedField(
                  maxSpeed: settings.aria2cMaxSpeed,
                  onChanged: (v) => ref.read(settingsProvider.notifier).setAria2cMaxSpeed(v),
                  colorScheme: colorScheme,
                ).animate().fadeIn(delay: 220.ms, duration: 300.ms).slideX(begin: 0.1),
              ],
              _SettingNavItem(
                icon: Icons.tune,
                title: 'Download Presets',
                subtitle: 'Configure quality & container settings',
                colorScheme: colorScheme,
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const PresetsScreen(),
                    ),
                  );
                },
              ).animate().fadeIn(delay: 200.ms, duration: 300.ms).slideX(begin: 0.1),
              _SettingNavItem(
                icon: Icons.closed_caption_outlined,
                title: 'Subtitle Settings',
                subtitle: 'Language, auto-captions & embedding',
                colorScheme: colorScheme,
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const SubtitleSettingsScreen(),
                    ),
                  );
                },
              ).animate().fadeIn(delay: 220.ms, duration: 300.ms).slideX(begin: 0.1),
              _SettingNavItem(
                icon: Icons.schedule,
                title: 'Download Schedule',
                subtitle: 'Set time windows for downloads',
                colorScheme: colorScheme,
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const ScheduleSettingsScreen(),
                    ),
                  );
                },
              ).animate().fadeIn(delay: 230.ms, duration: 300.ms).slideX(begin: 0.1),
              Padding(
                padding: const EdgeInsets.only(top: 24, bottom: 8),
                child: Text(
                  'Download Archive',
                  style: textTheme.titleMedium?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _SettingSwitch(
                icon: Icons.archive_outlined,
                title: 'Track downloaded videos',
                subtitle: 'yt-dlp avoids re-downloading duplicates',
                value: settings.downloadArchive,
                onChanged: () => ref.read(settingsProvider.notifier).setDownloadArchive(!settings.downloadArchive),
                colorScheme: colorScheme,
              ).animate().fadeIn(delay: 250.ms, duration: 300.ms).slideX(begin: 0.1),
              if (settings.downloadArchive)
                _SettingSwitch(
                  icon: Icons.folder_special_outlined,
                  title: 'Organize by folder',
                  subtitle: 'Separate archive per download folder',
                  value: settings.archiveByFolder,
                  onChanged: () => ref.read(settingsProvider.notifier).setArchiveByFolder(!settings.archiveByFolder),
                  colorScheme: colorScheme,
                ).animate().fadeIn(delay: 260.ms, duration: 300.ms).slideX(begin: 0.1),
              Padding(
                padding: const EdgeInsets.only(top: 24, bottom: 8),
                child: Text(
                  'Content Filtering',
                  style: textTheme.titleMedium?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _SettingNavItem(
                icon: Icons.block,
                title: 'SponsorBlock',
                subtitle: 'Skip sponsored segments',
                colorScheme: colorScheme,
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const SponsorBlockSettingsScreen(),
                    ),
                  );
                },
              ).animate().fadeIn(delay: 240.ms, duration: 300.ms).slideX(begin: 0.1),
              Padding(
                padding: const EdgeInsets.only(top: 24, bottom: 8),
                child: Text(
                  'Engine',
                  style: textTheme.titleMedium?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _SettingNavItem(
                icon: Icons.terminal,
                title: 'Command Templates',
                subtitle: 'Custom yt-dlp argument templates',
                colorScheme: colorScheme,
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const CommandTemplatesScreen(),
                    ),
                  );
                },
              ).animate().fadeIn(delay: 260.ms, duration: 300.ms).slideX(begin: 0.1),
              Padding(
                padding: const EdgeInsets.only(top: 24, bottom: 8),
                child: Text(
                  'Post-Processing',
                  style: textTheme.titleMedium?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _SettingSwitch(
                icon: Icons.content_cut,
                title: 'Split Chapters',
                subtitle: 'Split video into chapters after download',
                value: settings.splitChapters,
                onChanged: () => ref.read(settingsProvider.notifier).toggleSplitChapters(),
                colorScheme: colorScheme,
              ).animate().fadeIn(delay: 240.ms, duration: 300.ms).slideX(begin: 0.1),
              _SettingSwitch(
                icon: Icons.notifications_outlined,
                title: 'Download Completion Alerts',
                subtitle: 'Notify when a file finishes',
                value: settings.completionAlerts,
                onChanged: () => ref.read(settingsProvider.notifier).toggleCompletionAlerts(),
                colorScheme: colorScheme,
              ).animate().fadeIn(delay: 260.ms, duration: 300.ms).slideX(begin: 0.1),
              _SettingThemeSelector(
                currentTheme: settings.themeMode,
                onChanged: (mode) => ref.read(settingsProvider.notifier).setThemeMode(mode),
                colorScheme: colorScheme,
              ).animate().fadeIn(delay: 300.ms, duration: 300.ms).slideX(begin: 0.1),
              _SettingNavItem(
                icon: Icons.info_outline,
                title: 'About TrueStream',
                subtitle: 'v0.0.1-beta · The Only',
                colorScheme: colorScheme,
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const AboutScreen(),
                    ),
                  );
                },
              ).animate().fadeIn(delay: 340.ms, duration: 300.ms).slideX(begin: 0.1),
              _SettingAction(
                icon: Icons.history,
                title: 'Clear Search History',
                colorScheme: colorScheme,
              ).animate().fadeIn(delay: 380.ms, duration: 300.ms).slideX(begin: 0.1),
              const SizedBox(height: 32),
              // Version badge
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: colorScheme.outlineVariant.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Text(
                    'beta testing pre-release',
                    style: textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingSwitch extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final VoidCallback onChanged;
  final ColorScheme colorScheme;

  const _SettingSwitch({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Semantics(
      label: '$title, $subtitle, ${value ? 'enabled' : 'disabled'}',
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
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: colorScheme.outline, size: 20),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: textTheme.bodyLarge),
                  Text(
                    subtitle,
                    style: textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Switch.adaptive(
              value: value,
              onChanged: (_) => onChanged(),
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

class _SettingNavItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final ColorScheme colorScheme;
  final VoidCallback? onTap;

  const _SettingNavItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.colorScheme,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Semantics(
      button: true,
      label: '$title, $subtitle',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          child: Row(
            children: [
              Semantics(
                label: title,
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: colorScheme.outline, size: 20),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: textTheme.bodyLarge),
                    Text(
                      subtitle,
                      style: textTheme.labelSmall?.copyWith(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              Semantics(
                label: 'Navigate',
                child: Icon(Icons.chevron_right, color: colorScheme.outline, size: 20),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingAction extends StatelessWidget {
  final IconData icon;
  final String title;
  final ColorScheme colorScheme;

  const _SettingAction({
    required this.icon,
    required this.title,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Semantics(
            label: title,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHigh,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: colorScheme.outline, size: 20),
            ),
          ),
          const SizedBox(width: 16),
          Text(
            title,
            style: textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _Aria2cChunkSlider extends StatelessWidget {
  final int chunks;
  final ValueChanged<int> onChanged;
  final ColorScheme colorScheme;

  const _Aria2cChunkSlider({
    required this.chunks,
    required this.onChanged,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Semantics(
            label: 'Concurrent chunks',
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.link, color: colorScheme.outline, size: 20),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Concurrent chunks', style: textTheme.bodyLarge),
                Text(
                  '${chunks} connections',
                  style: textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 120,
            child: Slider(
              value: chunks.toDouble(),
              min: 1,
              max: 16,
              divisions: 15,
              label: '$chunks',
              activeColor: colorScheme.primary,
              inactiveColor: colorScheme.surfaceContainerHighest,
              onChanged: (v) => onChanged(v.round()),
            ),
          ),
        ],
      ),
    );
  }
}

class _Aria2cSpeedField extends StatelessWidget {
  final String? maxSpeed;
  final ValueChanged<String?> onChanged;
  final ColorScheme colorScheme;

  const _Aria2cSpeedField({
    required this.maxSpeed,
    required this.onChanged,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final controller = TextEditingController(text: maxSpeed ?? '');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Semantics(
            label: 'Max speed limit',
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.speed, color: colorScheme.outline, size: 20),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Max speed limit', style: textTheme.bodyLarge),
                Text(
                  'e.g. 10M or leave empty for unlimited',
                  style: textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 100,
            child: TextField(
              controller: controller,
              style: GoogleFonts.instrumentSans(
                fontSize: 14,
                color: colorScheme.onSurface,
              ),
              decoration: InputDecoration(
                hintText: 'Unlimited',
                hintStyle: GoogleFonts.instrumentSans(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 14,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: colorScheme.outlineVariant),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                isDense: true,
              ),
              keyboardType: TextInputType.text,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^[0-9]*[KMGT]?$')),
              ],
              onChanged: (v) => onChanged(v.isEmpty ? null : v),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingThemeSelector extends StatelessWidget {
  final AppThemeMode currentTheme;
  final ValueChanged<AppThemeMode> onChanged;
  final ColorScheme colorScheme;

  const _SettingThemeSelector({
    required this.currentTheme,
    required this.onChanged,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Semantics(
      label: 'Appearance, Choose Light, Dark, or System mode',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Semantics(
              label: 'Appearance',
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.palette_outlined, color: colorScheme.outline, size: 20),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Appearance', style: textTheme.bodyLarge),
                  Text(
                    'Choose Light, Dark, or System mode',
                    style: textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Semantics(
              label: 'Theme selection, currently ${currentTheme.name}',
              child: DropdownButton<AppThemeMode>(
                value: currentTheme,
                onChanged: (val) {
                  if (val != null) onChanged(val);
                },
                dropdownColor: colorScheme.surfaceContainerHigh,
                items: const [
                  DropdownMenuItem(
                    value: AppThemeMode.system,
                    child: Text('System'),
                  ),
                  DropdownMenuItem(
                    value: AppThemeMode.light,
                    child: Text('Light'),
                  ),
                  DropdownMenuItem(
                    value: AppThemeMode.dark,
                    child: Text('Dark'),
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

