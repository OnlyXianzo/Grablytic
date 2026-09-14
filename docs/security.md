# Security & Privacy Policy

Grablytic is designed with a privacy-first, zero-telemetry architecture. We take the security of our application, user data, and downstream dependencies seriously.

## Supported Versions

| Version | Supported |
|---|---|
| 0.0.x (main) | :white_check_mark: |
| < 0.0.1 | :x: |

## Reporting a Vulnerability

If you discover a security vulnerability or sensitive data issue in Grablytic, please report it privately:

1. **GitHub Security Advisory**: Use the [Private Vulnerability Reporting](https://github.com/OnlyXianzo/Grablytic/security/advisories/new) feature on GitHub to submit a confidential report.
2. Please provide a clear description of the vulnerability, reproduction steps, affected versions/platforms, and any potential mitigation.
3. **Do not** open public GitHub issues or discussions for security vulnerabilities.
4. We aim to acknowledge reports promptly and coordinate a fix prior to public disclosure.

## Trust Model

| Asset | Storage Location | Accessibility |
|---|---|---|
| Session cookies (`cookies.txt`, 0600) | App-private storage | App only (sandboxed) |
| Auth flags, settings, presets | SharedPreferences (private) | App only |
| Download history | App-private SQLite database | App only |
| Diagnostic logs (`app_logs.txt`) | App-private logs directory | App only (tokens redacted) |
| Exported logs | User-selected folder / Downloads | User only |

### Threat Boundaries
- **Defended against**: Malicious shared URLs or payload files, archive traversal attacks, network interception (TLS enforced everywhere, SHA-256 integrity verification for downloads), and cross-app inspection (sandboxed Android storage with `0600` file permissions).
- **Out of scope**: Operating system compromise, device root compromise, or zero-day exploits within upstream dependencies prior to patch release.

## Protections in Place

- **Safe yt-dlp Configuration**: Dangerous execution flags (`write-link`, `write-desktop-link`, `exec`, `enable-file-urls`) are strictly disabled.
- **Hardened Extraction**: Extraction routines reject path traversal (Zip-Slip / Tar-Slip), absolute paths, path escapes, and unsafe symlinks.
- **JS Runtime Allowlist**: Only approved challenge solver components execute within the sandbox.
- **Validated Downloader Arguments**: aria2c connection chunk counts are bounded (1–16), parameters validated against injection, and DASH/HLS routed to native handling.
- **Secrets & Token Hygiene**: No hardcoded API keys; TLS validation enforced; immutable PendingIntents; non-exported services; parameterized SQL queries; `0600` permissions on cookie files.
- **Automated Redaction**: Sensitive session tokens, signatures (`sig=`, `lsig=`), passwords, and authorization headers are automatically scrubbed from application logs.

## Applied Security Hardenings

| Hardening | Description | Impact |
|---|---|---|
| **Backup Protection** | `allowBackup="false"` with strict data extraction exclusion rules | Prevents private session cookies and tokens from uploading to unencrypted cloud backups |
| **Log Scrubbing** | Real-time redaction of authentication parameters and signatures in logs | Prevents accidental token leakage when users export diagnostic logs |
| **Intent Bounds** | Strict length and payload guards on incoming send intents | Protects against intent-based denial-of-service and intent overflow crashes |
| **Template Validation** | Sanitization and escape-blocking on custom output template formats | Restricts template path traversal and unauthorized command flags |

## Privacy Standards

- **Anonymous by Default**: No user accounts, no telemetry, no tracking, and no advertisements.
- **Opt-in Storage**: Cookies, logins, and diagnostic logging are strictly opt-in and stored only in private app storage.
- **User Control**: Users can wipe all application data, logs, and stored cookies at any time directly from Settings.
