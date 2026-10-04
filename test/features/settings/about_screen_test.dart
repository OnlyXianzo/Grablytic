import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grablytic/core/engine/engine_provider.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';
import 'package:grablytic/core/theme/adaptive_logo.dart';
import 'package:grablytic/core/widgets/grablytic_components.dart';
import 'package:grablytic/features/settings/screens/about_screen.dart';
import 'package:grablytic/providers/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AboutScreen Structural Tests', () {
    late SharedPreferences prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'logoVariant': 'mark',
      });
      prefs = await SharedPreferences.getInstance();
    });

    testWidgets('renders hero brand column, contribute card, and support actions',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWith((ref) => MockEngineService()),
          ],
          child: const MaterialApp(
            home: AboutScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. BackHeader navigation chrome
      expect(find.byType(BackHeader), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);

      // 2. Hero brand column with AdaptiveLogo
      expect(find.byType(AdaptiveLogo), findsOneWidget);
      expect(find.text('Grablytic'), findsOneWidget);
      expect(find.text('by The Only'), findsOneWidget);

      // 3. Contribute & Help card with dual CTAs
      expect(find.text('CONTRIBUTE & HELP'), findsOneWidget);
      expect(find.text('Open repository on GitHub'), findsOneWidget);
      expect(find.text('Open @OnlyXianzo profile'), findsOneWidget);

      // 4. Support & Feedback rows
      expect(find.text('SUPPORT & FEEDBACK'), findsOneWidget);
      expect(find.text('Send Feedback'), findsOneWidget);
    });
  });
}
