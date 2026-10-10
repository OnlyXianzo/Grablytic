import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/engine/engine_provider.dart';
import 'package:grablytic/core/engine/extraction_cache.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';
import 'package:grablytic/core/utils/offline_link_queue.dart';
import 'package:grablytic/features/home/screens/home_screen.dart';
import 'package:grablytic/features/home/screens/format_picker_screen.dart';
import 'package:grablytic/features/home/screens/search_results_screen.dart';
import 'package:grablytic/features/shell/screens/app_shell.dart';
import 'package:grablytic/providers/engine_status_provider.dart';
import 'package:grablytic/providers/resume_provider.dart';
import 'package:grablytic/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NoScan extends ResumeNotifier {
  _NoScan(super.ref);
  @override
  Future<void> scan() async => state = const AsyncValue.data([]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const connectivity = MethodChannel('dev.fluttercommunity.plus/connectivity');
  const url = 'https://example.com/video';
  late ProviderContainer container;
  late MockEngineService engine;
  String? clipboard;
  var online = true;
  var reads = 0;

  setUp(() {
    clipboard = null;
    online = true;
    reads = 0;
    engine = MockEngineService();
    ExtractionCache.instance.clear();
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        reads++;
        return clipboard == null ? null : {'text': clipboard};
      }
      return null;
    });
    messenger.setMockMethodCallHandler(
      connectivity,
      (call) async =>
          call.method == 'check' ? [online ? 'wifi' : 'none'] : null,
    );
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockMethodCallHandler(connectivity, null);
    engine.dispose();
    ExtractionCache.instance.clear();
  });

  Future<void> pumpEntry(WidgetTester tester, {bool shell = false}) async {
    SharedPreferences.setMockInitialValues({
      'onboardingCompleted': true,
      'hasSeenBatteryPrompt': true,
    });
    final prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        engineProvider.overrideWithValue(engine),
        engineStatusProvider.overrideWith(
          (ref) async => const EngineStatus(ready: true),
        ),
        resumeProvider.overrideWith((ref) => _NoScan(ref)),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: shell ? const AppShell() : const HomeScreen()),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
  }

  testWidgets('empty Home input extracts the first URL from clipboard prose', (
    tester,
  ) async {
    clipboard = 'Watch $url or https://example.com/second';
    await pumpEntry(tester);
    await tester.tap(find.text('Grab'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<FormatPickerScreen>(find.byType(FormatPickerScreen)).url,
      url,
    );
    expect(reads, 1);
  });

  testWidgets('explicit Home input takes priority over clipboard', (
    tester,
  ) async {
    clipboard = 'https://example.com/ignored';
    await pumpEntry(tester);
    await tester.enterText(find.byType(TextField), url);
    await tester.tap(find.text('Grab'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<FormatPickerScreen>(find.byType(FormatPickerScreen)).url,
      url,
    );
    expect(reads, 0);
  });

  testWidgets('clipboard text without a URL becomes a search query', (
    tester,
  ) async {
    clipboard = 'nature documentary';
    await pumpEntry(tester);
    await tester.tap(find.text('Grab'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SearchResultsScreen>(find.byType(SearchResultsScreen))
          .initialQuery,
      clipboard,
    );
  });

  for (final text in [null, '   ', 'x']) {
    testWidgets('unusable clipboard $text leaves Home open', (tester) async {
      clipboard = text;
      await pumpEntry(tester);
      await tester.tap(find.text('Grab'));
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(FormatPickerScreen), findsNothing);
      expect(find.byType(SearchResultsScreen), findsNothing);
      expect(container.read(offlineQueueProvider), isEmpty);
    });
  }

  testWidgets('offline clipboard submission saves once and clears the input', (
    tester,
  ) async {
    online = false;
    clipboard = url;
    await pumpEntry(tester);
    await tester.tap(find.text('Grab'));
    await tester.pumpAndSettle();
    expect(container.read(offlineQueueProvider).single.url, url);
    expect(container.read(offlineQueueProvider).single.source, 'paste');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    await tester.tap(find.text('Grab'));
    await tester.pumpAndSettle();
    expect(container.read(offlineQueueProvider), hasLength(1));
    expect(find.byType(FormatPickerScreen), findsNothing);
  });

  testWidgets(
    'startup clipboard waits for the delay, then offers Paste online',
    (tester) async {
      clipboard = 'Watch $url';
      await pumpEntry(tester, shell: true);
      expect(reads, 0);
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();
      expect(find.text('Clipboard link found: $url'), findsOneWidget);
      expect(container.read(offlineQueueProvider), isEmpty);
      await tester.tap(find.text('Paste'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        url,
      );
    },
  );

  testWidgets(
    'startup queues offline clipboard links and resume does not duplicate',
    (tester) async {
      online = false;
      clipboard = url;
      await pumpEntry(tester, shell: true);
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();
      expect(container.read(offlineQueueProvider).single.url, url);
      expect(container.read(offlineQueueProvider).single.source, 'clipboard');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(container.read(offlineQueueProvider), hasLength(1));
    },
  );

  testWidgets('disposing AppShell cancels its pending clipboard check', (
    tester,
  ) async {
    clipboard = url;
    await pumpEntry(tester, shell: true);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(reads, 0);
    expect(tester.takeException(), isNull);
  });
}
