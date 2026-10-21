import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/crash_reports.dart';
import '../../settings/screens/report_problem_screen.dart';

/// The "we ran into a problem last time" offer.
///
/// A [MaterialBanner] rather than a dialog: it must not block startup, must
/// not steal focus from whatever the user opened the app for, and must be
/// dismissible without deciding anything. The report is already on disk, so
/// "Not now" costs the user nothing.
///
/// One-shot rules live in [CrashReports.promptCandidate] (earlier session
/// only, three-day cooldown per report) plus [_shownThisSession], so a hot
/// restart or a rebuilt shell cannot stack banners.
class CrashRecoveryBanner {
  CrashRecoveryBanner._();

  static bool _shownThisSession = false;

  /// Test seam: forget that the banner ran.
  @visibleForTesting
  static void resetForTest() => _shownThisSession = false;

  static Future<void> maybeShow({
    required BuildContext context,
    required WidgetRef ref,
  }) async {
    if (_shownThisSession) return;
    final reports = CrashReports.instance;
    if (reports == null) return;

    final report = await reports.promptCandidate();
    if (report == null) return;

    // Claim the slot before any await that could race a second caller.
    _shownThisSession = true;
    await reports.markPrompted(report.id);

    if (!context.mounted) return;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    void open({bool sendImmediately = false}) {
      messenger.hideCurrentMaterialBanner();
      navigator.push(MaterialPageRoute<bool>(
        builder: (_) => ReportProblemScreen(
          initialTitle: 'The app encountered a problem and restarted.',
          initialBody: report.body,
          queuedReportId: report.id,
          submitImmediately: sendImmediately,
        ),
      ));
    }

    messenger.showMaterialBanner(
      MaterialBanner(
        leading: const Icon(Icons.report_problem_outlined),
        // Three actions on a phone-width banner do not fit beside the text,
        // and the alternative is a row that overflows by a pixel.
        forceActionsBelow: true,
        content: Text(
          'Grablytic ran into a problem last time. Send a diagnostic report '
          'so it can be fixed?',
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
            child: const Text('Review report'),
          ),
          FilledButton(
            onPressed: () => open(sendImmediately: true),
            child: const Text('Send report'),
          ),
        ],
      ),
    );
  }
}
