import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Shared presentation components for the redesign (Phase 1: design system).
///
/// Every component resolves colors, text styles, spacing and radii from the
/// active [Theme] plus [GrablyticSpacing]/[GrablyticRadii] — no hardcoded
/// values. Logic and callbacks stay with the call sites; these widgets only
/// paint. All interactive elements meet the 48dp minimum target.
///
/// New screens must reuse these instead of inventing one-off equivalents.

/// Uppercase section label, e.g. PENDING / DOWNLOADED. Matches the mockup
/// `.grplabel` / `.lbl` treatment and the existing library section headers.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Text(
      text,
      style: textTheme.labelSmall?.copyWith(
        color: color ?? colorScheme.primary,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.5,
      ),
    );
  }
}

/// Rounded list-row container from the mockup (`.row`: 20px radius,
/// surface fill, hairline border). Content-agnostic; padding overridable.
class RowCard extends StatelessWidget {
  const RowCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(GrablyticSpacing.sm + 2),
    this.borderRadius = GrablyticRadii.xl,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(borderRadius),
      side: BorderSide(
        color: colorScheme.outlineVariant.withValues(alpha: 0.3),
      ),
    );
    final card = Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colorScheme.surfaceContainerLow,
      shape: shape,
      child: Padding(padding: padding, child: child),
    );
    if (onTap == null) return card;
    return InkWell(
      borderRadius: BorderRadius.circular(borderRadius),
      onTap: onTap,
      child: card,
    );
  }
}

/// Thin linear progress bar (mockup `.bar` / `.pbar`). Value is 0..1 and is
/// clamped; deterministic (no animation) so rapid progress ticks can't cause
/// layout jitter. Semantics expose the percentage to screen readers.
class GrablyticProgressBar extends StatelessWidget {
  const GrablyticProgressBar({
    super.key,
    required this.value,
    this.color,
    this.height = 4,
    this.semanticsLabel,
  });

  final double value;
  final Color? color;
  final double height;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final clamped = value.clamp(0.0, 1.0);
    return Semantics(
      label:
          semanticsLabel ?? 'Progress ${(clamped * 100).toInt()} percent',
      value: '${(clamped * 100).toInt()}%',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(height / 2),
        child: LinearProgressIndicator(
          value: clamped,
          minHeight: height,
          backgroundColor: colorScheme.surfaceContainerHighest,
          valueColor: AlwaysStoppedAnimation<Color>(
            color ?? colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

/// Icon + title + subtitle row with a trailing [Switch] (mockup `.set` with
/// `.tg`). Fixed 48dp+ height, single tap target, screen-reader friendly.
class ToggleRow extends StatelessWidget {
  const ToggleRow({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Semantics(
      toggled: value,
      label: title,
      child: InkWell(
        onTap: () => onChanged(!value),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: GrablyticSpacing.lg,
              vertical: GrablyticSpacing.sm,
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: colorScheme.outline, size: 20),
                ),
                const SizedBox(width: GrablyticSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title, style: textTheme.bodyLarge),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          style: textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                Switch(value: value, onChanged: onChanged),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottom-sheet presenter matching the mockup `.sheet`: 28px top radius,
/// drag handle, safe-area-aware padding. Thin wrapper over
/// [showModalBottomSheet] so every sheet in the app shares the chrome.
class GrablyticBottomSheet {
  GrablyticBottomSheet._();

  static Future<T?> show<T>({
    required BuildContext context,
    required Widget child,
    bool isDismissible = true,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return showModalBottomSheet<T>(
      context: context,
      isDismissible: isDismissible,
      isScrollControlled: true,
      backgroundColor: colorScheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(GrablyticRadii.sheet),
        ),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
            left: GrablyticSpacing.lg,
            right: GrablyticSpacing.lg,
            top: GrablyticSpacing.sm,
            bottom:
                GrablyticSpacing.lg + MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: GrablyticSpacing.sm),
              Flexible(child: child),
            ],
          ),
        ),
      ),
    );
  }
}

/// Back navigation header (mockup `.back`): chevron + label, 48dp target,
/// muted color. Label defaults to "Back".
class BackHeader extends StatelessWidget {
  const BackHeader({super.key, this.label = 'Back', this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onPressed ?? () => Navigator.of(context).maybePop(),
        borderRadius: BorderRadius.circular(GrablyticRadii.sm),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.chevron_left,
                color: colorScheme.onSurfaceVariant,
              ),
              Text(
                label,
                style: textTheme.bodyLarge?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
