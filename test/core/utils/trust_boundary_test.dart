import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/utils/command_template.dart';
import 'package:grablytic/core/utils/download_config.dart';
import 'package:grablytic/core/utils/trust_boundary.dart';
import 'package:grablytic/providers/settings_provider.dart';

void main() {
  group('sanitizeProxy', () {
    test('accepts http/https/socks with host', () {
      expect(sanitizeProxy('http://proxy.test:8080'), 'http://proxy.test:8080');
      expect(sanitizeProxy('socks5h://127.0.0.1:9050'), 'socks5h://127.0.0.1:9050');
      expect(sanitizeProxy('http://user:pw@proxy.test:3128'),
          'http://user:pw@proxy.test:3128');
    });

    test('drops garbage, wrong scheme, missing host', () {
      expect(sanitizeProxy('--proxy http://evil:8080'), isNull);
      expect(sanitizeProxy('not a url'), isNull);
      expect(sanitizeProxy('ftp://proxy.test:21'), isNull);
      expect(sanitizeProxy(''), isNull);
      expect(sanitizeProxy(null), isNull);
    });
  });

  group('sanitizeExportFileName', () {
    test('strips directory components', () {
      expect(sanitizeExportFileName('../../etc/passwd'), 'passwd');
      expect(sanitizeExportFileName(r'..\windows\evil.txt'), 'evil.txt');
      expect(sanitizeExportFileName('app_logs.txt'), 'app_logs.txt');
    });

    test('falls back on empty/traversal-only input', () {
      expect(sanitizeExportFileName(''), 'export');
      expect(sanitizeExportFileName('../..'), 'export');
    });
  });

  group('sanitizeEngineFilePath', () {
    test('accepts absolute paths, rejects relative', () {
      expect(sanitizeEngineFilePath('/a/b/c.mp4'), '/a/b/c.mp4');
      expect(sanitizeEngineFilePath('../evil.mp4'), isNull);
      expect(sanitizeEngineFilePath('rel/path.mp4'), isNull);
      expect(sanitizeEngineFilePath(''), isNull);
      expect(sanitizeEngineFilePath(null), isNull);
    });
  });

  group('isPathWithinDir', () {
    test('contains inside, rejects escape', () {
      expect(isPathWithinDir('/dl/vid/a.mp4', '/dl/vid'), isTrue);
      expect(isPathWithinDir('/dl/other/a.mp4', '/dl/vid'), isFalse);
      expect(isPathWithinDir('/dl/vid/../other/a.mp4', '/dl/vid'), isFalse);
    });
  });

  group('template proxy validation', () {
    test('valid proxy applied, garbage ignored', () {
      final ok = parseTemplateConfig('--proxy http://proxy.test:8080');
      expect(ok.config.containsKey('proxy'), isFalse);
      expect(ok.ignored, contains('--proxy [use the secure Proxy setting]'));
      final bad = parseTemplateConfig('--proxy not_a_url');
      expect(bad.config.containsKey('proxy'), isFalse);
      expect(bad.ignored, isNotEmpty);
    });
  });

  group('openFileFailureMessage', () {
    test('a refused path names the folder, not a missing player', () {
      final message = openFileFailureMessage(
        '/storage/emulated/0/Old/video.mp4',
        'path outside the download folder',
      );
      expect(message, contains('outside the download folder'));
      expect(message, isNot(contains('No app can play')));
      expect(message, contains('/storage/emulated/0/Old/video.mp4'));
    });

    test('any other engine error keeps the old wording', () {
      expect(
        openFileFailureMessage('/dl/video.mp4', 'no handler'),
        'No app can play this file.\nOpen file at: /dl/video.mp4',
      );
      expect(
        openFileFailureMessage('/dl/video.mp4', null),
        contains('No app can play this file.'),
      );
      expect(
        openFileFailureMessage('/dl/video.mp4', 42),
        contains('No app can play this file.'),
      );
    });
  });

  group('settings proxy validation', () {
    test('malformed settings proxy omitted', () {
      const s = AppSettings(proxy: 'not a url');
      expect(settingsDownloadConfig(s).containsKey('proxy'), isFalse);
      const ok = AppSettings(proxy: 'http://proxy.test:8080');
      expect(settingsDownloadConfig(ok)['proxy'], 'http://proxy.test:8080');
    });
  });
}
