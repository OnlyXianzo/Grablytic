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
  });
}
