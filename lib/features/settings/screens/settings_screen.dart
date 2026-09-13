import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:file_picker/file_picker.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../providers/settings_provider.dart';
import '../../../providers/search_provider.dart';
import '../../../providers/engine_status_provider.dart';
import '../../../core/engine/engine_provider.dart';
import '../../../core/theme/text_styles.dart';
import '../../home/widgets/bootstrap_status_card.dart';
import 'command_templates_screen.dart';
import 'cookies_screen.dart';
import 'observed_sources_screen.dart';
import 'presets_screen.dart';
import 'subtitle_settings_screen.dart';
import 'schedule_settings_screen.dart';
import 'sponsorblock_settings_screen.dart';
import 'about_screen.dart';
import 'log_viewer_screen.dart';


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
              // 1. General & Interface
              _SettingsSection(
                title: 'General & Interface',
                icon: Icons.tune,
                children: [
                  _SettingThemeSelector(
                    currentTheme: settings.themeMode,
                    onChanged: (mode) => ref.read(settingsProvider.notifier).setThemeMode(mode),
                    colorScheme: colorScheme,
                  ),
                  _SettingSwitch(
                    icon: Icons.grid_view_outlined,
                    title: 'Library Grid View',
                    subtitle: 'Display media cards in two-column masonry grid',
                    value: settings.useGridView,
                    onChanged: () => ref.read(settingsProvider.notifier).toggleGridView(),
                    colorScheme: colorScheme,
                  ),
                  _SettingSwitch(
                    icon: Icons.notifications_outlined,
                    title: 'Download Completion Alerts',
                    subtitle: 'Notify when a file finishes',
                    value: settings.completionAlerts,
                    onChanged: () => ref.read(settingsProvider.notifier).toggleCompletionAlerts(),
                    colorScheme: colorScheme,
                  ),
                  _SettingSwitch(
                    icon: Icons.share_outlined,
                    title: 'Auto-start Download on Share',
                    subtitle: 'Automatically start when link is shared to TrueStream',
                    value: settings.autoStartDownloadOnShare,
                    onChanged: () => ref.read(settingsProvider.notifier).toggleAutoStartDownloadOnShare(),
                    colorScheme: colorScheme,
                  ),
                  const _BackgroundPermissionsSection(),
                ],
              ).animate().fadeIn(duration: 300.ms).slideX(begin: 0.05),

              // 2. Directories & Storage
              _SettingsSection(
                title: 'Directories & Storage',
                icon: Icons.folder_outlined,
                children: [
                  _SettingNavItem(
                    icon: Icons.folder_outlined,
                    title: 'Download folder',
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
                  ),
                  _SettingSwitch(
                    icon: Icons.archive_outlined,
                    title: 'Skip already-downloaded videos',
                    subtitle: 'yt-dlp avoids re-downloading duplicates',
                    value: settings.downloadArchive,
                    onChanged: () => ref.read(settingsProvider.notifier).setDownloadArchive(!settings.downloadArchive),
                    colorScheme: colorScheme,
                  ),
                  if (settings.downloadArchive)
                    _SettingSwitch(
                      icon: Icons.folder_special_outlined,
                      title: 'Separate history per folder',
                      subtitle: 'Separate archive per download folder',
                      value: settings.archiveByFolder,
                      onChanged: () => ref.read(settingsProvider.notifier).setArchiveByFolder(!settings.archiveByFolder),
                      colorScheme: colorScheme,
                    ),
                  _SettingAction(
                    icon: Icons.history,
                    title: 'Clear Search History',
                    subtitle: 'Remove cached search queries',
                    colorScheme: colorScheme,
                    onTap: () {
                      ref.read(searchProvider.notifier).clear();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Search history cleared')),
                      );
                    },
                  ),
                ],
              ).animate().fadeIn(delay: 50.ms, duration: 300.ms).slideX(begin: 0.05),

              // 3. Network & Acceleration
              _SettingsSection(
                title: 'Network & Acceleration',
                icon: Icons.speed,
                children: [
                  _SettingSwitch(
                    icon: Icons.cloud_outlined,
                    title: 'Wi-Fi Only Downloads',
                    subtitle: 'Prevent data usage for downloads',
                    value: settings.wifiOnly,
                    onChanged: () => ref.read(settingsProvider.notifier).toggleWifiOnly(),
                    colorScheme: colorScheme,
                  ),
                  _SettingSwitch(
                    icon: Icons.speed,
                    title: 'Turbo download mode',
                    subtitle: 'Accelerate speed with multi-threading',
                    value: settings.turboMode,
                    onChanged: () => ref.read(settingsProvider.notifier).toggleTurboMode(),
                    colorScheme: colorScheme,
                  ),
                  _SettingSwitch(
                    icon: Icons.air,
                    title: 'Use aria2c accelerator',
                    subtitle: 'Multi-connection download acceleration',
                    value: settings.aria2cEnabled,
                    onChanged: () => ref.read(settingsProvider.notifier).setAria2cEnabled(!settings.aria2cEnabled),
                    colorScheme: colorScheme,
                  ),
                  if (settings.aria2cEnabled) ...[
                    _Aria2cChunkSlider(
                      chunks: settings.aria2cChunks,
                      onChanged: (v) => ref.read(settingsProvider.notifier).setAria2cChunks(v),
                      colorScheme: colorScheme,
                    ),
                    _Aria2cSpeedField(
                      maxSpeed: settings.aria2cMaxSpeed,
                      onChanged: (v) => ref.read(settingsProvider.notifier).setAria2cMaxSpeed(v),
                      colorScheme: colorScheme,
                    ),
                  ],
                  _SettingNavItem(
                    icon: Icons.vpn_key_outlined,
                    title: 'Proxy server',
                    subtitle: (settings.proxy?.isNotEmpty ?? false)
                        ? settings.proxy!
                        : 'Not set — direct connection',
                    colorScheme: colorScheme,
                    onTap: () async {
                      final controller =
                          TextEditingController(text: settings.proxy ?? '');
                      final picked = await showDialog<String>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16)),
                          title: const Text('Proxy server'),
                          content: TextField(
                            controller: controller,
                            decoration: const InputDecoration(
                              labelText: 'Proxy URL',
                              hintText: 'http://proxy:8080',
                              border: OutlineInputBorder(),
                            ),
                            keyboardType: TextInputType.url,
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text('Cancel'),
                            ),
                            if (settings.proxy?.isNotEmpty ?? false)
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, ''),
                                child: const Text('Remove'),
                              ),
                            FilledButton(
                              onPressed: () =>
                                  Navigator.pop(ctx, controller.text.trim()),
                              child: const Text('Save'),
                            ),
                          ],
                        ),
                      );
                      if (picked != null && context.mounted) {
                        ref
                            .read(settingsProvider.notifier)
                            .setProxy(picked.isEmpty ? null : picked);
                      }
                    },
                  ),
                  _SettingNavItem(
                    icon: Icons.tune,
                    title: 'Quality presets',
                    subtitle: 'Configure quality & container settings',
                    colorScheme: colorScheme,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const PresetsScreen(),
                        ),
                      );
                    },
                  ),
                ],
              ).animate().fadeIn(delay: 100.ms, duration: 300.ms).slideX(begin: 0.05),

              // 4. Media & Post-Processing
              _SettingsSection(
                title: 'Media & Subtitles',
                icon: Icons.movie_filter_outlined,
                children: [
                  _SettingNavItem(
                    icon: Icons.closed_caption_outlined,
                    title: 'Subtitles',
                    subtitle: 'Language, auto-captions & embedding',
                    colorScheme: colorScheme,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const SubtitleSettingsScreen(),
                        ),
                      );
                    },
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
                  ),
                  _SettingSwitch(
                    icon: Icons.content_cut,
                    title: 'Split video by chapters',
                    subtitle: 'Split video into chapters after download',
                    value: settings.splitChapters,
                    onChanged: () => ref.read(settingsProvider.notifier).toggleSplitChapters(),
                    colorScheme: colorScheme,
                  ),
                  _SettingSwitch(
                    icon: Icons.description_outlined,
                    title: 'Save video description',
                    subtitle: 'Save video description as a text file',
                    value: settings.saveDescription,
                    onChanged: () => ref.read(settingsProvider.notifier).toggleSaveDescription(),
                    colorScheme: colorScheme,
                  ),
                  _SettingSwitch(
                    icon: Icons.image_outlined,
                    title: 'Lossless thumbnails (PNG)',
                    subtitle: 'Save thumbnail image as PNG instead of JPG',
                    value: settings.pngThumbnails,
                    onChanged: () => ref.read(settingsProvider.notifier).togglePngThumbnails(),
                    colorScheme: colorScheme,
                  ),
                ],
              ).animate().fadeIn(delay: 150.ms, duration: 300.ms).slideX(begin: 0.05),

              // 5. Automation & Scheduling
              _SettingsSection(
                title: 'Automation & Scheduling',
                icon: Icons.auto_mode,
                children: [
                  _SettingNavItem(
                    icon: Icons.schedule,
                    title: 'Scheduled downloads',
                    subtitle: 'Set time windows for downloads',
                    colorScheme: colorScheme,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const ScheduleSettingsScreen(),
                        ),
                      );
                    },
                  ),
                  _SettingNavItem(
                    icon: Icons.visibility_outlined,
                    title: 'Observed Sources',
                    subtitle: 'Monitor channels and playlists for automated downloads',
                    colorScheme: colorScheme,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const ObservedSourcesScreen(),
                        ),
                      );
                    },
                  ),
                  _SettingNavItem(
                    icon: Icons.terminal,
                    title: 'Custom download commands',
                    subtitle: 'Custom yt-dlp argument templates',
                    colorScheme: colorScheme,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const CommandTemplatesScreen(),
                        ),
                      );
                    },
                  ),
                ],
              ).animate().fadeIn(delay: 200.ms, duration: 300.ms).slideX(begin: 0.05),

              // 6. Accounts & Authentication
              _SettingsSection(
                title: 'Accounts & Authentication',
                icon: Icons.security,
                children: [
                  _SettingNavItem(
                    icon: Icons.cookie_outlined,
                    title: 'Logins for members-only videos',
                    subtitle: 'Site logins for members-only content',
                    colorScheme: colorScheme,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const CookiesScreen(),
                        ),
                      );
                    },
                  ),
                ],
              ).animate().fadeIn(delay: 250.ms, duration: 300.ms).slideX(begin: 0.05),

              // 7. Packages
              Padding(
                padding: const EdgeInsets.only(top: 24, bottom: 8),
                child: Text(
                  'Packages',
                  style: textTheme.titleMedium?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _PackagesSection(
                colorScheme: colorScheme,
                textTheme: textTheme,
              ).animate().fadeIn(delay: 280.ms, duration: 300.ms).slideX(begin: 0.05),
              _SettingNavItem(
                icon: Icons.refresh_outlined,
                title: 'Update channel',
                subtitle: settings.updateChannel,
                colorScheme: colorScheme,
                onTap: () async {
                  final picked = await showDialog<String>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                      title: const Text('Update channel'),
                      content: RadioGroup<String>(
                        groupValue: settings.updateChannel,
                        onChanged: (v) => Navigator.pop(ctx, v),
                        child: const Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            RadioListTile<String>(
                              title: Text('stable'),
                              value: 'stable',
                            ),
                            RadioListTile<String>(
                              title: Text('nightly'),
                              value: 'nightly',
                            ),
                            RadioListTile<String>(
                              title: Text('master'),
                              value: 'master',
                            ),
                          ],
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Cancel'),
                        ),
                      ],
                    ),
                  );
                  if (picked != null && context.mounted) {
                    ref
                        .read(settingsProvider.notifier)
                        .setUpdateChannel(picked);
                    try {
                      await ref.read(engineProvider).setUpdateChannel(picked);
                    } catch (_) {}
                  }
                },
              ).animate().fadeIn(delay: 285.ms, duration: 300.ms).slideX(begin: 0.05),

              // 8. System & Diagnostics
              _SettingsSection(
                title: 'System & Diagnostics',
                icon: Icons.info_outline,
                children: [
                  _SettingSwitch(
                    icon: Icons.bug_report,
                    title: 'Detailed engine logging',
                    subtitle: 'Record extra engine detail for troubleshooting',
                    value: settings.verbose,
                    onChanged: () =>
                        ref.read(settingsProvider.notifier).toggleVerbose(),
                    colorScheme: colorScheme,
                  ),
                  _SettingNavItem(
                    icon: Icons.bug_report_outlined,
                    title: 'App logs & diagnostics',
                    subtitle: 'View, export, delete, or report app logs',
                    colorScheme: colorScheme,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const LogViewerScreen(),
                        ),
                      );
                    },
                  ),
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
                  ),
                ],
              ).animate().fadeIn(delay: 300.ms, duration: 300.ms).slideX(begin: 0.05),
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

