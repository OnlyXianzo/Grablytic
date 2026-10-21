import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/engine/engine_provider.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';
import 'package:grablytic/core/utils/crash_reporter.dart';
import 'package:grablytic/core/utils/github_reporter.dart';
import 'package:grablytic/core/utils/pending_report.dart';
import 'package:grablytic/features/settings/screens/report_problem_screen.dart';

class _FakeGithubReporter extends GithubReporter {
  _FakeGithubReporter({this.postable = true, this.createdUrl});

  final bool postable;
  final String? createdUrl;

  @override
  bool get canPost => postable;

  @override
  Future<String?> findDuplicate(String fp) async => null;

  @override
  Future<String?> createIssue({
    required String title,
    required String body,
    List<String> labels = const ['bug', 'auto-report'],
  }) async =>
      createdUrl;
}

/// Pumps a fixed number of frames instead of `pumpAndSettle`.
///
/// The send path shows a progress indicator and touches the filesystem;
/// `pumpAndSettle` waits for "no scheduled frames", which a spinner never
/// satisfies, and real file I/O completes on the event loop rather than on
/// a timer.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  late Directory dir;
  late PendingReportStore store;
  late CrashReporter reporter;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('grablytic_report_ui');
    store = PendingReportStore(dir);
    reporter = CrashReporter(
      store: store,
      reporterFactory: () => _FakeGithubReporter(
        createdUrl: 'https://github.com/o/r/issues/42',
      ),
    );
    CrashReporter.instance = reporter;
  });

  tearDown(() async {
    CrashReporter.instance = null;
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<void> pump(WidgetTester tester, {Widget? screen}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          engineProvider.overrideWithValue(MockEngineService()),
        ],
        child: MaterialApp(
          home: screen ?? const ReportProblemScreen(),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('shows a short form and a disabled send button', (tester) async {
    await pump(tester);

    expect(find.text('What went wrong?'), findsOneWidget);
    expect(find.text('Report a problem'), findsOneWidget);
    expect(find.text('Send report'), findsOneWidget);

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Send report'),
    );
    expect(button.onPressed, isNull, reason: 'nothing to send yet');
  });

  testWidgets('typing enables Send and offers the five categories',
      (tester) async {
    await pump(tester);

    for (final category in ReportCategory.values) {
      expect(find.text(category.label), findsOneWidget);
    }

    await tester.enterText(find.byType(TextField), 'download stalled at 40%');
    await tester.pump();

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Send report'),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('success is only claimed when GitHub confirms', (tester) async {
    await pump(tester);

    await tester.enterText(find.byType(TextField), 'it crashed on open');
    await tester.tap(find.text('Download failed'));
    await tester.pump();
    await tester.tap(find.text('Send report'));
    await settle(tester);

    expect(find.text('Report sent'), findsOneWidget);
    expect(find.textContaining('issues/42'), findsOneWidget);
  });

  testWidgets('a browser hand-off does not claim success', (tester) async {
    CrashReporter.instance = CrashReporter(
      store: store,
      reporterFactory: () => _FakeGithubReporter(postable: false),
    );
    await pump(tester);

    await tester.enterText(find.byType(TextField), 'something is wrong');
    await tester.tap(find.text('Send report'));
    await settle(tester);

    expect(find.text('Finish on GitHub'), findsOneWidget);
    expect(find.text('Report sent'), findsNothing);
    // The report stays queued: the app cannot know the user pressed Submit.
    expect(await store.list(), hasLength(1));
  });

  testWidgets('a failure keeps the words and offers a retry', (tester) async {
    CrashReporter.instance = CrashReporter(
      store: store,
      reporterFactory: () => _FakeGithubReporter(), // createIssue → null
    );
    await pump(tester);

    await tester.enterText(find.byType(TextField), 'nothing works');
    await tester.tap(find.text('Send report'));
    await settle(tester);

    expect(find.text('Not sent'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(await store.list(), hasLength(1));
  });

  testWidgets('the review panel shows exactly what will be filed',
      (tester) async {
    await pump(tester);

    expect(find.text('What will be included'), findsOneWidget);
    await tester.tap(find.text('What will be included'));
    await tester.pump();

    expect(
      find.textContaining('The full text appears here once the report'),
      findsOneWidget,
    );
  });

  testWidgets('reporting unavailable is stated, not hidden', (tester) async {
    CrashReporter.instance = null;
    await pump(tester);

    await tester.enterText(find.byType(TextField), 'anything at all');
    await tester.tap(find.text('Send report'));
    await settle(tester);

    expect(
      find.textContaining('Reporting is not available'),
      findsOneWidget,
    );
  });
}
