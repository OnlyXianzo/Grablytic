import 'package:flutter_test/flutter_test.dart';
import 'package:truestream/core/utils/download_config.dart';
import 'package:truestream/providers/settings_provider.dart';

void main() {
  group('settingsDownloadConfig (P1 shared overlay)', () {
    test('maps settings to exact engine keys', () {
      const s = AppSettings(
        downloadSubtitles: true,
        subtitleLanguages: ['en', 'hi'],
        downloadAutoSubtitles: true,
        embedSubtitles: false,
        sponsorBlockCats: ['sponsor', 'intro'],
        aria2cEnabled: true,
        aria2cChunks: 8,
        splitChapters: true,
        saveDescription: true,
      );
      final cfg = settingsDownloadConfig(s);
      expect(cfg['writesubtitles'], isTrue);
      expect(cfg['writeautomaticsub'], isTrue);
      expect(cfg['subtitleslangs'], ['en', 'hi']);
      expect(cfg['embedsubtitles'], isFalse);
      expect(cfg['sponsorblock_cats'], ['sponsor', 'intro']);
      expect(cfg['aria2c_enabled'], isTrue);
      expect(cfg['aria2c_chunks'], 8);
      expect(cfg['split_chapters'], isTrue);
      expect(cfg['write_description'], isTrue);
    });

    test('drops null/empty proxy and speed so engine defaults survive', () {
      const s = AppSettings();
      final cfg = settingsDownloadConfig(s);
      expect(cfg.containsKey('proxy'), isFalse);
      expect(cfg.containsKey('aria2c_max_speed'), isFalse);
      const s2 = AppSettings(proxy: '  ', aria2cMaxSpeed: '');
      final cfg2 = settingsDownloadConfig(s2);
      expect(cfg2.containsKey('proxy'), isFalse);
      expect(cfg2.containsKey('aria2c_max_speed'), isFalse);
    });

    test('trims and forwards non-empty proxy and speed', () {
      const s = AppSettings(proxy: ' http://p:8080 ', aria2cMaxSpeed: '5M');
      final cfg = settingsDownloadConfig(s);
      expect(cfg['proxy'], 'http://p:8080');
      expect(cfg['aria2c_max_speed'], '5M');
    });

    test('copyWith keeps templates and schedule fields (state bug)', () {
      const s = AppSettings();
      final next = s.copyWith(
        customTemplates: ['--write-sub'],
        scheduleEnabled: true,
        scheduleTime: '23:00',
        scheduleDays: [6, 7],
      );
      expect(next.customTemplates, ['--write-sub']);
      expect(next.scheduleEnabled, isTrue);
      expect(next.scheduleTime, '23:00');
      expect(next.scheduleDays, [6, 7]);
    });
  });
}
