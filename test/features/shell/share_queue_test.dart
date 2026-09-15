import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grablytic/core/engine/engine_provider.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';
import 'package:grablytic/features/shell/screens/app_shell.dart';
import 'package:grablytic/providers/resume_provider.dart';
import 'package:grablytic/providers/settings_provider.dart';

/// Scripted engine: queued cold-start URLs + a controllable live stream.
class _QueuedShareEngine extends MockEngineService {
  final List<String?> coldStarts;
  final StreamController<String> live = StreamController<String>.broadcast();

  _QueuedShareEngine(this.coldStarts);

  @override
  Future<String?> getSharedUrl() async =>
      coldStarts.isEmpty ? null : coldStarts.removeAt(0);

  @override
  Stream<String> get sharedUrlStream => live.stream;
}

class _NoopResumeNotifier extends ResumeNotifier {
  _NoopResumeNotifier(super.ref);

  @override
  Future<void> scan() async {
    state = const AsyncValue.data([]);
  }
}

Future<void> _pumpShell(
  WidgetTester tester, {
  required MockEngineService engine,
}) async {
  SharedPreferences.setMockInitialValues({
    'onboardingCompleted': true,
    'hasSeenBatteryPrompt': true,
  });
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        engineProvider.overrideWithValue(engine),
        resumeProvider.overrideWith((ref) => _NoopResumeNotifier(ref)),
      ],
      child: const MaterialApp(home: AppShell()),
    ),
  );
  // Explicit frames first: the cold-start drain runs in a post-frame
  // callback with async gaps that settle-alone can miss.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pumpAndSettle();
}

const _url1 = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ';
const _url2 = 'https://www.youtube.com/watch?v=9bZkp7q19f0';

void main() {
  group('T2-6 share queue (Dart half)', () {
    testWidgets('two cold-start URLs each get a sheet in order',
        (tester) async {
      final engine = _QueuedShareEngine([_url1, _url2]);
      await _pumpShell(tester, engine: engine);

      // First URL surfaces immediately.
      expect(find.text('Shared link'), findsOneWidget);
      // Dismiss it ("Not now") → second queued URL must surface next.
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      // Exactly one sheet re-opens for the queued URL (pre-fix: zero —
      // the second share was silently dropped). URL text also prefills
      // Home, so the sheet chrome is the sequencing signal.
      expect(find.text('Shared link'), findsOneWidget);
    });

    testWidgets('live URL arriving while sheet open is queued, not dropped',
        (tester) async {
      final engine = _QueuedShareEngine([_url1]);
      await _pumpShell(tester, engine: engine);
      expect(find.text('Shared link'), findsOneWidget);

      engine.live.add(_url2);
      await tester.pump();
      // Still the first sheet (second waits its turn, not stacked).
      // (URL text itself also prefills Home, so assert on the sheet chrome.)
      expect(find.text('Shared link'), findsOneWidget);

      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      // Exactly one sheet re-opens for the queued URL (pre-fix: zero —
      // the second share was silently dropped). URL text also prefills
      // Home, so the sheet chrome is the sequencing signal.
      expect(find.text('Shared link'), findsOneWidget);
    });
  });
}
