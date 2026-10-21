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
| Non-secret settings and presets | SharedPreferences (private) | App only |
| Proxy credentials | `flutter_secure_storage` (Android Keystore-backed) | App only; not stored in history JSON |
| Download history | App-private SQLite database | App only; proxy fields are scrubbed |
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

## Bug and crash reports (opt-in, reviewed before sending)

Grablytic records a crash report locally and offers it on the next launch.
Nothing is sent without the user pressing a button.

The path in the app:

1. An unhandled error (Flutter framework error, uncaught Dart error, or an
   unexpected Python engine exit) is turned into a **redacted** report and
   written to `<app>/reports/<id>.json`. No network call happens here — the
   handler returns immediately.
2. On the next launch, the shell shows a dismissible banner: *"Grablytic ran
   into a problem last time."* with **Not now / Review / Send report**. The
   same report is reachable at **Settings → System & Diagnostics → Report a
   problem**.
3. The report form shows what happened in the user's own words, one of five
   categories, and a *What will be included* panel containing the exact issue
   text. The user can read all of it before sending.
4. Sending either files the issue through the GitHub API (only when the build
   was compiled with a token) or opens a prefilled `issues/new` page in the
   browser. In the second case the app says so — it never claims a submission
   it could not confirm, and the report stays in the local list until the user
   removes it.

**Auto-sending is OFF by default.** The setting *Send crash reports
automatically* (Settings → System & Diagnostics) is the only thing that lets a
queued crash be filed without asking. Even then the body is the same redacted
one the review panel shows. Recording a report locally is not gated on that
setting; otherwise the next launch would have nothing to offer.

### What is in a report

| Included | Redacted before it is written to disk |
|---|---|
| Exception type, message, and first stack frame | URL userinfo passwords (`user:***REDACTED***@host`) |
| Full stack trace, bounded to 6 KB | `Authorization`, `Cookie`, `Set-Cookie`, `X-Api-Key`, `X-Auth-Token` header values |
| App version/build, platform, Flutter version, timestamp | `token=`, `sig=`, `lsig=`, `key=`, `password=`, `session=`, `po_token=`, `credential=` and similar assignments, in query strings and free text |
| Recent app log tail, bounded to 12 KB (a tail, not a head) | Bare `Bearer`/`Basic` credentials |
| Category, session/recovered flags, the IPC method or subsystem | The account name in `/home/<name>/…`, `/Users/<name>/…` and `C:\Users\<name>\…` |

**Not collected at all:** download history, media, cookies, authentication
headers, tokens, personal files, and full command-line arguments.

**Unknown fields are not assumed safe.** Values in the report's context map are
scrubbed even when their key looks harmless, and redaction **fails closed**: if
the scrubber throws on a pathological input, the field becomes
`[content withheld — redaction failed]` instead of the original text.

Reports are redacted before they are persisted, so the files in `<app>/reports`
are already safe to attach to an issue by hand. Submission re-runs the scrubber
at the network boundary, and the clipboard copy of a report is the redacted one.

### Limits of the queue

At most three reports are kept, each body capped at 64 KB; a repeat of the same
fingerprint within seven days collapses into one report with an occurrence
count; the recovery banner mentions a given report no more often than every
three days. Writes are atomic (`.tmp` + rename), so a process killed mid-write
leaves no half-parsed report. A failed submission keeps the user's text and
increments an attempt counter rather than discarding it.

### Python engine (developer/CLI path)

The engine has its own notifier for exceptions raised while handling an IPC
request. It is a developer tool, not the user-facing path: it requires
`GRABLYTIC_AUTO_REPORT=1` in the environment **and** a `GITHUB_TOKEN`, and
neither is set in a normal install — nor can it be, since Android never passes
environment variables to the embedded interpreter and no token is shipped in
the APK. The in-app preference above governs the Flutter path only; the engine
notifier cannot file anything without its own explicit environment.

When it is configured, it files a **public** GitHub issue against
`OnlyXianzo/Grablytic` (overridable) containing the exception, traceback, log
tail (up to 15 KB) and platform versions, redacted by the same shared scrubber
(`persistent.scrub_text`) the on-disk logger uses.

| Variable | Purpose | Default |
|---|---|---|
| `GRABLYTIC_AUTO_REPORT` | `1` enables auto-filing | unset (off) |
| `GITHUB_TOKEN` | Token used to file the issue | unset (manual mode) |
| `GRABLYTIC_REPORT_REPO` | Target `owner/repo` for reports | `OnlyXianzo/Grablytic` |
| `GITHUB_REPO` | Generic repo override (lower priority) | unset |
| `GRABLYTIC_REPORT_LOG_TAIL` | `0` keeps the log tail out of the report | `1` |

If the target repository is renamed or deleted, the notifier logs a
warning once and drops the report — it does not fail silently and it
does not retry against a different repository.

## Privacy Standards

- **Anonymous by Default**: No user accounts, no telemetry, no tracking, and no advertisements.
- **Opt-in Storage**: Cookies, logins, and diagnostic logging are strictly opt-in and stored only in private app storage.
- **User Control**: Users can wipe all application data, logs, and stored cookies at any time directly from Settings.
