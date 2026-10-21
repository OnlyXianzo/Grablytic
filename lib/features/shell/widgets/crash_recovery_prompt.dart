import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/crash_reporter.dart';
import '../../settings/screens/report_problem_screen.dart';

/// The "we ran into a problem last time" offer, shown once per crash.
///
/// Deliberately a [MaterialBanner] and not a dialog: it must not block
/// startup, must not steal focus from whatever the user opened the app to
/// do, and must be dismissible without deciding anything. The report is
/// already on disk at this point, so "Not now" costs nothing but the
/// prompt.
///
/// One-shot rules live in [CrashReporter.promptCandidate] (earlier session
/// only, three-day cooldown per report) plus [_shownThisSession], so a
/// hot-restart or a rebuilt shell cannot stack banners.
class CrashRecoveryPrompt {
  CrashRecoveryPrompt._();

  static bool _shownThisSession = false;

  /// Test seam: forget that the prompt ran.
  @visibleForTesting
  static void resetForTest() => _shownThisSession = false;

  static Future<void> maybeShow({
    required BuildContext context,
    required WidgetRef ref,
  }) async {
    if (_shownThisSession) return;
    final reporter = CrashReporter.instance;
    if (reporter == null) return;

    final report = await reporter.promptCandidate();
    if (report == null) return;

    // Claim the slot before any await that could race a second caller.
    _shownThisSession = true;
    await reporter.markPrompted(report.id);

    if (!context.mounted) return;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    void open({bool autoSend = false}) {
      messenger.hideCurrentMaterialBanner();
      navigator.push(
        MaterialPageRoute(
          builder: (_) => ReportProblemScreen(
            initialCategory: report.category,
            reviewReportId: report.id,
            autoSend: autoSend,
          ),
        ),
      );
    }

    messenger.showMaterialBanner(
      MaterialBanner(
        leading: const Icon(Icons.report_problem_outlined),
        content: Text(
          'Grablytic ran into a problem last time. Send a diagnostic report '
          'so it can be fixed? Nothing is sent unless you choose Send.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () {
              messenger.hideCurrentMaterialBanner();
              messenger.showSnackBar(
                const SnackBar(
                  content: Text('Kept for later. Find it in Settings → '
                      'Report a problem.'),
                ),
              );
            },
            child: const Text('Not now'),
          ),
          TextButton(
            onPressed: () => open(),
            child: const Text('Review'),
          ),
          FilledButton(
            onPressed: () => open(autoSend: true),
            child: const Text('Send report'),
          ),
        ],
      ),
    );
  }
}
