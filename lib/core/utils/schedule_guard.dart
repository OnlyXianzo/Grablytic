import '../../providers/settings_provider.dart';

/// Minutes in a day, for wrapping a window past midnight.
const _minutesPerDay = 24 * 60;

/// Schedule window guard (pure, unit-tested).
///
/// When the schedule is enabled, downloads may start on
/// [AppSettings.scheduleDays] (DateTime.weekday numbers, Mon=1..Sun=7) in
/// the window that opens at [AppSettings.scheduleTime] (`HH:MM`, 24h) and
/// stays open for [AppSettings.scheduleWindowMinutes].
///
/// A window that runs past midnight covers the early hours of the NEXT day:
/// `22:00` for 240 minutes is open from 02:00 on the day AFTER a scheduled
/// day as well. The previous rule had no end at all — it compared the clock
/// against the start time only, so a 22:00 schedule was open until midnight
/// and then closed, which is not what "run overnight" means to anyone.
///
/// Anything else is "outside the window" and the caller should confirm with
/// the user instead of starting silently.
bool isWithinScheduleWindow(AppSettings settings, DateTime now) {
  if (!settings.scheduleEnabled) return true;
  final parts = settings.scheduleTime.split(':');
  if (parts.length != 2) return true; // malformed stored value: fail open
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) return true;

  final startMinutes = h * 60 + m;
  final duration = settings.scheduleWindowMinutes;
  // A degenerate window is a config error, not a reason to block.
  if (duration >= _minutesPerDay) return true;
  if (duration <= 0) return settings.scheduleDays.contains(now.weekday);

  final nowMinutes = now.hour * 60 + now.minute;
  final elapsed = (nowMinutes - startMinutes + _minutesPerDay) % _minutesPerDay;
  final inWindow = elapsed < duration;
  if (!inWindow) return false;

  // A window that spilled past midnight belongs to the PREVIOUS day's
  // schedule entry, so check that day instead.
  final windowDay = nowMinutes >= startMinutes
      ? now.weekday
      : (now.weekday == DateTime.monday ? DateTime.sunday : now.weekday - 1);
  return settings.scheduleDays.contains(windowDay);
}

/// Short human summary for dialogs, e.g. "Sat, Sun from 22:00".
String scheduleSummary(AppSettings settings) {
  const names = {1: 'Mon', 2: 'Tue', 3: 'Wed', 4: 'Thu', 5: 'Fri', 6: 'Sat', 7: 'Sun'};
  final days = settings.scheduleDays.map((d) => names[d] ?? '?').join(', ');
  return '$days from ${settings.scheduleTime}';
}
