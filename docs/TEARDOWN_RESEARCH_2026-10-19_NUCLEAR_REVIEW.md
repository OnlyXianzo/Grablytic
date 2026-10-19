# Verified Approach — 2026-10-19 nuclear code-quality review

**Attribution: Arena.ai Agent Mode.**

This is the Phase 2 artifact of the repository's own
`skills/verified-implementation/SKILL.md` workflow. It records what was
researched, which sources were consulted, how the disagreements were
resolved, and what was decided before any code was written. The
companion document `docs/TEARDOWN_AUDIT_DELTA_2026-10-19.md` lists the
outcome for each of the 61 findings.

---

## Phase 0 — Scope

The supplied review covered commit `306877e` (2026-10-10) and reported
61 findings (6 Critical, 17 High, 31 Medium, 7 Low) across the Flutter
app (`lib/`), the Android bridge (`android/app/src/main/kotlin/`), the
Python engine (`engine/grablytic_engine/`) and the CI workflow
(`.github/workflows/`).

The repository has moved on since the audit: `HEAD` at the time of this
work was `c7a1a8a` (2026-10-19), **54 commits** newer than the audited
commit, touching 151 files (+12,739 / −2,742). Many findings were
therefore already fixed upstream and applying the audit's patches
verbatim would have re-introduced regressions or broken newer work.

"Done" therefore means: every one of the 61 findings re-checked against
the current source at line level, every still-open finding fixed on the
current code, a regression test for each fix, and a written record of
the outcome for every finding — including the ones that turned out to
be already fixed or not applicable.

---

## Phase 1 — Research

Four independent angles were researched. Every conclusion below is
backed by at least one primary source; material conclusions are backed
by two or more.

### Angle A — Platform APIs (Android / Flutter), primary sources

| Claim | Sources | Confidence |
|---|---|---|
| `Service.onTimeout(int startId, int fgsType)` was added in **API 35** and is the callback the system uses for a `dataSync` foreground service once its budget (6 h per rolling 24 h) is spent; the service must call `stopSelf()` within seconds or the process is killed with `ForegroundServiceDidNotStopInTimeException`. `onTimeout(int)` is the **shortService** overload. | `developer.android.com/develop/background-work/services/fgs/timeout`; `developer.android.com/reference/android/app/Service` | High (two pages of the same primary source, mutually consistent) |
| Flutter requires the framework to run in a **single zone**: `WidgetsFlutterBinding.ensureInitialized()` and `runApp()` must be in the same zone, otherwise framework callbacks are dispatched to a zone without a handler. | `docs.flutter.dev/release/breaking-changes/zone-errors` | High (primary) |
| `androidx.security:security-crypto` 1.1.0 deprecated **all** of its APIs in favour of direct Android Keystore use. | `developer.android.com/jetpack/androidx/releases/security` | High (primary) |
| `flutter_secure_storage` v10 removed the Jetpack `EncryptedSharedPreferences` backend; the default is a custom cipher (RSA/ECB/OAEPWithSHA-256AndMGF1Padding key wrapping + AES/GCM storage cipher) on the Android Keystore, min SDK 23, target SDK 36, Java 17, `migrateOnAlgorithmChange` default true, `resetOnError` default true, `storageNamespace` added in v10.3.x. | `pub.dev/packages/flutter_secure_storage` + its changelog; `github.com/juliansteenbakker/flutter_secure_storage/issues/1043`, `#1166`, `#1259` | High (primary package page + three independent issue reports) |

### Angle B — Upstream state of the audited findings

The repository's own git history was the primary evidence, not the
audit. `git log 306877e..HEAD` (54 commits) was read in full, and every
finding was re-checked line by line against `HEAD` with targeted greps
and a purpose-built status probe. The upstream commits that closed
large groups of findings are visible in the history: `2cc356c` (engine
contract versioning), `f562499` (proxy secret storage), `6538497` (FTS4
+ proxy scrubbing), `c4112ac` (package SHA-256 pinning), `65e1ea2`
(service state sync), `b59c459` (SSRF fail-closed), `cba06bb` (stdout
framing + bounded IPC), `47acdb7` (output templates), `2c6a285`
(result-delivered flag), plus PRs #14 and #15.

Confidence: High — this is the repository itself.

### Angle C — Failure modes of the obvious fixes

