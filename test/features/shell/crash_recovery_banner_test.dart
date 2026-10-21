import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/engine/engine_provider.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';
import 'package:grablytic/core/utils/crash_reports.dart';
import 'package:grablytic/core/utils/pending_report.dart';
import 'package:grablytic/features/settings/screens/report_problem_screen.dart';
import 'package:grablytic/features/shell/widgets/crash_recovery_banner.dart';
import 'package:grablytic/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/memory_report_store.dart';

/// Hosts the banner the way the shell does: once, after the first frame.
class _Host extends ConsumerStatefulWidget {
  const _Host();

  @override
  ConsumerState<_Host> createState() => _HostState();
}

class _HostState extends ConsumerState<_Host> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      CrashRecoveryBanner.maybeShow(context: context, ref: ref);
    });
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('home')));
}

void main() {
  late MemoryReportStore store;

  late SharedPreferences prefs;

  setUp(() async {
    store = MemoryReportStore();
    CrashRecoveryBanner.resetForTest();
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  tearDown(() {
    CrashRecoveryBanner.resetForTest();
    CrashReports.instance = null;
  });

  /// A crash as the previous session would have left it.
  Future<void> seedCrash() => store.add(PendingReport(
        id: 'old-crash',
        fingerprint: 'fp',
        category: ReportCategory.crash,
        title: '[Crash] StateError: boom',
        summary: 'boom',
        body: '### What happened\nboom',
        createdAt: DateTime.now().subtract(const Duration(hours: 2)),
        source: 'auto',
      ));

  /// Fixed pumps, not `pumpAndSettle`: the queue read is a real async hop
  /// and the banner animates in.
  Future<void> settle(WidgetTester tester) async {
    // Long enough for the banner's 250 ms entrance and exit animations.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        // The form reads the engine to open GitHub; keep it fake so the
        // test never spawns a Python process.
        overrides: [
          engineProvider.overrideWith((ref) => MockEngineService()),
          // The form reads the settings for its diagnostics panel.
          sharedPreferencesProvider.overrideWithValue(prefs),
        ],
        child: const MaterialApp(home: _Host()),
      ),
    );
    await settle(tester);
    expect(tester.takeException(), isNull,
        reason: 'a past crash must never break the shell');
  }

  testWidgets('offers a previous crash without blocking the UI',
      (tester) async {
    CrashReports.instance = CrashReports(store: store);
    await seedCrash();
    await pumpHost(tester);

    expect(find.textContaining('ran into a problem last time'), findsOneWidget);
    expect(find.text('Review report'), findsOneWidget);
    expect(find.text('Send report'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
    // The screen underneath stays usable: a banner, not a dialog.
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('marks the report as mentioned so it is not repeated',
      (tester) async {
    CrashReports.instance = CrashReports(store: store);
    await seedCrash();
    await pumpHost(tester);

    expect((await store.list()).single.lastPromptAt, isNotNull);
  });

  testWidgets('shows nothing when the only crash is from this session',
      (tester) async {
    CrashReports.instance = CrashReports(store: store);
    await store.add(PendingReport(
      id: 'fresh',
      fingerprint: 'fp2',
      category: ReportCategory.crash,
      title: 't',
      summary: 's',
      body: 'b',
      createdAt: DateTime.now().add(const Duration(seconds: 5)),
      source: 'auto',
    ));
    await pumpHost(tester);

    expect(find.byType(MaterialBanner), findsNothing);
  });

  testWidgets('shows nothing rather than throwing when reporting is off',
      (tester) async {
    CrashReports.instance = null;
    await pumpHost(tester);
    expect(find.byType(MaterialBanner), findsNothing);
  });

  testWidgets('Not now dismisses and keeps the report on disk', (tester) async {
    CrashReports.instance = CrashReports(store: store);
    await seedCrash();
    await pumpHost(tester);

    await tester.tap(find.text('Not now'));
    await settle(tester);

    expect(find.byType(MaterialBanner), findsNothing);
    expect(await store.list(), hasLength(1));
  });

  testWidgets('Review report opens the form with the crash text', (tester) async {
    CrashReports.instance = CrashReports(store: store);
    await seedCrash();
    await pumpHost(tester);

    await tester.tap(find.text('Review report'));
    await settle(tester);

    expect(find.byType(ReportProblemScreen), findsOneWidget);
    expect(find.text('Tell us what went wrong'), findsOneWidget);
  });
}
