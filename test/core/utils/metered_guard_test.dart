import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grablytic/core/engine/engine_provider.dart';
import 'package:grablytic/providers/settings_provider.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';
import 'package:grablytic/providers/metered_guard.dart';

/// Seal-grounded metered handling: explicit taps on a metered link with
/// Wi-Fi Only on must ask (Download anyway / Wait) instead of silently
/// burning mobile data — and stay silent otherwise.
void main() {
  testWidgets('wifiOnly off proceeds without any dialog',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final engine = MockEngineService()..mockMetered = true;
    bool? result;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        engineProvider.overrideWithValue(engine),
      ],
      child: MaterialApp(
        home: Consumer(builder: (context, ref, _) {
          return ElevatedButton(
            onPressed: () async {
              result = await ensureUnmeteredDownload(
                  context: context, ref: ref);
            },
            child: const Text('go'),
          );
        }),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(find.text('On mobile data'), findsNothing);
  });

  testWidgets('metered link asks, Download proceeds, Wait cancels',
      (tester) async {
    SharedPreferences.setMockInitialValues({'wifiOnly': true});
    final prefs = await SharedPreferences.getInstance();
    for (final choice in ['Download', 'Wait']) {
      final engine = MockEngineService()..mockMetered = true;
      bool? result;
      await tester.pumpWidget(ProviderScope(
        overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        engineProvider.overrideWithValue(engine),
      ],
        child: MaterialApp(
          home: Consumer(builder: (context, ref, _) {
            return ElevatedButton(
              onPressed: () async {
                result = await ensureUnmeteredDownload(
                    context: context, ref: ref);
              },
              child: const Text('go'),
            );
          }),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('On mobile data'), findsOneWidget);
      await tester.tap(find.text(choice));
      await tester.pumpAndSettle();
      expect(result, choice == 'Download');
    }
  });

  testWidgets('unmetered link with wifiOnly on proceeds silently',
      (tester) async {
    SharedPreferences.setMockInitialValues({'wifiOnly': true});
    final prefs = await SharedPreferences.getInstance();
    final engine = MockEngineService()..mockMetered = false;
    bool? result;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        engineProvider.overrideWithValue(engine),
      ],
      child: MaterialApp(
        home: Consumer(builder: (context, ref, _) {
          return ElevatedButton(
            onPressed: () async {
              result = await ensureUnmeteredDownload(
                  context: context, ref: ref);
            },
            child: const Text('go'),
          );
        }),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(find.text('On mobile data'), findsNothing);
  });
}