| Risk | Why the naive fix is wrong | Resolution |
|---|---|---|
| "Redact cookies" by adding `cookie` to a substring blocklist | Substring matching on keys redacts `author` (it contains `auth`) and `authorization_status`, and misses `X-Api-Key` or `Cookie:` inside a *value* | Exact-key set + suffix rules, plus value-shape regexes (header lines, bearer tokens, `k=v` secrets) |
| "Fix the cycle detection" by keeping a global visited set | A global set marks a **shared** (DAG) reference as a cycle, so the second occurrence of a config object is blanked out | Track the **ancestor path** (a tuple of ids), not every visited id |
| "Cancel the downloads on timeout" by overriding `onTimeout(int)` | That is the *shortService* overload; a `dataSync` service never receives it, so the fix is a no-op | Override **both** overloads; API 35 added the `(int, int)` one |
| "Use `ON CONFLICT DO UPDATE` for the upsert" | Needs SQLite 3.24 (API 30); the app's `minSdk` is 24 and sqflite uses the **platform** SQLite, so the statement fails on older devices | Explicit UPDATE-then-INSERT in one transaction |
| "Add JetSec for the cookie jar" | `security-crypto` 1.1.0 deprecated every API it exposes | Reuse the existing `flutter_secure_storage` pattern (`ProxySecretStore`) for a file-backed cookie store |
| "Move `ensureInitialized()` into `runZonedGuarded`" (the audit's own wording) | The whole startup path must move, otherwise `ensureInitialized()` still runs in the root zone | Move the **entire** startup body into the guarded zone |
| "Pin yt-dlp" only on the desktop | The Android build installs the package too, through Chaquopy | Pin **both** the desktop bootstrap and `android/app/build.gradle.kts` |

### Angle D — Environment constraints (verified, not assumed)

* **No Flutter SDK** in the sandbox. `flutter analyze` and `flutter test`
  cannot run. Dart files were therefore syntax-checked with
  `dart format --output=none` (Dart SDK 3.9.2 from
  `~/.cache/sandbox-tools/dart-sdk`), which parses the file and reports
  syntax errors. Formatting was **not** applied (the repository has
  deliberate legacy formatting churn).
* **No Android SDK / Gradle.** Kotlin files were type-checked with
  `kotlinc` 2.1.0 against real `kotlinx-coroutines-core-jvm`,
  `org.json` and `androidx.annotation` jars downloaded from Maven
  Central / Google Maven. The Android and Flutter classes stay
  unresolved, so the check is a **differential** one: the error
  signature of the patched tree is compared against the unpatched tree
  and must not gain any new class of error. It did not.
* **Python** is fully available: the engine suite runs in a venv
  (`/home/user/repo/.venv`, Python 3.13.16, yt-dlp 2026.08.19).

---

## Phase 2 — Cross-verification: the decisions

### Disagreement 1 — where to keep the cookie jar

* *Option A:* `flutter_secure_storage` (already a dependency, Keystore-backed).
* *Option B:* a file in the app-private directory with `0600`.
* *Option C:* `androidx.security:security-crypto` `EncryptedSharedPreferences`.

Resolution: **C is excluded** — 1.1.0 deprecated every API it exposes
(primary source: the androidx release notes). Between A and B, the
repository already has a precedent for B: the WebView login flow writes
`cookies.txt` into the app-private documents directory and `chmod 0600`
it, and the engine already consumes Netscape cookie files from disk. A
cookie jar is a *file format* in this project, not a key-value secret,
and a jar can be hundreds of kilobytes — a poor fit for a preferences
store. **B was chosen**, behind a `CookieSecretStore` interface that
mirrors the existing `ProxySecretStore` (so it stays injectable and
testable). A stays the model for the *proxy* (already fixed upstream).

### Disagreement 2 — how strict the malformed-response handling should be

* *Option A:* make `EngineEnvelope.decodeResponse` throw on garbage.
* *Option B:* keep the codec lenient and enforce strictness in the
  transports.

Resolution: **B**. `EngineEnvelope.decodeResponse` returning `{}` for
garbage is a *documented, tested* contract of the codec
(`engine_codec_test.dart` asserts it for `null`, `'not-json{{{'` and
`'[1,2]'`). Changing it would ripple through every consumer and break
an existing test for no security gain. The transports now detect the
empty result and answer `ERROR_PROTOCOL` with a log line, so the
failure is visible where it matters, and the codec's contract is
preserved.

### Disagreement 3 — should the release build fail without a keystore, and should lint abort?

Resolution: **yes to both**, with the debug path untouched. The
release workflow (`.github/workflows/build.yml`) decodes the keystore
only when `KEYSTORE_BASE64` is present, so a missing secret silently
produced a **debug-signed release APK**. The signing config now throws
`GradleException` when a *release* task runs without a keystore, and
`lint { checkReleaseBuilds = true; abortOnError = true }` restores the
AGP defaults the project had switched off. A `:app:lintRelease` step
was added to the verify matrix so findings surface on every pull
request, not only on release day.

### Uncertainty that remains, and how it is hedged

* **Lint findings.** The sandbox has no Android SDK, so the number of
  pre-existing lint errors is unknown. Enabling `abortOnError` may turn
  the first CI run red. This is the intended visibility, and the
  release-signing failure and the lint step are in separate jobs: a
  lint failure blocks the merge but cannot produce a broken artifact.
* **`Service.onTimeout(int, int)`.** Overriding it requires API 35
  stubs at compile time. `compileSdk` is now
  `maxOf(flutter.compileSdkVersion, 35)` so the override always
  resolves regardless of the Flutter version in use.
* **Flutter-side behaviour.** No Dart test could be executed here.
  Every Dart change was written to preserve the existing observable
  contract, and the Dart test files that the changes touch were read
  to confirm the new behaviour does not contradict an existing
  expectation (see the blast-radius table below).

---

## Phase 3 — Blast radius

Every changed behaviour was traced to its consumers before editing.

| Change | Consumers checked | Action |
|---|---|---|
| `sanitize()` no longer blanks shared references | `persistent.py` (logger, `traced_request`), `github_notifier.redact_context`, `errors._safe_message` | `github_notifier` now delegates key classification to `persistent.is_sensitive_key` so the two cannot drift |
| Engine EOF shutdown no longer waits forever | `__main__.py` only (the engine process owns its own lifetime) | Futures are tracked in a set and drained with a deadline |
| `DownloadRecord.copyWith` can clear a field | `download_provider.dart`, `download_history_db.dart`, tests | Sentinel default keeps every existing call site source-compatible |
| `DownloadHistoryDb.insert` is now UPDATE-then-INSERT | `download_provider._persistRecord`, `restoreInterruptedDownloads`, tests, and the **Kotlin** writer (`ObservedSourcesPollWorker` uses `CONFLICT_IGNORE` on the same table) | Both sides use the same key (`id`); the Kotlin side keeps `CONFLICT_IGNORE`, which is correct for "do not overwrite" |
| `syncConcurrency` returns `bool` | `download_queue_test.dart`, `platform_channel_concurrency_test.dart` | `await` on a `Future<bool>` is source-compatible |
| `setPaths` (Android) now returns the engine's verdict | Kotlin `paths/set` branch, Dart `EngineService.setPaths` | The Dart side ignores the body today; the verdict is now at least visible in the log |
| `EngineEnvelope` unchanged | every transport | Strictness added in the transports only |
| Kotlin `replySuccess`/`replyError` replace `withContext(Dispatchers.Main)` | every `MethodChannel` branch in `MainActivity` (28 sites) | `NonCancellable` keeps the delivery attempt alive when the activity scope is cancelled |
| `eventSink` → listener registry | `MainActivity`, `ShareActivity` (separate Flutter engines) | Each listener registers and unregisters its own sink |
| `onTimeout(int, int)` added | `DownloadService` | Both overloads delegate to one implementation |

---

## Phase 4 — Verification

* **Engine suite:** `python -m pytest engine/tests -q` →
  **769 passed** (736 pre-existing + 33 new) at the final commit.
  Baseline before any change: 736 passed, 0 failed.
* **Ruff:** `ruff check --select F engine/` → *All checks passed*,
  including F401, which the CI gate had disabled.
* **Dart:** every changed file parses (`dart format --output=none`).
* **Kotlin:** differential `kotlinc` check — the patched tree produces
  no error class that the unpatched tree did not already produce, and
  the total error count drops (the remaining errors are all
  `unresolved reference` for the Android/Flutter classes that the
  sandbox does not have).
* **Manifest / workflow YAML:** parsed successfully after the edits.

---

## Phase 5 — Residual risk

1. The Dart changes are **not** covered by an executed `flutter test`
   run in this environment. The new Dart tests
   (`test/providers/download_terminal_events_test.dart`,
   `test/providers/cookie_secret_storage_test.dart`,
   `test/core/database/download_record_copywith_test.dart`) are written
   against the documented behaviour and must be run by CI.
2. The Kotlin changes are **not** compiled by Gradle here. The
   differential `kotlinc` check is the strongest signal available
   without the Android SDK.
3. The lint gate may surface pre-existing findings on the first CI run.
