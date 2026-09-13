import 'package:flutter_test/flutter_test.dart';
import 'package:truestream/core/utils/command_template.dart';
import 'package:truestream/core/utils/schedule_guard.dart';
import 'package:truestream/providers/settings_provider.dart';

void main() {
  group('parseTemplateConfig (safe subset)', () {
    test('maps subtitle + embed + sponsorblock flags', () {
      final p = parseTemplateConfig('--write-subs --sub-langs en,hi --embed-subs --sponsorblock-remove sponsor,intro');
      expect(p.config['writesubtitles'], isTrue);
      expect(p.config['subtitleslangs'], ['en', 'hi']);
      expect(p.config['embedsubtitles'], isTrue);
      expect(p.config['sponsorblock_cats'], ['sponsor', 'intro']);
      expect(p.ignored, isEmpty);
    });

    test('sub-langs implies write-subs; no- flags win explicitly', () {
      final p = parseTemplateConfig('--sub-langs en');
      expect(p.config['writesubtitles'], isTrue);
      final q = parseTemplateConfig('--sub-langs en --no-write-subs');
      expect(q.config['writesubtitles'], isFalse);
    });

    test('container clamped to safe token; network flags parsed', () {
      final p = parseTemplateConfig('--merge-output-format mp4 --concurrent-fragments 8 --socket-timeout 15 --proxy http://p:8080 --limit-rate 5M');
      expect(p.config['container'], 'mp4');
      expect(p.config['concurrent_fragments'], 8);
      expect(p.config['socket_timeout'], 15);
      expect(p.config['proxy'], 'http://p:8080');
      expect(p.config['rate_limit'], '5M');
    });

    test('unknown and unsafe values land in ignored, never config', () {
      final p = parseTemplateConfig('--write-description --do-anything --merge-output-format ../../x');
      expect(p.config['write_description'], isTrue);
      expect(p.config.containsKey('container'), isFalse);
      expect(p.ignored, contains('--do-anything'));
    });

    test('quoted values tokenize intact', () {
      final p = parseTemplateConfig('--proxy "http://p:8080/x y"');
      expect(p.config['proxy'], 'http://p:8080/x y');
    });
  });

  group('isWithinScheduleWindow', () {
    test('disabled schedule always allows', () {
      const s = AppSettings(scheduleEnabled: false);
      expect(isWithinScheduleWindow(s, DateTime(2026, 9, 12, 3, 0)), isTrue);
    });

    test('wrong day blocks; right day before/after time', () {
      // 2026-09-12 is a Saturday (weekday 6).
      const s = AppSettings(scheduleEnabled: true, scheduleTime: '22:00', scheduleDays: [6]);
      expect(isWithinScheduleWindow(s, DateTime(2026, 9, 12, 21, 59)), isFalse);
      expect(isWithinScheduleWindow(s, DateTime(2026, 9, 12, 22, 0)), isTrue);
      const s2 = AppSettings(scheduleEnabled: true, scheduleTime: '22:00', scheduleDays: [1]);
      expect(isWithinScheduleWindow(s2, DateTime(2026, 9, 12, 23, 0)), isFalse);
    });

    test('malformed time fails open, never blocks', () {
      const s = AppSettings(scheduleEnabled: true, scheduleTime: 'xx', scheduleDays: [6]);
      expect(isWithinScheduleWindow(s, DateTime(2026, 9, 12, 3, 0)), isTrue);
    });
  });

  group('Schedule settings & summary', () {
    test('default scheduler settings', () {
      const s = AppSettings();
      expect(s.scheduleEnabled, isFalse);
      expect(s.scheduleTime, '22:00');
      expect(s.scheduleDays, [1, 2, 3, 4, 5]);
      expect(s.scheduleIntervalMinutes, 60);
      expect(s.scheduleWifiOnly, isTrue);
      expect(s.scheduleRequiresCharging, isFalse);
    });

    test('copyWith updates scheduler settings', () {
      const s = AppSettings();
      final updated = s.copyWith(
        scheduleEnabled: true,
        scheduleTime: '01:30',
        scheduleDays: [6, 7],
        scheduleIntervalMinutes: 30,
        scheduleWifiOnly: false,
        scheduleRequiresCharging: true,
      );
      expect(updated.scheduleEnabled, isTrue);
      expect(updated.scheduleTime, '01:30');
      expect(updated.scheduleDays, [6, 7]);
      expect(updated.scheduleIntervalMinutes, 30);
      expect(updated.scheduleWifiOnly, isFalse);
      expect(updated.scheduleRequiresCharging, isTrue);
    });

    test('scheduleSummary formats day names and time', () {
      const s = AppSettings(
        scheduleDays: [6, 7],
        scheduleTime: '23:00',
      );
      expect(scheduleSummary(s), 'Sat, Sun from 23:00');
    });
  });
}