class _SettingsSection extends StatelessWidget {
  final String title;
  final IconData? icon;
  final List<Widget> children;

  const _SettingsSection({
    required this.title,
    this.icon,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
            child: Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 18, color: colorScheme.primary),
                  const SizedBox(width: 8),
                ],
                Text(
                  title,
                  style: textTheme.titleMedium?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: colorScheme.outlineVariant.withValues(alpha: 0.25),
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      thickness: 1,
                      indent: 56,
                      endIndent: 16,
                      color: colorScheme.outlineVariant.withValues(alpha: 0.15),
                    ),
                  children[i],
                ],
              ],
            ),
          ),
        ],
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
      child: InkWell(
        onTap: onChanged,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
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
  final Widget? trailing;

  const _SettingNavItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.colorScheme,
    this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Semantics(
      button: true,
      label: '$title, $subtitle',
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                    const SizedBox(height: 2),
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
              const SizedBox(width: 8),
              Semantics(
                label: 'Navigate',
                child: trailing ??
                    Icon(Icons.chevron_right, color: colorScheme.outline, size: 20),
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
  final String? subtitle;
  final VoidCallback? onTap;
  final ColorScheme colorScheme;

  const _SettingAction({
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Semantics(
      button: true,
      label: title,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Semantics(
            label: 'aria2c connections',
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
                Text('aria2c connections', style: textTheme.bodyLarge),
                Text(
                  '$chunks connections',
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Semantics(
            label: 'aria2c speed limit',
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
                Text('aria2c speed limit', style: textTheme.bodyLarge),
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                underline: const SizedBox.shrink(),
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

/// Background-download permissions (Android): battery exemption so Doze
/// doesn't kill downloads, and notification permission for completion
/// alerts. Desktop builds report unsupported and hide the actions.
class _BackgroundPermissionsSection extends ConsumerStatefulWidget {
  const _BackgroundPermissionsSection();

  @override
  ConsumerState<_BackgroundPermissionsSection> createState() =>
      _BackgroundPermissionsSectionState();
}

class _BackgroundPermissionsSectionState
    extends ConsumerState<_BackgroundPermissionsSection> {
  bool? _exempt;
  bool? _notifGranted;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final engine = ref.read(engineProvider);
    final bat = await engine.batteryExemptionStatus();
    final notif = await engine.notificationPermissionStatus();
    if (!mounted) return;
    setState(() {
      final b = bat['exempt'];
      _exempt = b is bool ? b : null;
      final g = notif['granted'];
      _notifGranted = g is bool ? g : null;
    });
  }

  Future<void> _run(Future<Map<String, dynamic>> Function() call) async {
    setState(() => _working = true);
    try {
      await call();
    } catch (_) {}
    await _refresh();
    if (mounted) setState(() => _working = false);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // Desktop/mock report unsupported (null states) — hide the section.
    if (_exempt == null && _notifGranted == null && !_working) {
      return const SizedBox.shrink();
    }
    final engine = ref.read(engineProvider);
    return Column(
      children: [
        _SettingNavItem(
          icon: Icons.battery_charging_full_outlined,
          title: 'Unrestricted background',
          subtitle: _exempt == true
              ? 'Allowed — downloads survive in background'
              : 'Needed so Android doesn\'t pause downloads',
          colorScheme: colorScheme,
          trailing: _exempt == true
              ? Icon(Icons.check_circle, color: colorScheme.tertiary)
              : null,
          onTap: _working
              ? () {}
              : () => _run(engine.requestBatteryExemption),
        ),
        _SettingNavItem(
          icon: Icons.notifications_outlined,
          title: 'Notifications',
          subtitle: _notifGranted == true
              ? 'Allowed'
              : 'Needed for download and completion alerts',
          colorScheme: colorScheme,
          trailing: _notifGranted == true
              ? Icon(Icons.check_circle, color: colorScheme.tertiary)
              : null,
          onTap: _working
              ? () {}
              : () => _run(engine.requestNotificationPermission),
        ),
      ],
    );
  }
}

class _PackagesSection extends ConsumerWidget {
  final ColorScheme colorScheme;
  final TextTheme textTheme;

  const _PackagesSection({
    required this.colorScheme,
    required this.textTheme,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statusAsync = ref.watch(engineStatusProvider);
    final isWorking = statusAsync.isLoading || statusAsync.isRefreshing;

    return statusAsync.when(
      loading: () => const BootstrapStatusCard(),
      error: (err, _) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'Engine unavailable: $err',
          style: textTheme.bodySmall?.copyWith(color: colorScheme.error),
        ),
      ),
      data: (status) {
        if (status.error != null) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              children: [
                Text(
                  status.error!,
                  style: textTheme.bodySmall?.copyWith(color: colorScheme.error),
                ),
                const SizedBox(height: 8),
                _buildRebootstrapAllButton(ref),
              ],
            ),
          );
        }

        BinaryStatus lookup(String name, BinaryStatus fallback) {
          if (status.binaries.isEmpty) return fallback;
          return status.binaries.firstWhere(
            (b) => b.name == name,
            orElse: () => fallback,
          );
        }

        final ytDlp = lookup(
            'yt-dlp',
            BinaryStatus(
                name: 'yt-dlp',
                ok: status.ytDlpVersion != null,
                version: status.ytDlpVersion));
        final ffmpeg = lookup(
            'ffmpeg',
            BinaryStatus(
                name: 'ffmpeg',
                ok: status.ffmpegOk,
                version: status.ffmpegVersion));
        final aria2c = lookup(
            'aria2c',
            BinaryStatus(
                name: 'aria2c',
                ok: status.aria2cOk,
                version: status.aria2cVersion));
        final jsName = status.jsRuntime != null && status.jsRuntime != 'none'
            ? status.jsRuntime!
            : (Platform.isAndroid ? 'QuickJS' : 'Deno');
        final jsRecord = lookup(
            jsName,
            BinaryStatus(
                name: jsName,
                ok: status.jsRuntimeOk,
                version: status.jsRuntimeOk ? status.jsRuntimeVersion : null));

        final packages = [
          _SettingsBinaryInfo(
            name: 'yt-dlp',
            ok: ytDlp.ok,
            version: ytDlp.version,
            source: ytDlp.source,
            detail: ytDlp.detail ?? 'Core media extraction engine (Python package)',
            actionable: ytDlp.isActionable,
          ),
          _SettingsBinaryInfo(
            name: 'FFmpeg',
            ok: ffmpeg.ok,
            version: ffmpeg.version,
            source: ffmpeg.source,
            detail: ffmpeg.detail ?? 'Media processor for audio/video muxing and encoding',
            actionable: ffmpeg.isActionable,
          ),
          _SettingsBinaryInfo(
            name: 'aria2c',
            ok: aria2c.ok || Platform.isAndroid,
            version: aria2c.version ?? (Platform.isAndroid ? 'Compiled v1.37.0' : null),
            source: Platform.isAndroid ? 'bundled' : aria2c.source,
            detail: Platform.isAndroid
                ? 'Compiled static native downloader (bundled execution)'
                : (aria2c.detail ?? 'Multi-connection accelerated downloader'),
            actionable: !Platform.isAndroid && aria2c.isActionable,
          ),
          _SettingsBinaryInfo(
            name: 'Deno',
            ok: jsRecord.ok,
            version: jsRecord.version,
            source: jsRecord.source,
            detail: jsRecord.detail ?? 'JavaScript runtime for signature deciphering & extractors',
            actionable: jsRecord.isActionable,
          ),
        ];

        return Container(
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: colorScheme.outlineVariant.withAlpha(40),
            ),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'INSTALLED PACKAGES',
                    style: textTheme.labelSmall?.copyWith(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                  Text(
                    'Tap to check',
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.outline,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ...packages.map((pkg) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => _showPackageDetails(context, ref, pkg, colorScheme, textTheme),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                      child: Row(
                        children: [
                          Icon(
                            pkg.ok
                                ? Icons.check_circle
                                : (pkg.optional ? Icons.hourglass_empty : Icons.cancel),
                            size: 18,
                            color: pkg.ok
                                ? colorScheme.tertiary
                                : (pkg.optional ? colorScheme.outline : colorScheme.error),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  pkg.name,
                                  style: textTheme.bodyMedium?.copyWith(
                                    color: colorScheme.onSurface,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (pkg.version != null)
                                  Text(
                                    pkg.version!,
                                    style: textTheme.mono.copyWith(
                                      color: colorScheme.outline,
                                      fontSize: 11,
                                    ),
                                  )
                                else
                                  Text(
                                    pkg.ok
                                        ? 'Installed'
                                        : (pkg.optional ? 'Optional' : 'Not installed'),
                                    style: textTheme.mono.copyWith(
                                      color: pkg.ok
                                          ? colorScheme.tertiary
                                          : colorScheme.outline,
                                      fontSize: 11,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Icon(
                            Icons.chevron_right,
                            size: 18,
                            color: colorScheme.outline.withAlpha(120),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: isWorking
                      ? null
                      : () {
                          ref.invalidate(engineStatusProvider);
                        },
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Check All Packages'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: colorScheme.primary,
                    side: BorderSide(
                      color: colorScheme.primary.withAlpha(100),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showPackageDetails(
    BuildContext context,
    WidgetRef ref,
    _SettingsBinaryInfo binary,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    // Run live checking on package tap
    ref.invalidate(engineStatusProvider);

    showModalBottomSheet(
      context: context,
      backgroundColor: colorScheme.surfaceContainerLowest,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: colorScheme.outlineVariant.withAlpha(80),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Icon(
                      binary.ok
                          ? Icons.check_circle
                          : (binary.optional ? Icons.info_outline : Icons.cancel),
                      size: 24,
                      color: binary.ok
                          ? colorScheme.tertiary
                          : (binary.optional ? colorScheme.outline : colorScheme.error),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            binary.name,
                            style: textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: colorScheme.onSurface,
                            ),
                          ),
                          Text(
                            binary.sourceLabel.isNotEmpty
                                ? 'Source: ${binary.sourceLabel}'
                                : 'Verified on this device',
                            style: textTheme.bodySmall?.copyWith(
                              color: colorScheme.outline,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: binary.ok
                            ? colorScheme.tertiaryContainer.withAlpha(60)
                            : colorScheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        binary.ok ? 'INSTALLED' : 'STATUS',
                        style: textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: binary.ok ? colorScheme.tertiary : colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: 12),
                if (binary.version != null) ...[
                  Text(
                    'DETECTED VERSION',
                    style: textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                      color: colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    binary.version!,
                    style: textTheme.mono.copyWith(
                      fontSize: 13,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                Text(
                  'PACKAGE DETAILS',
                  style: textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                    color: colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  binary.detail ?? (binary.ok ? 'Verified operational on this system.' : 'No additional diagnostic details available.'),
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      ref.invalidate(engineStatusProvider);
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Re-checked ${binary.name} status.')),
                      );
                    },
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Check Again'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: colorScheme.primaryContainer,
                      foregroundColor: colorScheme.onPrimaryContainer,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildRebootstrapAllButton(WidgetRef ref) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: () {
          ref.invalidate(engineStatusProvider);
        },
        icon: const Icon(Icons.refresh, size: 16),
        label: const Text('Re-check all packages'),
        style: OutlinedButton.styleFrom(
          foregroundColor: colorScheme.primary,
          side: BorderSide(
            color: colorScheme.primary.withAlpha(100),
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
    );
  }
}

class _SettingsBinaryInfo {
  final String name;
  final bool ok;
  final String? version;
  final String source;
  final String? detail;
  /// False for states no re-bootstrap can fix (e.g. unsupported platform).
  final bool actionable;

  const _SettingsBinaryInfo({
    required this.name,
    required this.ok,
    this.version,
    this.source = 'unknown',
    this.detail,
    this.actionable = true,
  });

  /// Neutral 'pending' instead of red 'missing' when nothing can be done.
  bool get optional => !ok && !actionable;

  String get sourceLabel {
    switch (source) {
      case 'bundled':
        return 'Bundled';
      case 'downloaded':
        return 'Downloaded';
      case 'system':
        return 'System';
      case 'runtime':
        return 'Runtime';
      case 'unsupported':
        return 'Unavailable';
      case 'missing':
        return 'Missing';
      default:
        return '';
    }
  }

  String? get subtitle {
    if (!ok && detail != null && detail!.length < 120) return detail;
    if (sourceLabel.isNotEmpty) return sourceLabel;
    return null;
  }
}

