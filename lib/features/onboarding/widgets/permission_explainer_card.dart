import 'package:flutter/material.dart';

/// One explained accept/reject choice in the onboarding permissions step.
///
/// Purely presentational: the parent owns the permission state and fires
/// the actual system requests. Uses the dark translucent design language
/// of onboarding beats 1-4 ([Colors.white10] card, white/white70 text)
/// because the onboarding scaffold is always [Colors.black], regardless
/// of the active theme — [ColorScheme.onSurface] would be black-on-black
/// in light mode. Elevated buttons reuse
/// [ColorScheme.primaryContainer]/[ColorScheme.onPrimaryContainer] to
/// match the beat-4 Continue button (identical value in both themes).
///
/// When [confirmed] is true (granted / already-on / acknowledged / not
/// applicable on this device), the card shows [statusText] with a check
/// and no buttons. Otherwise it shows the accept/reject button row, or a
/// spinner while [working]. [singleAck] renders one acknowledgment button
/// for informational rows where there is genuinely nothing to grant —
/// a fake Allow/Skip choice would be dishonest UI.
class PermissionExplainerCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String explanation;

  final bool confirmed;
  final String? statusText;

  final bool working;
  final String? acceptLabel;
  final VoidCallback? onAccept;
  final String? rejectLabel;
  final VoidCallback? onReject;

  /// Recovery action shown when a fired system prompt came back ungranted
  /// (denied twice / "don't ask again" means the system silently drops
  /// further prompts — the only path left is the OS settings screen).
  final String? recoveryLabel;
  final VoidCallback? onRecovery;

  /// True for informational rows: one button, honestly labeled.
  final bool singleAck;

  const PermissionExplainerCard({
    super.key,
    required this.icon,
    required this.title,
    required this.explanation,
    this.confirmed = false,
    this.statusText,
    this.working = false,
    this.acceptLabel,
    this.onAccept,
    this.rejectLabel,
    this.onReject,
    this.singleAck = false,
  })  : recoveryLabel = null,
        onRecovery = null;

  const PermissionExplainerCard.denied({
    super.key,
    required this.icon,
    required this.title,
    required this.explanation,
    required this.recoveryLabel,
    required this.onRecovery,
    this.rejectLabel,
    this.onReject,
  })  : confirmed = false,
        statusText = null,
        working = false,
        acceptLabel = null,
        singleAck = false,
        onAccept = null;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final elevatedStyle = ElevatedButton.styleFrom(
      backgroundColor: colorScheme.primaryContainer,
      foregroundColor: colorScheme.onPrimaryContainer,
    );
    const rejectStyle = ButtonStyle(
      foregroundColor: WidgetStatePropertyAll(Colors.white70),
    );

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Semantics(
                label: title,
                child: Icon(icon, color: Colors.white, size: 28),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (confirmed)
                const Icon(
                  Icons.check_circle,
                  color: Colors.white,
                  size: 22,
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            explanation,
            style: textTheme.bodyMedium?.copyWith(
              color: Colors.white70,
            ),
          ),
          if (confirmed && statusText != null) ...[
            const SizedBox(height: 8),
            Text(
              statusText!,
              style: textTheme.bodySmall?.copyWith(
                color: Colors.white70,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (!confirmed) ...[
            const SizedBox(height: 12),
            if (working)
              const Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                ),
              )
            else if (singleAck)
              Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton(
                  onPressed: onAccept,
                  style: elevatedStyle,
                  child: Text(acceptLabel ?? 'Got it'),
                ),
              )
            else
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (rejectLabel != null)
                    TextButton(
                      onPressed: onReject,
                      style: rejectStyle,
                      child: Text(rejectLabel!),
                    ),
                  const SizedBox(width: 8),
                  if (recoveryLabel != null)
                    ElevatedButton(
                      onPressed: onRecovery,
                      style: elevatedStyle,
                      child: Text(recoveryLabel!),
                    )
                  else if (acceptLabel != null)
                    ElevatedButton(
                      onPressed: onAccept,
                      style: elevatedStyle,
                      child: Text(acceptLabel!),
                    ),
                ],
              ),
          ],
        ],
      ),
    );
  }
}
