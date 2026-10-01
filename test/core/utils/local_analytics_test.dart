import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grablytic/core/utils/local_analytics.dart';

void main() {
  group('LocalAnalytics (T21 strictly-local dashboard)', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await LocalAnalytics.clear();
    });

    test('classifies YouTube, Instagram, and other domains', () {
      expect(LocalAnalytics.domainOf('https://youtu.be/x'), 'youtube');
      expect(
        LocalAnalytics.domainOf('https://www.youtube.com/watch?v=x'),
        'youtube',
      );
      expect(
        LocalAnalytics.domainOf('https://www.instagram.com/reel/x'),
        'instagram',
      );
      expect(LocalAnalytics.domainOf('https://example.com/v.mp4'), 'other');
    });

    test(
      'aggregates intakes, outcomes, and failures with range filter',
      () async {
        await LocalAnalytics.recordIntake(
          LocalAnalytics.kindShare,
          'https://youtu.be/a',
        );
        await LocalAnalytics.recordIntake(
          LocalAnalytics.kindPaste,
          'https://www.instagram.com/reel/b',
        );
        await LocalAnalytics.recordOutcome(
          jobId: 'j1',
          outcome: LocalAnalytics.outcomeSuccess,
          url: 'https://youtu.be/a',
          title: 'Video A',
        );
        await LocalAnalytics.recordOutcome(
          jobId: 'j2',
          outcome: LocalAnalytics.outcomeRetry,
          url: 'https://youtu.be/a',
        );
        await LocalAnalytics.recordOutcome(
          jobId: 'j3',
          outcome: LocalAnalytics.outcomeFailure,
          url: 'https://example.com/c',
          title: 'Video C',
          errorType: 'ERROR_NETWORK',
        );

        final all = await LocalAnalytics.summary();
        expect(all['shares'], 1);
        expect(all['pastes'], 1);
        expect(all['success'], 1);
        expect(all['retries'], 1);
        expect(all['failures'], 1);
        expect(all['youtube'], 3);
        expect(all['instagram'], 1);
        expect(all['other'], 1);

        final future = DateTime.now()
            .add(const Duration(days: 1))
            .millisecondsSinceEpoch;
        final empty = await LocalAnalytics.summary(sinceMs: future);
        expect(empty['total'], 0);

        final failed = await LocalAnalytics.failures();
        expect(failed.length, 1);
        expect(failed.first['jobId'], 'j3');
        expect(failed.first['errorType'], 'ERROR_NETWORK');

        await LocalAnalytics.clear();
        expect((await LocalAnalytics.summary())['total'], 0);
      },
    );

    test('incognito jobs are never recorded', () async {
      await LocalAnalytics.recordIntake(
        LocalAnalytics.kindShare,
        'https://youtu.be/x',
        incognito: true,
      );
      await LocalAnalytics.recordOutcome(
        jobId: 'j9',
        outcome: LocalAnalytics.outcomeSuccess,
        url: 'https://youtu.be/x',
        incognito: true,
      );
      expect((await LocalAnalytics.summary())['total'], 0);
    });
  });
}
