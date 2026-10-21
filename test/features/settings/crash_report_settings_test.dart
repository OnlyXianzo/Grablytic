import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/engine/engine_provider.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';
import 'package:grablytic/core/utils/crash_reporter.dart';
import 'package:grablytic/features/settings/screens/report_problem_screen.dart';
import 'package:grablytic/features/settings/screens/settings_screen.dart';
import 'package:grablytic/providers/resume_provider.dart';
import 'package:grablytic/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_proxy_secret_store.dart';

class _NoopResumeNotifier extends ResumeNotifier {
  _NoopResumeNotifier(super.ref);

  @override
  Future<void> scan() async {
    state = const AsyncValue.data([]);
  }
}

/// The setting only matters if a user can find it, so this covers the two
/// things that made the old implementation unreachable: the switch and the
/// entry point into the form.
void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'onboardingCompleted': true,
      'hasSeenBatteryPrompt': true,
    });
    prefs = await SharedPreferences.getInstance();
  });

  tearDown(() => CrashReporter.instance = null);

  Future<void> pumpSettings(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          proxySecretStoreProvider.overrideWithValue(FakeProxySecretStore()),
          engineProvider.overrideWith((ref) => MockEngineService()),
          resumeProvider.overrideWith((ref) => _NoopResumeNotifier(ref)),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openSystemCategory(WidgetTester tester) async {
    final cat = find.text('System & Diagnostics');
    await tester.scrollUntilVisible(cat, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(cat);
    await tester.pumpAndSettle();
  }

  testWidgets('automatic crash reports are off until the user opts in',
      (tester) async {
    await pumpSettings(tester);
    await openSystemCategory(tester);

    final label = find.text('Send crash reports automatically');
    expect(label, findsOneWidget);

    final row = find.ancestor(
      of: label,
      matching: find.byType(Row),
    ).first;
    final toggle =
        tester.widget<Switch>(find.descendant(of: row, matching: find.byType(Switch)));
    expect(toggle.value, isFalse, reason: 'privacy-first default');

    await tester.tap(label);
    await tester.pumpAndSettle();

    expect(prefs.getBool('auto_crash_reporting'), isTrue);
  });

  testWidgets('Report a problem is reachable and opens the form',
      (tester) async {
    await pumpSettings(tester);
    await openSystemCategory(tester);

    final row = find.text('Report a problem');
    expect(row, findsOneWidget);

    await tester.scrollUntilVisible(row, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(find.byType(ReportProblemScreen), findsOneWidget);
    expect(find.text('What went wrong?'), findsOneWidget);
  });

  testWidgets('searching for "bug" finds the system category', (tester) async {
    await pumpSettings(tester);

    await tester.enterText(find.byKey(const Key('settings_search_field')), 'bug');
    await tester.pumpAndSettle();

    // The root list is categories; the query has to keep this one visible
    // or the report row is unfindable for anyone who searches first.
    expect(find.text('System & Diagnostics'), findsOneWidget);
    expect(find.text('General'), findsNothing);

    await tester.tap(find.text('System & Diagnostics'));
    await tester.pumpAndSettle();
    expect(find.text('Report a problem'), findsOneWidget);
  });
}
