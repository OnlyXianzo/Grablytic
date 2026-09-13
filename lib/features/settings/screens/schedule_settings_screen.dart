import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/engine/engine_provider.dart';
import '../../../providers/settings_provider.dart';

class ScheduleSettingsScreen extends ConsumerWidget {
  const ScheduleSettingsScreen({super.key});

  static const _dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Download Schedule',
          style: GoogleFonts.instrumentSans(
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SettingSwitch(
                icon: Icons.schedule,
                title: 'Enable Schedule',
                subtitle: 'Restrict downloads to specific times',
                value: settings.scheduleEnabled,
                onChanged: () => notifier.setScheduleEnabled(!settings.scheduleEnabled),
                colorScheme: colorScheme,
              ),
              const SizedBox(height: 24),
              if (settings.scheduleEnabled) ...[
                InkWell(
                  onTap: () async {
                    final parts = settings.scheduleTime.split(':');
                    final initialHour = int.tryParse(parts[0]) ?? 22;
                    final initialMinute = int.tryParse(parts[1]) ?? 0;
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay(hour: initialHour, minute: initialMinute),
                    );
                    if (picked != null && context.mounted) {
                      notifier.setScheduleTime(
                        '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}',
                      );
                    }
                  },
                  child: _SettingTile(
                    icon: Icons.access_time,
                    title: 'Schedule Time',
                    subtitle: settings.scheduleTime,
                    colorScheme: colorScheme,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Days of Week',
                  style: textTheme.titleMedium?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: List.generate(7, (i) {
                    final selected = settings.scheduleDays.contains(i + 1);
                    return ChoiceChip(
                      label: Text(
                        _dayLabels[i],
                        style: GoogleFonts.instrumentSans(
                          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                      selected: selected,
                      onSelected: (val) {
                        final days = List<int>.from(settings.scheduleDays);
                        if (val) {
                          days.add(i + 1);
                        } else {
                          days.remove(i + 1);
                        }
                        if (days.isNotEmpty) {
                          days.sort();
                          notifier.setScheduleDays(days);
                        }
                      },
                      selectedColor: colorScheme.primaryContainer,
                      backgroundColor: colorScheme.surfaceContainer,
                      labelStyle: TextStyle(color: selected ? colorScheme.onPrimaryContainer : colorScheme.onSurface),
                    );
                  }),
                ),
                const SizedBox(height: 24),
                _SettingTile(
                  icon: Icons.timer_outlined,
                  title: 'Check Cadence',
                  subtitle: _formatInterval(settings.scheduleIntervalMinutes),
                  colorScheme: colorScheme,
                  trailing: DropdownButton<int>(
                    value: settings.scheduleIntervalMinutes,
                    underline: const SizedBox.shrink(),
                    dropdownColor: colorScheme.surfaceContainerHigh,
                    items: const [
                      DropdownMenuItem(value: 15, child: Text('15 min')),
                      DropdownMenuItem(value: 30, child: Text('30 min')),
                      DropdownMenuItem(value: 60, child: Text('1 hour')),
                      DropdownMenuItem(value: 120, child: Text('2 hours')),
                      DropdownMenuItem(value: 360, child: Text('6 hours')),
                      DropdownMenuItem(value: 720, child: Text('12 hours')),
                      DropdownMenuItem(value: 1440, child: Text('24 hours')),
                    ],
                    onChanged: (v) {
                      if (v != null) notifier.setScheduleIntervalMinutes(v);
                    },
                  ),
                ),
                const SizedBox(height: 16),
                _SettingSwitch(
                  icon: Icons.wifi,
                  title: 'Wi-Fi Only',
                  subtitle: 'Only check and download on unmetered Wi-Fi',
                  value: settings.scheduleWifiOnly,
                  onChanged: () => notifier.setScheduleWifiOnly(!settings.scheduleWifiOnly),
                  colorScheme: colorScheme,
                ),
                const SizedBox(height: 16),
                _SettingSwitch(
                  icon: Icons.power,
                  title: 'Require Charging',
                  subtitle: 'Only check and download while plugged into power',
                  value: settings.scheduleRequiresCharging,
                  onChanged: () => notifier.setScheduleRequiresCharging(!settings.scheduleRequiresCharging),
                  colorScheme: colorScheme,
                ),
                const SizedBox(height: 16),
                InkWell(
                  onTap: () {
                    ref.read(engineProvider).requestBatteryExemption();
                  },
                  child: _SettingTile(
                    icon: Icons.battery_charging_full,
                    title: 'Battery Optimization',
                    subtitle: 'Configure Android battery limits for overnight reliability',
                    colorScheme: colorScheme,
                  ),
                ),
                const SizedBox(height: 24),
              ],
              Text(
                'Downloads will only start during scheduled windows',
                style: textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _formatInterval(int minutes) {
    if (minutes < 60) return '$minutes minutes';
    final hours = minutes ~/ 60;
    return hours == 1 ? '1 hour (Default)' : '$hours hours';
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

class _SettingTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final ColorScheme colorScheme;

  final Widget? trailing;

  const _SettingTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.colorScheme,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '$title, $subtitle',
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
                  Text(title, style: Theme.of(context).textTheme.bodyLarge),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            trailing ??
                Semantics(
                  label: 'Tap to change',
                  child: Icon(Icons.chevron_right, color: colorScheme.outline, size: 20),
                ),
          ],
        ),
      ),
    );
  }
}
