import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grablytic/core/engine/engine_provider.dart';
import 'package:grablytic/core/engine/extraction_cache.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';
import 'package:grablytic/features/home/screens/home_screen.dart';
import 'package:grablytic/features/home/screens/format_picker_screen.dart';
import 'package:grablytic/features/settings/screens/presets_screen.dart';
import 'package:grablytic/providers/download_provider.dart';
import 'package:grablytic/providers/resume_provider.dart';
import 'package:grablytic/providers/settings_provider.dart';

class _NoopResumeNotifier extends ResumeNotifier {
  _NoopResumeNotifier(super.ref);

  @override
  Future<void> scan() async {
    state = const AsyncValue.data([]);
  }
}

Future<void> _pumpHome(
  WidgetTester tester,
  SharedPreferences prefs,
  MockEngineService engine, {
  List<DownloadItem> items = const [],
  VoidCallback? onSeeAll,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        engineProvider.overrideWithValue(engine),
        resumeProvider.overrideWith((ref) => _NoopResumeNotifier(ref)),
        downloadProvider.overrideWith((ref) {
          final notifier = DownloadNotifier(engine);
          for (final item in items) {
            notifier.addDownload(item);
          }
          return notifier;
        }),
      ],
      child: MaterialApp(
        home: HomeScreen(onSeeAll: onSeeAll),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (MethodCall call) async {
        if (call.method == 'check') return ['wifi'];
        return null;
      },
    );
  });

  setUp(() => ExtractionCache.instance.clear());

  group('Home P4-3 fidelity (hero + pill + opts + sections)', () {
    testWidgets('hero shows brand row and headline, Download submits URL',
        (tester) async {
      SharedPreferences.setMockInitialValues({'onboardingCompleted': true});
      final prefs = await SharedPreferences.getInstance();
      await _pumpHome(tester, prefs, MockEngineService());
      expect(find.text('Save video and audio for offline.'), findsOneWidget);
      expect(find.text('Download'), findsOneWidget);
      await tester.enterText(find.byType(TextField),
          'https://www.youtube.com/watch?v=dQw4w9WgXcQ');
      await tester.pump();
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      expect(find.byType(FormatPickerScreen), findsOneWidget);
    });

    testWidgets('opts tiles show real defaults and navigate', (tester) async {
      SharedPreferences.setMockInitialValues({
        'onboardingCompleted': true,
        'audioOnly': true,
        'qualityCeiling': '720p',
        'downloadPath': '/storage/emulated/0/Download/Grablytic',
      });
      final prefs = await SharedPreferences.getInstance();
      await _pumpHome(tester, prefs, MockEngineService());
      expect(find.text('Audio'), findsOneWidget);
      expect(find.text('720p'), findsOneWidget);
      expect(find.text('Grablytic'), findsWidgets);
      await tester.tap(find.text('720p'));
      await tester.pumpAndSettle();
      expect(find.byType(PresetsScreen), findsOneWidget);
    });

    testWidgets('downloading and recent sections render with See-all',
        (tester) async {
      SharedPreferences.setMockInitialValues({'onboardingCompleted': true});
      final prefs = await SharedPreferences.getInstance();
      var seenAll = false;
      await _pumpHome(
        tester,
        prefs,
        MockEngineService(),
        items: [
          DownloadItem(
            id: 'dl-1',
            title: 'Live One',
            url: 'https://example.com/1',
            status: 'downloading',
            progress: 0.2,
          ),
          DownloadItem(
            id: 'dl-2',
            title: 'Done One',
            url: 'https://example.com/2',
            status: 'completed',
          ),
        ],
        onSeeAll: () => seenAll = true,
      );
      expect(find.text('Downloading'), findsOneWidget);
      expect(find.text('Live One'), findsOneWidget);
      expect(find.text('Recent'), findsOneWidget);
      expect(find.text('Done One'), findsOneWidget);
      await tester.ensureVisible(find.text('See all'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('See all'));
      await tester.pumpAndSettle();
      expect(seenAll, isTrue);
    });

    testWidgets('tactile progress groove and calibrated telemetry rows render properly',
        (tester) async {
      SharedPreferences.setMockInitialValues({'onboardingCompleted': true});
      final prefs = await SharedPreferences.getInstance();
      await _pumpHome(
        tester,
        prefs,
        MockEngineService(),
        items: [
          DownloadItem(
            id: 'dl-test',
            title: 'Live Stream',
            url: 'https://example.com/test',
            status: 'downloading',
            progress: 0.45,
            downloadedBytes: 45000000,
            totalBytes: 100000000,
            speed: 5242880,
            eta: 125,
          ),
        ],
      );

      // Verify tactile progress groove container
      final progressFinder = find.byType(LinearProgressIndicator);
      expect(progressFinder, findsOneWidget);
      final lpi = tester.widget<LinearProgressIndicator>(progressFinder);
      expect(
        (lpi.valueColor as AlwaysStoppedAnimation<Color>).value,
        const Color(0xFF8B3A26),
      );
      expect(lpi.backgroundColor, const Color(0xFFE8DFD5));
      expect(lpi.borderRadius, BorderRadius.circular(2.5));

      final containerFinder = find.ancestor(
        of: progressFinder,
        matching: find.byType(Container),
      ).first;
      final container = tester.widget<Container>(containerFinder);
      expect(container.constraints?.maxHeight, 5.0);
      final decoration = container.decoration as BoxDecoration;
      expect(decoration.color, const Color(0xFFE8DFD5));
      expect(decoration.borderRadius, BorderRadius.circular(2.5));
      expect(decoration.border?.top.color, const Color(0xFFDDD2C6));
      expect(decoration.border?.top.width, 0.5);

      // Verify telemetry row 1
      expect(find.text('43 MB / 95 MB'), findsOneWidget);
      final pctFinder = find.text('45%');
      expect(pctFinder, findsOneWidget);
      final pctText = tester.widget<Text>(pctFinder);
      expect(pctText.style?.color, const Color(0xFF8B3A26));
      expect(pctText.style?.fontFamily, 'IosevkaCharonMono');
      expect(pctText.style?.fontWeight, FontWeight.bold);
      expect(pctText.style?.fontFeatures?.any((f) => f.feature == 'tnum'), isTrue);

      // Verify telemetry row 2
      final speedFinder = find.text('↓ 5.0 MB/s');
      expect(speedFinder, findsOneWidget);
      final speedText = tester.widget<Text>(speedFinder);
      expect(speedText.style?.color, const Color(0xFF8B3A26));
      expect(speedText.style?.fontFamily, 'IosevkaCharonMono');
      expect(speedText.style?.fontWeight, FontWeight.bold);
      expect(speedText.style?.fontFeatures?.any((f) => f.feature == 'tnum'), isTrue);

      final etaFinder = find.text('ETA 02:05');
      expect(etaFinder, findsOneWidget);
      final etaText = tester.widget<Text>(etaFinder);
      expect(etaText.style?.color, const Color(0xFF7A6E64));
      expect(etaText.style?.fontFamily, 'IosevkaCharonMono');
      expect(etaText.style?.fontFeatures?.any((f) => f.feature == 'tnum'), isTrue);
    });

    testWidgets('Grab button uses primary signal color 0xFF8B3A26',
        (tester) async {
      SharedPreferences.setMockInitialValues({'onboardingCompleted': true});
      final prefs = await SharedPreferences.getInstance();
      await _pumpHome(tester, prefs, MockEngineService());

      final buttonFinder = find.byWidgetPredicate(
        (w) => w is Material && w.color == const Color(0xFF8B3A26),
      );
      expect(buttonFinder, findsWidgets);
    });
  });
}
