import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/utils/crash_reporter.dart';
import 'package:grablytic/core/utils/pending_report.dart';
import 'package:grablytic/features/settings/screens/report_problem_screen.dart';
import 'package:grablytic/features/shell/widgets/crash_recovery_prompt.dart';

import '../../support/memory_report_store.dart';

/// Hosts the prompt the way the shell does: once, after the first frame.
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
      CrashRecoveryPrompt.maybeShow(context: context, ref: ref);
    });
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('home')));
}

void main() {
  late MemoryReportStore store;

  setUp(() {
    store = MemoryReportStore();
    CrashRecoveryPrompt.resetForTest();
  });

  tearDown(() {
    CrashRecoveryPrompt.resetForTest();
    CrashReporter.instance = null;
  });

  /// Writes a crash as a previous session would have left it.
  Future<PendingReport> seedCrash() async {
    final report = PendingReport(
      id: 'old-crash',
      fingerprint: 'fp',
      category: ReportCategory.crash,
      title: '[Crash] StateError: boom',
      summary: 'boom',
      body: '### What happened\nboom',
      createdAt: DateTime.now().subtract(const Duration(hours: 2)),
      source: 'auto',
      errorType: 'StateError',
    );
    await store.add(report);
    return report;
  }

  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: _Host())),
    );
    // Fixed pumps, not pumpAndSettle: reading the queue is real file I/O
    // and the banner animates in.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  testWidgets('offers a previous crash without blocking the UI',
      (tester) async {
    CrashReporter.instance = CrashReporter(store: store);
    await seedCrash();
    await pumpHost(tester);

    expect(find.textContaining('ran into a problem last time'), findsOneWidget);
    expect(find.text('Review'), findsOneWidget);
    expect(find.text('Send report'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
    // The screen underneath is usable: this is a banner, not a dialog.
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('marks the report as mentioned so it is not repeated',
      (tester) async {
    CrashReporter.instance = CrashReporter(store: store);
    await seedCrash();
    await pumpHost(tester);

    expect((await store.list()).single.lastPromptAt, isNotNull);
  });

  testWidgets('shows nothing when the only crash is from this session',
      (tester) async {
    CrashReporter.instance = CrashReporter(store: store);
    // Created "now" by the same session: not a recovery, just a report.
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
    CrashReporter.instance = null;
    await pumpHost(tester);
    expect(find.byType(MaterialBanner), findsNothing);
  });

  testWidgets('Not now dismisses and keeps the report on disk',
      (tester) async {
    CrashReporter.instance = CrashReporter(store: store);
    await seedCrash();
    await pumpHost(tester);

    await tester.tap(find.text('Not now'));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(find.byType(MaterialBanner), findsNothing);
    expect(await store.list(), hasLength(1));
  });

  testWidgets('Review opens the form with the crash prefilled', (tester) async {
    CrashReporter.instance = CrashReporter(store: store);
    await seedCrash();
    await pumpHost(tester);

    await tester.tap(find.text('Review'));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(find.byType(ReportProblemScreen), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, 'boom');
    // The category the report was filed under, not the default.
    expect(find.text('Crash or freeze'), findsOneWidget);
  });
}
