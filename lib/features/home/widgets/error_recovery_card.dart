import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/theme/text_styles.dart';

class ErrorRecoveryCard extends StatelessWidget {
  final String? errorType;
  final String? errorMessage;
  final VoidCallback? onRetry;
  final VoidCallback? onOpenCookies;
  final VoidCallback? onOpenProxy;
  final VoidCallback? onPickFormat;

  const ErrorRecoveryCard({
    super.key,
    this.errorType,
    this.errorMessage,
    this.onRetry,
    this.onOpenCookies,
    this.onOpenProxy,
    this.onPickFormat,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final mapping = _actionMapping(errorType);
    if (mapping == null) return const SizedBox.shrink();

    final icon = mapping.$1;
    final label = mapping.$2;
    final action = mapping.$3;

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: colorScheme.error.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: colorScheme.error),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  errorMessage ?? 'Download failed',
                  style: GoogleFonts.instrumentSans(
                    fontSize: 12,
                    color: colorScheme.onErrorContainer,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (action != null) ...[
                  const SizedBox(height: 8),
                  Semantics(
                    button: true,
                    label: label,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: action,
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: colorScheme.error.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: colorScheme.error.withValues(alpha: 0.3),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(icon, size: 14, color: colorScheme.error),
                              const SizedBox(width: 6),
                              Text(
                                label,
                                style: GoogleFonts.instrumentSans(
                                  fontSize: 12,
                                  color: colorScheme.error,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ] else ...[
                  const SizedBox(height: 4),
                  Text(
                    label,
                    style: textTheme.mono.copyWith(
                      fontSize: 11,
                      color: colorScheme.error.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  (IconData, String, VoidCallback?)? _actionMapping(String? errorType) {
    if (errorType == null) return null;

    switch (errorType) {
      case 'ERROR_NETWORK':
        return (Icons.refresh, 'Retry', onRetry);
      case 'ERROR_FORBIDDEN':
        return (Icons.cookie, 'Try with Cookies', onOpenCookies);
      case 'ERROR_PRIVATE':
        return (Icons.login, 'Log In', onOpenCookies);
      case 'ERROR_AGE_RESTRICTED':
        return (Icons.login, 'Log In', onOpenCookies);
      case 'ERROR_RATE_LIMITED':
        return (Icons.timer, 'Retry in 60s', onRetry);
      case 'ERROR_GEO_BLOCKED':
      case 'ERROR_SSL_BLOCKED':
        return (Icons.vpn_key, 'Configure Proxy', onOpenProxy);
      case 'ERROR_FORMAT_UNAVAILABLE':
        return (Icons.tune, 'Pick Format', onPickFormat);
      case 'ERROR_FILE_LOCKED':
        return (Icons.warning, 'Overwrite', onRetry);
      case 'ERROR_QUOTA_EXCEEDED':
        return (Icons.replay, 'Re-download', onRetry);
      case 'ERROR_DRM':
        return (Icons.info, 'Cannot Download (DRM)', null);
      case 'ERROR_JS_RUNTIME':
        return (Icons.replay, 'Re-download', onRetry);
      case 'ERROR_UNAVAILABLE':
        return (Icons.info, 'Unavailable', null);
      case 'ERROR_CANCELLED':
        return (Icons.cancel, 'Cancelled', null);
      case 'ERROR_UNKNOWN':
      default:
        return (Icons.info, 'View Details', onRetry);
    }
  }
}
