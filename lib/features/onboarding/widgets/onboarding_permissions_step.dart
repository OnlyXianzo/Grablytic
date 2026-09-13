import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/engine/engine_provider.dart';
import '../../../providers/settings_provider.dart';
import 'permission_explainer_card.dart';

/// Per-permission onboarding decision state.
///
/// `ask` means the explainer card shows its Allow/Skip choice; `denied`
/// means a fired system prompt came back ungranted, so the card offers the
/// OS settings screen instead of re-firing a dead prompt.
enum _CardDecision { loading, ask, granted, skipped, denied, unsupported }

/// Final onboarding beat: a pre-permission explainer step.
///
/// Each card explains WHY the permission matters and offers its own
/// accept/reject choice (never one blanket button):
///
/// 1. Notifications — pre-permission rationale shown immediately before
///    the system `POST_NOTIFICATIONS` dialog (current Android guidance:
///    explain why first, then request). WHY: background-download
///    completion/failure alerts.
/// 2. Unrestricted background — battery-exemption explainer before the
///    system exemption screen. WHY: downloads must survive Doze with the
///    screen off. Any choice here sets `hasSeenBatteryPrompt` so the
///    AppShell prompt never double-asks.
/// 3. Download location — informational: scoped storage means there is no
///    runtime storage permission to request; files live in
///    Download/TrueStream.
///
/// Denial never blocks: [onFinished] (wired to `completeOnboarding`) is
/// always available, and everything remains changeable in Settings.
class OnboardingPermissionsStep extends ConsumerStatefulWidget {
  final VoidCallback onFinished;

  const OnboardingPermissionsStep({super.key, required this.onFinished});

  @override
  ConsumerState<OnboardingPermissionsStep> createState() =>
      _OnboardingPermissionsStepState();
}

