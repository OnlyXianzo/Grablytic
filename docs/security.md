# Security & Privacy Policy

Grablytic has no accounts, no telemetry and no analytics SDK. This page covers
what is stored, what leaves the device, and how to report a vulnerability.

## Supported Versions

| Version | Supported |
|---|---|
| 0.0.x (main) | :white_check_mark: |
| < 0.0.1 | :x: |

## Reporting a Vulnerability

Report a vulnerability privately:

1. **GitHub Security Advisory**: Use the [Private Vulnerability Reporting](https://github.com/OnlyXianzo/Grablytic/security/advisories/new) feature on GitHub to submit a confidential report.
2. Include reproduction steps, affected versions and platforms, and any
   mitigation you already see.
3. **Do not** open a public issue or discussion for a vulnerability.
4. Reports are acknowledged and a fix is coordinated before public disclosure.

## Trust Model

| Asset | Storage Location | Accessibility |
|---|---|---|
| Session cookies (`cookies.txt`, 0600) | App-private storage | App only (sandboxed) |
| Non-secret settings and presets | SharedPreferences (private) | App only |
| Proxy credentials | `flutter_secure_storage` (Android Keystore-backed) | App only; not stored in history JSON |
| Download history | App-private SQLite database | App only; proxy fields are scrubbed |
| Diagnostic logs (`app_logs.txt`) | App-private logs directory | App only (tokens redacted) |
| Exported logs | User-selected folder / Downloads | User only |

### Threat boundaries

- **Defended against:** malicious shared URLs and payload files, archive
  traversal, network interception (TLS for every request), and cross-app
  inspection (Android sandbox, `0600` files). Every binary the bootstrapper
  installs and the pinned yt-dlp wheel are SHA-256 verified against the
  manifest. Media downloads are not: yt-dlp fetches them over TLS and there is
  no trusted digest to compare against.
- **Out of scope:** OS or root compromise, and a zero-day in an upstream
  dependency before that upstream ships a patch.

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

## In-app bug and crash reports

Reports are captured locally, redacted, and only sent when the user says so.

1. A Flutter framework error, an uncaught Dart error, or an unexpected Python
   engine exit is turned into a redacted draft and written to
   `<app>/reports/<id>.json`. **No network call happens on this path.** The
   handler returns as soon as the file is written.
2. On the next launch the shell shows a dismissible banner offering
   **Not now / Review report / Send report**. The same report is reachable at
   **Settings → Report a problem**.
3. The form shows the user's own description, a category, and a *Review
   included information* panel with the exact text that would be filed.
4. Sending opens a prefilled `github.com/.../issues/new` page. A build that was
   deliberately compiled with a token may post through the API instead; in that
   case the app only reports success when GitHub returned an issue URL.

Capture is **not** gated on the auto-send switch. Otherwise an install that
left it off would lose every crash, which is what used to happen. The switch
only decides whether a queued crash may be filed without asking, and it is off
by default.

### What a report contains

| Included | Removed before the report is written |
|---|---|
| Exception type, message, first stack frame | Whole URLs (`[URL removed]`) |
| Stack trace, bounded to 6 KB | Absolute file paths, including account names (`[local path removed]`) |
| App version, platform, Dart/Flutter version, timestamp | `Authorization` / `Proxy-Authorization` / `Cookie` / `Set-Cookie` header values |
| Category and session state | `token=`, `sig=`, `key=`, `password=`, `session=` and similar query parameters (via `AppLogger.redact`) |
| Recent app log tail, bounded | Nothing, it is already scrubbed line by line |

**Not collected at all:** download history, media files, cookies, tokens,
personal files, and command-line arguments.

Redaction is applied when the draft is built, again at `_buildBody`, when the
short summary is stored in the queue, and once more inside `issueUrl` and
`createIssue`. The last two are the points where a report leaves the app, so a
caller that forgets to scrub the title or body still cannot leak one. Labels
are passed through unchanged: keep them to the fixed `bug`-style set and never
route free text there.
It **fails closed**: if the scrubber throws, the field becomes
`[diagnostics omitted: safe redaction failed]` rather than the original text.
The trade-off is deliberate and documented: because whole URLs are stripped, a
download-failure report cannot name the site that failed. The log tail and the
user's own description are the diagnostic value.

### Queue limits

At most three reports are kept, each body capped at 64 KB; a repeat of the same
fingerprint inside seven days collapses into one report with an occurrence
count; the recovery banner mentions a given report no more than once every
three days. Writes are atomic (`.tmp` + rename), so a process killed mid-write
leaves no half-parsed report. A submission failure keeps the text and bumps an
attempt counter.

## Python engine auto-reporting (developer/CLI only)

This is the engine's own notifier, not the user-facing path above. It is
disabled unless both of these are true, and a normal install sets neither:
Android never passes environment variables to the embedded interpreter, and no
token ships in the APK.

**Auto-reporting is OFF by default.** A crash report is only filed when
`GRABLYTIC_AUTO_REPORT=1` is set in the environment AND a `GITHUB_TOKEN`
with issue-write access is available. Neither is set in a normal install,
so a stock build never contacts GitHub.

When a build *does* enable it, the following is filed as a **public**
GitHub issue against the configured repository (default
`OnlyXianzo/Grablytic`):

| Included | Redacted before it leaves the device |
|---|---|
| Exception type and message | URL userinfo passwords (`user:***REDACTED***@host`) |
| Full traceback frames | `token=` / `sig=` / `lsig=` / `key=` / `auth=` query parameters |
| Tail of `server_logs.log` (up to 15 KB) | The same parameter names as query strings, plus dict keys matching `cookie`, `token`, `password`, `secret`, `auth`, `proxy`, `api_key`, `session`, `po_token` |
| Platform versions (OS, Python, yt-dlp) | Nothing |
| The IPC method that failed | Nothing |

**What is NOT redacted:** the URL path and query parameter *names*, the
video/channel identifiers in a URL, and file names. If you need those
gone too, disable the log tail with `GRABLYTIC_REPORT_LOG_TAIL=0`.

### Configuration

| Variable | Purpose | Default |
|---|---|---|
| `GRABLYTIC_AUTO_REPORT` | `1` enables auto-filing | unset (off) |
| `GITHUB_TOKEN` | Token used to file the issue | unset (manual mode) |
| `GRABLYTIC_REPORT_REPO` | Target `owner/repo` for reports | `OnlyXianzo/Grablytic` |
| `GITHUB_REPO` | Generic repo override (lower priority) | unset |
| `GRABLYTIC_REPORT_LOG_TAIL` | `0` keeps the log tail out of the report | `1` |

If the target repository is renamed or deleted, the notifier logs a
warning once and drops the report. It does not fail silently and it
does not retry against a different repository.

## Privacy Standards

- **No account, no telemetry, no ads.** Nothing identifies the install.
- **Opt-in storage.** Cookies and logins are optional and live in private app
  storage, never in the settings blob.
- **User control.** Settings can wipe app data, logs and stored cookies.
