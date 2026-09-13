import 'package:flutter/material.dart';

/// One explained accept/reject choice in the onboarding permissions step.
///
/// Purely presentational: the parent owns the permission state and fires
/// the actual system requests. Visual language mirrors the onboarding
/// screen's existing feature cards (white10 fill, white24 border) so the
/// step feels like part of the same flow, not a system bolt-on.
///
/// When [confirmed] is true (granted / already-on / acknowledged / not
/// applicable on this device), the card shows [statusText] with a check
/// and no buttons. Otherwise it shows the accept/reject button row, or a
/// spinner while [working].
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
        onAccept = null;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

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
                  color: Colors.lightGreenAccent,
                  size: 22,
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            explanation,
            style: textTheme.bodyMedium?.copyWith(color: Colors.white70),
          ),
          if (confirmed && statusText != null) ...[
            const SizedBox(height: 8),
            Text(
              statusText!,
              style: textTheme.bodySmall?.copyWith(
                color: Colors.lightGreenAccent,
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
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              )
            else
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (rejectLabel != null)
                    TextButton(
                      onPressed: onReject,
                      child: Text(
                        rejectLabel!,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                  const SizedBox(width: 8),
                  if (recoveryLabel != null)
                    ElevatedButton(
                      onPressed: onRecovery,
                      child: Text(recoveryLabel!),
                    )
                  else if (acceptLabel != null)
                    ElevatedButton(
                      onPressed: onAccept,
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
