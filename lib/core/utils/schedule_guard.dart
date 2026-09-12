import '../../providers/settings_provider.dart';

/// Schedule window guard (pure, unit-tested).
///
/// Semantics (documented in Settings UI): when the schedule is enabled,
/// downloads may start on [AppSettings.scheduleDays] (DateTime.weekday
/// numbers, Mon=1..Sun=7) at or after [AppSettings.scheduleTime]
/// (`HH:MM`, 24h). Anything else is "outside the window" and the caller
/// should confirm with the user instead of starting silently.
bool isWithinScheduleWindow(AppSettings settings, DateTime now) {
  if (!settings.scheduleEnabled) return true;
  if (!settings.scheduleDays.contains(now.weekday)) return false;
  final parts = settings.scheduleTime.split(':');
  if (parts.length != 2) return true; // malformed stored value: fail open
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) return true;
  final startMinutes = h * 60 + m;
  return now.hour * 60 + now.minute >= startMinutes;
}

/// Short human summary for dialogs, e.g. "Sat, Sun from 22:00".
String scheduleSummary(AppSettings settings) {
  const names = {1: 'Mon', 2: 'Tue', 3: 'Wed', 4: 'Thu', 5: 'Fri', 6: 'Sat', 7: 'Sun'};
  final days = settings.scheduleDays.map((d) => names[d] ?? '?').join(', ');
  return '$days from ${settings.scheduleTime}';
}