class _OnboardingPermissionsStepState
    extends ConsumerState<OnboardingPermissionsStep> {
  _CardDecision _notif = _CardDecision.loading;
  _CardDecision _battery = _CardDecision.loading;
  bool _notifWorking = false;
  bool _batteryWorking = false;
  bool _storageAcked = false;

  @override
  void initState() {
    super.initState();
    _queryStatuses();
  }

  Future<void> _queryStatuses() async {
    final engine = ref.read(engineProvider);
    Map<String, dynamic> notif = const {};
    Map<String, dynamic> bat = const {};
    try {
      notif = await engine.notificationPermissionStatus();
    } catch (_) {}
    try {
      bat = await engine.batteryExemptionStatus();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _notif = _fromStatus(notif);
      _battery = _fromBattery(bat);
    });
  }

  /// `{'supported': ..., 'granted': ...}` → decision. Unsupported covers
  /// pre-33 Android (implicitly granted) and desktop builds.
  static _CardDecision _fromStatus(Map<String, dynamic> status) {
    if (status['supported'] != true) return _CardDecision.unsupported;
    if (status['granted'] == true) return _CardDecision.granted;
    return _CardDecision.ask;
  }

  static _CardDecision _fromBattery(Map<String, dynamic> status) {
    if (status['supported'] != true) return _CardDecision.unsupported;
    if (status['exempt'] == true) return _CardDecision.granted;
    return _CardDecision.ask;
  }

  Future<void> _allowNotifications() async {
    setState(() => _notifWorking = true);
    Map<String, dynamic> res = const {};
    try {
      res = await ref.read(engineProvider).requestNotificationPermission();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _notifWorking = false;
      // Kotlin returns {'success': true, 'granted': bool} from the system
      // prompt verdict (MainActivity.onRequestPermissionsResult).
      _notif = res['granted'] == true ? _CardDecision.granted : _CardDecision.denied;
    });
  }

  void _skipNotifications() {
    setState(() => _notif = _CardDecision.skipped);
  }

  Future<void> _openNotificationSettings() async {
    try {
      await ref.read(engineProvider).openNotificationSettings();
    } catch (_) {}
  }

  Future<void> _enableBackground() async {
    setState(() => _batteryWorking = true);
    try {
      await ref.read(engineProvider).requestBatteryExemption();
    } catch (_) {}
    // Any first-run choice suppresses the AppShell post-onboarding prompt.
    try {
      ref.read(settingsProvider.notifier).setHasSeenBatteryPrompt(true);
    } catch (_) {}
    Map<String, dynamic> bat = const {};
    try {
      bat = await ref.read(engineProvider).batteryExemptionStatus();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _batteryWorking = false;
      // The system screen leaves the app; if the user exempted us, confirm
      // it, otherwise record that they made their choice (re-ask in Settings).
      _battery = bat['exempt'] == true
          ? _CardDecision.granted
          : _CardDecision.skipped;
    });
  }

  void _skipBackground() {
    try {
      ref.read(settingsProvider.notifier).setHasSeenBatteryPrompt(true);
    } catch (_) {}
    setState(() => _battery = _CardDecision.skipped);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'A couple of quick choices',
            style: textTheme.headlineMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'TrueStream works without these — they just make downloads smoother. '
            'You can change everything later in Settings.',
            style: textTheme.bodyMedium?.copyWith(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          _notificationCard(textTheme),
          const SizedBox(height: 12),
          _batteryCard(textTheme),
          const SizedBox(height: 12),
          _storageCard(textTheme),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: widget.onFinished,
            style: ElevatedButton.styleFrom(
              backgroundColor: colorScheme.primaryContainer,
              foregroundColor: colorScheme.onPrimaryContainer,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }

  Widget _notificationCard(TextTheme textTheme) {
    const explanation = 'TrueStream downloads in the background. With '
        'notifications on, you get progress updates and an alert when a '
        'file finishes or fails — even with the app closed. Without them, '
        'progress still shows inside the app.';
    switch (_notif) {
      case _CardDecision.loading:
        return const PermissionExplainerCard(
          icon: Icons.notifications_outlined,
          title: 'Download alerts',
          explanation: explanation,
          working: true,
        );
      case _CardDecision.granted:
        return const PermissionExplainerCard(
          icon: Icons.notifications_outlined,
          title: 'Download alerts',
          explanation: explanation,
          confirmed: true,
          statusText: 'On — you\'ll get completion alerts.',
        );
      case _CardDecision.unsupported:
        return const PermissionExplainerCard(
          icon: Icons.notifications_outlined,
          title: 'Download alerts',
          explanation: explanation,
          confirmed: true,
          statusText: 'Not needed on this device.',
        );
      case _CardDecision.skipped:
        return const PermissionExplainerCard(
          icon: Icons.notifications_outlined,
          title: 'Download alerts',
          explanation: explanation,
          confirmed: true,
          statusText: 'Skipped — enable anytime in Settings.',
        );
      case _CardDecision.denied:
        return PermissionExplainerCard.denied(
          icon: Icons.notifications_outlined,
          title: 'Download alerts',
          explanation: explanation,
          recoveryLabel: 'Open settings',
          onRecovery: _openNotificationSettings,
          rejectLabel: 'Not now',
          onReject: _skipNotifications,
        );
      case _CardDecision.ask:
        return PermissionExplainerCard(
          icon: Icons.notifications_outlined,
          title: 'Download alerts',
          explanation: explanation,
          working: _notifWorking,
          acceptLabel: 'Allow',
          onAccept: _allowNotifications,
          rejectLabel: 'Skip',
          onReject: _skipNotifications,
        );
    }
  }

  Widget _batteryCard(TextTheme textTheme) {
    const explanation = 'Android can pause apps to save battery (Doze). '
        'Exempting TrueStream lets downloads keep running with the screen '
        'off instead of stalling overnight.';
    switch (_battery) {
      case _CardDecision.loading:
        return const PermissionExplainerCard(
          icon: Icons.battery_charging_full_outlined,
          title: 'Unrestricted background',
          explanation: explanation,
          working: true,
        );
      case _CardDecision.granted:
        return const PermissionExplainerCard(
          icon: Icons.battery_charging_full_outlined,
          title: 'Unrestricted background',
          explanation: explanation,
          confirmed: true,
          statusText: 'Allowed — downloads survive in background.',
        );
      case _CardDecision.unsupported:
        return const PermissionExplainerCard(
          icon: Icons.battery_charging_full_outlined,
          title: 'Unrestricted background',
          explanation: explanation,
          confirmed: true,
          statusText: 'Not needed on this device.',
        );
      case _CardDecision.skipped:
      case _CardDecision.denied:
        return const PermissionExplainerCard(
          icon: Icons.battery_charging_full_outlined,
          title: 'Unrestricted background',
          explanation: explanation,
          confirmed: true,
          statusText: 'Skipped — enable anytime in Settings.',
        );
      case _CardDecision.ask:
        return PermissionExplainerCard(
          icon: Icons.battery_charging_full_outlined,
          title: 'Unrestricted background',
          explanation: explanation,
          working: _batteryWorking,
          acceptLabel: 'Enable',
          onAccept: _enableBackground,
          rejectLabel: 'Skip',
          onReject: _skipBackground,
        );
    }
  }

  Widget _storageCard(TextTheme textTheme) {
    const explanation = 'Finished files save to the TrueStream folder in '
        'your Downloads. Android gives each app its own storage space, so '
        'there is no extra permission to grant — this just tells you where '
        'to find everything.';
    if (_storageAcked) {
      return const PermissionExplainerCard(
        icon: Icons.folder_outlined,
        title: 'Download location',
        explanation: explanation,
        confirmed: true,
        statusText: 'Got it — Downloads / TrueStream.',
      );
    }
    return PermissionExplainerCard(
      icon: Icons.folder_outlined,
      title: 'Download location',
      explanation: explanation,
      acceptLabel: 'Got it',
      onAccept: () => setState(() => _storageAcked = true),
      rejectLabel: 'Skip',
      onReject: () => setState(() => _storageAcked = true),
    );
  }
}
