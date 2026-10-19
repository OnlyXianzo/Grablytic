# Audit delta — 2026-10-19 nuclear code-quality review (61 findings)

**Attribution: Arena.ai Agent Mode.**

| | |
|---|---|
| **Repository** | `https://github.com/OnlyXianzo/Grablytic` |
| **Audited commit** | `306877e` (2026-10-10) |
| **Base of this work** | `c7a1a8a` (2026-10-19) — 54 commits newer than the audit |
| **Branch** | `fix/nuclear-review-2026-10-19` |
| **Findings in the report** | 61 = 6 Critical, 17 High, 31 Medium, 7 Low |
| **Outcome** | **35** fixed outright here · **9** finished here (a partial upstream fix completed: #6, #22, #25, #46, #47, #50, #52, #55, #61) · **16** already fixed upstream · **1** already fixed upstream and hardened here (#2) — **61 of 61 accounted for** |

The audit targets a commit that is **54 commits behind** `HEAD`. Every
finding was therefore re-checked against the current source at line
level before anything was changed; the audit's own patches were not
applied blindly. The companion document
`docs/TEARDOWN_RESEARCH_2026-10-19_NUCLEAR_REVIEW.md` records the
research, the disagreements and the blast-radius analysis behind these
decisions.

---

## 1. Summary table

Status key: **FIXED** = changed on this branch · **UPSTREAM** = already
fixed before this branch started (no change needed) · **DONE (partial
→ complete)** = was partially fixed upstream, finished here.

| # | Sev | Finding | Status | Where |
|---|---|---|---|---|
| 1 | Critical | FFmpeg guard calls a nonexistent `log.warning` | UPSTREAM | `engine/grablytic_engine/downloader.py` |
| 2 | Critical | Public GitHub reports leak unsanitized exceptions | UPSTREAM (+ hardened here) | `github_notifier.py` |
| 3 | High | Auto-report blocks the stdin reader | **FIXED** | `engine/grablytic_engine/__main__.py` |
| 4 | High | Wrong Android FGS `onTimeout` overload | **FIXED** | `DownloadService.kt` |
| 5 | High | Android `paths/set` discards the fail-closed verdict | **FIXED** | `MainActivity.kt` |
| 6 | Critical | Plaintext cookies / proxy credentials | **FIXED** (proxy was UPSTREAM) | `settings_provider.dart`, `cookie_secret_store.dart` |
| 7 | High | Unknown terminal ID mutates the last download | **FIXED** | `download_provider.dart` |
| 8 | High | `redownload()` fabricates state / swallows rejection | **FIXED** | `download_provider.dart` |
| 9 | High | Cancel marks a refused cancel as "cancelling" | **FIXED** | `download_provider.dart` |
| 10 | High | Thread registered after `start()` permits over-admission | **FIXED** | `downloader.py` |
| 11 | Medium | Unbounded IPC executor queue | UPSTREAM | `__main__.py` |
| 12 | Medium | EOF shutdown waits forever | **FIXED** | `__main__.py` |
| 13 | Medium | Retry sleep holds the concurrency permit | UPSTREAM | `downloader.py` |
| 14 | Medium | `pop(0)` and O(n) URL scans | UPSTREAM | `downloader.py`, `hooks.py` |
| 15 | Medium | Unbounded cancel-watchdog threads / FFmpeg timeout mismatch | UPSTREAM | `downloader.py` |
| 16 | Medium | Verbose yt-dlp override | UPSTREAM | `opts_builder.py` |
| 17 | High | Flutter binding outside the guarded zone | **FIXED** | `lib/main.dart` |
| 18 | High | Runtime unpinned yt-dlp / PATH pip | **FIXED** | `desktop_engine_service.dart`, `build.gradle.kts` |
| 19 | High | Python resolved from the current directory | **FIXED** | `desktop_engine_service.dart` |
| 20 | Critical | SSRF guard fails open | UPSTREAM | `url_guard.py` |
| 21 | Medium | Unbounded resume `.info.json` loading | **FIXED** | `resume.py` |
| 22 | High | Notification stop / `onDestroy` does not cancel downloads | **FIXED** (partial → complete) | `DownloadService.kt` |
| 23 | Critical | Fourteen Android branches never answer `MethodChannel.Result` | **FIXED** | `MainActivity.kt` |
| 24 | High | Activity-scope cancellation drops IPC replies | **FIXED** | `MainActivity.kt` |
| 25 | Medium | Two activities share a static event sink | **FIXED** (partial → complete) | `MainActivity.kt` |
| 26 | Medium | Unbounded share text | **FIXED** | `ShareActivity.kt` |
| 27 | Medium | Substring playlist detection | UPSTREAM | `playlist.py` |
| 28 | Medium | Collision-prone output template | UPSTREAM | `opts_builder.py` |
| 29 | Medium | Remote profile validation / body / size / write | UPSTREAM | `site_profiles.py` |
| 30 | Medium | Sanitizer mistakes shared references for cycles | **FIXED** | `persistent.py` |
| 31 | Medium | Redactor misses headers and over-redacts `author` | **FIXED** | `persistent.py`, `github_notifier.py` |
| 32 | Medium | Wildcard `LIKE` history search | UPSTREAM (FTS4 primary) | `download_history_db.dart` |
| 33 | Medium | `copyWith` cannot clear nullable fields | **FIXED** | `download_history_db.dart` |
| 34 | Medium | Local timestamps without an offset | **FIXED** | `download_history_db.dart`, `download_provider.dart` |
| 35 | Medium | SQLite `REPLACE` upsert deletes and reinserts | **FIXED** | `download_history_db.dart` |
| 36 | Medium | O(n²) startup restore | **FIXED** | `download_provider.dart` |
| 37 | Medium | Progress events rebuild the full list | **FIXED** | `download_provider.dart` |
| 38 | Medium | Cleanup relies on `Queue.empty()` | UPSTREAM | `downloader.py` |
| 39 | Medium | Signed URLs in logs | **FIXED** | `url_guard.py`, `formats.py`, `playlist.py` |
| 40 | Medium | YouTube host substring check | **FIXED** | `url_guard.py`, `formats.py`, `playlist.py`, `opts_builder.py` |
| 41 | Medium | Binary probe blocks before its timeout | **FIXED** | `BinaryPackageManager.kt` |
| 42 | Medium | Wake-lock syscalls on the main thread | UPSTREAM | `DownloadService.kt` |
| 43 | Medium | Global `PATH` / `LD_LIBRARY_PATH` mutation | **FIXED** | `paths.py` |
| 44 | Medium | Active callback leak | **FIXED** | `MainActivity.kt` |
| 45 | High | JSON substring success detection | **FIXED** | `MainActivity.kt` |
| 46 | High | MethodChannel / desktop request timeout gaps | **FIXED** (desktop was partial) | `platform_channel_engine_service.dart`, `desktop_engine_service.dart` |
| 47 | High | Malformed response maps to `{}` | **FIXED** (partial → complete) | `platform_channel_engine_service.dart`, `desktop_engine_service.dart` |
| 48 | Medium | All yt-dlp error progress events marked recoverable | **FIXED** | `hooks.py` |
| 49 | Medium | Watchdog closes the slot during the FFmpeg merge | UPSTREAM | `downloader.py` |
| 50 | Medium | Concurrency-setting errors swallowed | **FIXED** (partial → complete) | `download_provider.dart`, `settings_screen.dart` |
| 51 | High | CI lacks an Android compile / coverage floor | UPSTREAM | `.github/workflows/verify.yml` |
| 52 | Medium | CI docs / coverage mismatch and F401 disabled | **FIXED** (partial → complete) | `verify.yml`, `AGENTS.md`, `engine/**` |
| 53 | Medium | Unknown / pending response IDs silently dropped | **FIXED** | `desktop_engine_service.dart` |
| 54 | High | Unredacted secrets in the SQLite config JSON | UPSTREAM | `download_history_db.dart` |
| 55 | Low | Unused `deque` / imports / parameters | **FIXED** (mostly UPSTREAM) | `downloader.py`, `resume.py` |
| 56 | Low | Debug-signed release fallback / lint disabled | **FIXED** | `build.gradle.kts`, `verify.yml` |
| 57 | Low | Unconstrained HTTPS intent filter | **FIXED** | `AndroidManifest.xml` |
| 58 | Low | Traced result deep-copied before truncation | **FIXED** | `persistent.py` |
| 59 | Low | UI index stored as the queue position | **FIXED** | `download_provider.dart` |
| 60 | Low | Unnecessarily exported `BootReceiver` | **FIXED** (see §4) | `AndroidManifest.xml` |
| 61 | Low | Broad catch/except handling hides failures | **FIXED** (partial → complete) | `platform_channel_engine_service.dart`, `__main__.py` |

---

## 2. Fixed on this branch

Each entry states the defect, the change, and the test that locks it
down. Test files referenced as "new" were added by this branch.

### 3 — Auto-report blocks the stdin reader *(High)*
`notify_exception()` performs up to two blocking HTTPS calls (a
duplicate search with a 15 s timeout and an issue create with a 20 s
timeout). It ran inline in the stdin reader, so one crash stalled every
subsequent request for up to ~35 s — the fast lane (cancel, queue
status) was held hostage by an unrelated failure.
**Fix:** the reader only *enqueues*. A dedicated single-worker pool
performs the network call, with a one-minute minimum interval and a
five-reports-per-session cap so a crash loop cannot spam a public
repository.
**Test:** `engine/tests/test_review_2026_10_19.py` —
`test_auto_report_is_queued_not_run_inline`,
`test_auto_report_is_rate_limited`,
`test_auto_report_caps_reports_per_session`.

### 4 — Wrong Android FGS `onTimeout` overload *(High)*
The service overrode only `onTimeout(int startId)`, which is the
**shortService** overload. `Service.onTimeout(int, int)` was added in
**API 35** and is the callback the system actually uses for a `dataSync`
foreground service when its 6-hour-per-24-hour budget is spent. The
service was therefore never given the chance to stop itself: the
platform killed the process with
`ForegroundServiceDidNotStopInTimeException` and the in-flight
downloads were lost with half-written `.part` files.
**Fix:** both overloads are implemented and delegate to one
implementation that cancels the engine workers, posts the terminal
alerts, sweeps the database, releases the locks and calls `stopSelf()`.
`compileSdk` is now `maxOf(flutter.compileSdkVersion, 35)` so the
override always resolves.
**Verification:** differential `kotlinc` type-check (see §5).

### 5 — Android `paths/set` discards the fail-closed verdict *(High)*
The engine's `set_paths` fails closed on a non-absolute root — the root
is the trust anchor for every derived path. The Kotlin branch threw that
verdict away and answered `{"success": true}` unconditionally, so the
app believed it was configured while the engine had rejected the paths.
**Fix:** the branch now returns the engine's own answer
(`pyJson(setPathsResult)`).

### 6 — Plaintext cookie jars *(Critical, cookie half)*
A cookie jar is a bearer credential: whoever holds the `SID` cookie
holds the session. The jar was stored as plaintext JSON in
SharedPreferences, next to the app's ordinary settings, in a file any
process with the app's uid can read.
**Fix:** the jar moved to an app-private file with `0600` permissions —
the same pattern the WebView login flow already uses for
`cookies.txt`. SharedPreferences keeps only the profile *metadata* (id,
url, description, enabled flag). A legacy plaintext jar is migrated
into the secret store on startup and removed from the preferences; a jar
that cannot be secured is dropped rather than left in the clear.
`jetpack.security` (`androidx.security:security-crypto`) was considered
and **rejected**: version 1.1.0 deprecated every API it exposes.
**Test:** `test/providers/cookie_secret_storage_test.dart` (new) — three
cases covering the write, the migration and the delete.
**Note:** the *proxy* half of this finding was already fixed upstream
(`ProxySecretStore` + `flutter_secure_storage`).

### 7 — Unknown terminal ID mutates the last download *(High)*
The terminal handlers looked the item up with
`firstWhere(..., orElse: () => state.last)`. When the id was gone
(deleted from history while running, a not-yet-restored item, a late
duplicate from the cancel watchdog) the fallback returned an
**unrelated** item, which was then persisted and reported to the resume
strike store — corrupting that other download's attempt counter. With
an empty list, `state.last` threw inside the event listener.
**Fix:** `_applyTerminal()` returns null for an unknown id and logs one
diagnosable line. No fallback.
**Test:** `test/providers/download_terminal_events_test.dart` (new).

### 8 — `redownload()` fabricates state / swallows rejection *(High)*
The item was optimistically set to `downloading` **before** the engine
answered, and the engine's verdict was discarded. A rejected start
(`ERROR_INVALID_PARAM` from the SSRF gate, `ERROR_QUEUE_FULL`,
`ERROR_DUPLICATE_URL`, `ERROR_SHUTTING_DOWN`, `ERROR_TRANSPORT`) never
produces a terminal event, so the card sat at 0 % for ever while the
database heartbeat kept writing `status='downloading'`.
**Fix:** an honest `pending` intermediate, then the engine's verdict
decides `downloading` / `queued` / a local `error`.
**Test:** `test/providers/download_terminal_events_test.dart` (new).

### 9 — Cancel marks a refused cancel as "cancelling" *(High)*
The cancel reply was discarded. When the engine answered
`ERROR_DOWNLOAD_NOT_FOUND` (the id had already been reaped) no terminal
event ever arrives, so the row stayed `cancelling` for ever.
**Fix:** the reply is awaited; a refusal closes the row locally with
`ERROR_CANCELLED`.
**Test:** `test/providers/download_terminal_events_test.dart` (new).

### 10 — Thread registered after `start()` permits over-admission *(High)*
The worker handle was published **after** `t.start()` returned. A cancel
landing in that window saw `worker_thread is None`, took the
"threadless" branch, closed the slot and admitted the next entry while
the thread was already running yt-dlp.
**Fix:** the handle is published under the lock, before `start()`.
**Test:** `test_review_2026_10_19.py` —
`test_thread_handle_is_published_before_start`.

### 12 — EOF shutdown waits forever *(Medium)*
`with ThreadPoolExecutor(...)` calls `shutdown(wait=True)`, which waits
for **every** submitted future. A 500-item playlist extraction kept the
engine alive for minutes after its parent exited, and the graceful
`shutdown_downloads` budget never even started.
**Fix:** an explicit pool; on EOF the queued futures are cancelled and
the running ones are drained with a hard deadline.
**Test:** `test_review_2026_10_19.py` —
`test_shutdown_pool_cancels_and_drains_with_deadline`.

### 17 — Flutter binding outside the guarded zone *(High)*
`WidgetsFlutterBinding.ensureInitialized()` ran in the root zone and
`runApp()` inside `runZonedGuarded`. Flutter requires the framework to
run in a single zone, so the framework callbacks were dispatched to a
zone with no handler: the crash reporter and the auto-report silently
missed exactly the errors they exist for.
**Fix:** the whole startup body moved inside the guarded zone.

### 18 — Runtime unpinned yt-dlp *(High)*
Both the desktop bootstrap (`pip install yt-dlp`) and the Android build
(`chaquopy { pip { install("yt-dlp") } }`) installed whatever PyPI
served at build time, with no review of the change.
**Fix:** pinned to `2026.08.19` on both sides, from one documented
constant (`EngineContract.ytDlpVersion` / the Gradle `pip` block). The
desktop fallback to a PATH `pip --user` install was removed: it
mutated the user's environment outside the app's own virtualenv.

### 19 — Python resolved from the current directory *(High)*
The interpreter probe looked at
`${Directory.current}/engine/.venv/bin/python` — the process working
directory, which on Windows is the shortcut's "Start in" folder and on
Linux whatever the launcher inherited. A `python` binary dropped into a
folder the user opened from was executed with the user's privileges.
**Fix:** only app-owned roots (the executable's directory and the app
data directory), plus an explicit `GRABLYTIC_PYTHON` override in debug
builds only.

### 21 — Unbounded resume `.info.json` loading *(Medium)*
The scan `json.load()`ed every sidecar. yt-dlp writes one per playlist
entry, and a playlist payload runs to several MB: 50 entries became 50
synchronous multi-megabyte parses inside one IPC worker.
**Fix:** a 2 MiB size cap is checked before the file is opened.

### 22 — Notification stop / `onDestroy` does not cancel downloads *(High)*
`ACTION_STOP` cleared the bookkeeping and stopped the service, but the
Chaquopy/Python worker threads kept downloading with no service behind
them. `onDestroy` did not cancel either.
**Fix:** both paths snapshot the active ids and call
`cancelActiveDownloads()`.

### 23 — Fourteen Android branches never answer `MethodChannel.Result` *(Critical)*
`val python = py ?: return@launch` left the `MethodChannel.Result`
unanswered in 14 branches: the Dart future never completed and the
caller waited for ever.
**Fix:** every branch answers with
`ERROR_ENGINE_UNAVAILABLE`.

### 24 — Activity-scope cancellation drops IPC replies *(High)*
`withContext(Dispatchers.Main) { result.success(...) }` throws before
its body runs when the coroutine has been cancelled, so a reply that
was due when the activity was destroyed never reached the Dart side.
**Fix:** `replySuccess()` / `replyError()` deliver under
`NonCancellable + Dispatchers.Main` (28 call sites).

### 25 — Two activities share a static event sink *(Medium)*
`MainActivity` and `ShareActivity` run separate Flutter engines and
both listen on the same `EventChannel` name, but the native side kept a
single static sink: the second listener silently **replaced** the
first, so while the share overlay was open the main activity's download
cards stopped receiving progress events.
**Fix:** a listener registry. Each listener registers and unregisters
its own sink; dispatch fans out to all of them.

### 26 — Unbounded share text *(Medium)*
`EXTRA_TEXT` is attacker-controlled and was handed to the Dart
entrypoint verbatim — a multi-megabyte message became a slow start or
an OOM.
**Fix:** a 32 KiB ceiling.

### 30 — Sanitizer mistakes shared references for cycles *(Medium)*
`sanitize()` kept a global "seen" set, so a config object referenced
twice (a DAG, not a cycle) was blanked out as `***CYCLIC***` on its
second occurrence.
**Fix:** the ancestor **path** is tracked (a tuple of ids), not every
visited id.
**Test:** `test_review_2026_10_19.py` —
`test_shared_reference_is_not_reported_as_a_cycle`,
`test_true_cycle_still_terminates`.

### 31 — Redactor misses headers and over-redacts `author` *(Medium)*
Key matching was a substring test, so `author` and
`authorization_status` were redacted, while an `Authorization:` or
`Cookie:` header embedded in an **exception message** was not.
**Fix:** an exact-key set plus suffix rules, and value-shape regexes
(header lines, bearer/basic tokens, `k=v` secrets, signed-URL query
parameters). The GitHub notifier — which posts **public** issues —
now delegates to the same scrubber as the on-disk logger, so the two
cannot drift.
**Test:** `test_review_2026_10_19.py` — six redaction cases.

### 33 — `copyWith` cannot clear nullable fields *(Medium)*
Every nullable parameter used `x ?? this.x`, so a caller could never
set a field back to null: a successful retry could not clear the
previous error, a deleted file could not clear the file path, and a
promoted item could not clear its queue position.
**Fix:** a sentinel object marks "not supplied".
**Test:** `test/core/database/download_record_copywith_test.dart` (new).

### 34 — Local timestamps without an offset *(Medium)*
Timestamps were local ISO strings with no zone, so lexicographic
ordering was only correct while the device stayed in one timezone, and
the column mixed in UTC strings written by the Android sweeper.
**Fix:** UTC ISO-8601 everywhere, plus a v6 → v7 migration that
rewrites the zone-less rows (idempotent: rows that already carry a zone
are left alone).
**Test:** `test/core/database/download_record_copywith_test.dart` (new).

### 35 — SQLite `REPLACE` upsert deletes and reinserts *(Medium)*
`ConflictAlgorithm.replace` (and the manual delete+insert it replaced)
deletes the old row and inserts a new one: the rowid changes, the
`downloads_fts` delete trigger fires and the FTS index is rebuilt.
`ON CONFLICT DO UPDATE` would be the natural SQL, but it needs SQLite
3.24 (API 30) and the app's `minSdk` is 24 with sqflite on the
**platform** SQLite.
**Fix:** an explicit UPDATE-then-INSERT inside one transaction.

### 36 — O(n²) startup restore *(Medium)*
The whole interrupt backlog was loaded and `state.any(...)` ran per
row, over a list that grew with every row it added, on the UI isolate.
**Fix:** a bounded read (`kMaxAutoResume * 4`) and an id `Set` instead
of a linear scan per row.

### 37 — Progress events rebuild the full list *(Medium)*
The hot path built the list with a per-element conditional even after
the index was already known.
**Fix:** `_replaceItem()` — one lookup, one list copy, one new item.

### 39 — Signed URLs in logs *(Medium)*
The exception paths concatenated the raw URL, so a signed CDN link (or a
playlist URL with an `si=` token) reached the daily JSONL, the rotating
log and any diagnostics export.
**Fix:** `url_guard.redact_url()` keeps scheme + host + path only, and
is used by the format and playlist fetchers. The free-text scrubber was
extended with a signed-URL parameter rule.

### 40 — YouTube host substring check *(Medium)*
`"youtube.com" in url` matched `https://evil.tld/?youtube.com` and
`https://notyoutube.com/...`, so unrelated hosts received the YouTube
extractor arguments.
**Fix:** `url_guard.is_youtube_url()` parses the host and matches a
suffix allowlist. Applied at all three call sites.

### 41 — Binary probe blocks before its timeout *(Medium)*
`readLine()` ran on the calling thread **before**
`waitFor(8, SECONDS)`: a binary that never wrote a line blocked the
probe for ever and the timeout was never reached.
**Fix:** the first line is read on its own thread; the process is
waited on with the timeout, and a timeout is reported as such.

### 43 — Global `PATH` / `LD_LIBRARY_PATH` mutation *(Medium)*
`set_paths()` rewrote process-global state with no lock and no way
back, and a second call with a different data directory stacked
another `PATH` entry.
**Fix:** a lock serializes the whole call, the module remembers the
entries it owns and replaces them on a reconfiguration, and
`child_env()` builds a child environment without touching the global
one.

### 44 — Active callback leak *(Medium)*
`activeCallbacks` is process-wide; an activity destroyed mid-download
left its entries behind, holding the engine callback alive.
**Fix:** the activity tracks the ids it registered and removes them in
`onDestroy`.

### 45 — JSON substring success detection *(High)*
`jsonStr.contains("\"success\": true")` decided the verdict over the
**whole** payload: a download title containing that literal text
flipped it, and a different JSON spacing slipped past the first test.
**Fix:** the payload is parsed and `success` is read as a boolean.

### 46 — MethodChannel / desktop request timeout gaps *(High)*
The platform channel had **no** timeout at all: a native handler that
never answered left the Dart future pending for ever. On the desktop
side the timer was armed only after the write returned, so a wedged
engine was never bounded.
**Fix:** per-method budgets on the platform channel (2 min for a start,
5 min for an extraction) and a timer that covers the write on the
desktop.

### 47 — Malformed response maps to `{}` *(High)*
A corrupted or truncated bridge payload became `{}`, which every caller
read as "not successful" — with no error type and no message.
**Fix:** the transports detect the empty result and answer
`ERROR_PROTOCOL` with a log line. The codec's documented
`decodeResponse` contract is deliberately unchanged (it has its own
tests).

### 48 — All yt-dlp error progress events marked recoverable *(Medium)*
`"recoverable": true` was hardcoded, so a private video or a DRM error
offered "Retry" for a failure that can never succeed, and the
geo-block / cookies guidance that `classify_error` produces was lost.
**Fix:** the event's own error text is classified.

### 50 — Concurrency-setting errors swallowed *(Medium)*
The engine's verdict on `set_concurrency` was discarded, so the UI and
the engine could disagree about the limit with no signal.
**Fix:** the notifier returns a `bool`, the settings slider logs the
rejection, and the notifier's `syncConcurrency` reports it too.

### 52 — CI docs / coverage mismatch and F401 disabled *(Medium)*
The coverage floors in the workflow (75 % Python, 30 % Flutter) already
matched the documentation — that half was fine. The F401 exclusion
(`--ignore F401`, "import audit backlog") was not: 18 unused imports
were still present.
**Fix:** all 18 removed (the one deliberate availability probe keeps
its import with a `# noqa: F401` and an explanatory comment) and the
CI gate now runs the **whole** correctness rule set. `AGENTS.md` was
updated to match.

### 53 — Unknown / pending response IDs silently dropped *(Medium)*
A response for an id the transport was not waiting for was dropped
without a word — a genuine protocol desync was invisible until a
download mysteriously never started.
**Fix:** the id is classified (a late answer to a timed-out request vs
an unknown id) and logged accordingly; the timed-out set is bounded.

### 55 — Unused `deque` / imports / parameters *(Low)*
The `deque` import **is** used (`downloader.py:1063`) and there are no
unused `enumerate` indexes, so most of this finding was already
handled upstream. The one real leftover was the `max_files` parameter of
`scan_resume_candidates`, which was accepted and then ignored.
**Fix:** `max_files` is honoured (resolved at call time so the module
constant stays overridable), and the 18 unused imports are gone (§52).

### 56 — Debug-signed release fallback / lint disabled *(Low)*
`signingConfig = ... ?: signingConfigs.getByName("debug")` produced a
**debug-signed release APK** whenever the keystore secret was missing,
with no warning. `lint { checkReleaseBuilds = false; abortOnError =
false }` disabled the lint gate entirely.
**Fix:** a release task without a keystore now fails with a clear
message; lint runs on release builds and its errors abort the build; a
`:app:lintRelease` step was added to the verify matrix.

### 57 — Unconstrained HTTPS intent filter *(Low)*
`<data android:scheme="https"/>` made the app a candidate handler for
**every** https link on the device — a bank login, a news article, a
private document.
**Fix:** the filter names the media hosts the app can actually handle
(YouTube, Vimeo, Twitter/X, Instagram, Twitch, Bilibili).

### 58 — Traced result deep-copied before truncation *(Low)*
`traced_request` sanitized (deep-copied) the **whole** result and then
threw away everything past 500 characters, so an 80-format payload was
copied in full on every request.
**Fix:** the preview is bounded first, then the bounded slice is
sanitized.

### 59 — UI index stored as the queue position *(Low)*
`_persistRecord` stored the item's **index in the UI list** in the
`queuePosition` column (computing it twice, two O(n) scans), and the
startup restore then ordered the backlog by that meaningless column.
**Fix:** the engine's own queue position is stored, and the engine's
`queued` event carries it.

### 60 — Unnecessarily exported `BootReceiver` *(Low)*
`BOOT_COMPLETED` is a system broadcast, so the receiver must be
exported to receive it — the finding's premise ("unnecessarily
exported") is only half right. What was missing is a **sender
restriction**: any app could spoof the broadcast and trigger the
database sweep.
**Fix:** `android:permission="android.permission.RECEIVE_BOOT_COMPLETED"`
on the receiver, so only the system (and apps holding the same
signature-level permission) may send it. The receiver's own action
check is kept as a second line of defence. See §4.

### 61 — Broad catch/except handling hides failures *(Low)*
The platform channel answered a generic `"Native call failed"`, so a
broken bridge, a missing plugin and a rejected argument were
indistinguishable in the UI and in the log.
**Fix:** the real reason travels with the failure; the engine's IPC
path already logged the method and the sanitized parameters.

---

## 3. Already fixed upstream (no change needed)

These 15 findings were closed by the 54 commits between the audited
commit and `HEAD`. Each was re-verified against the current source, not
taken on trust from the commit log.

| # | Evidence at `HEAD` |
|---|---|
| 1 | No `log.warning` / `logger.warning` call exists anywhere in `engine/`; the FFmpeg guard uses the module logger's real API. |
| 2 | `github_notifier.py` already redacts the title, the body and the context before posting. This branch made it share the engine's scrubber, so the public report cannot drift from the on-disk log. |
| 11 | The IPC executor is bounded: `_MAX_IPC_WORKERS` workers, a `_MAX_IPC_INFLIGHT` semaphore, and a load-shed envelope instead of an unbounded queue. |
| 13 | The retry sleep runs **after** the slot is released — `_pump_queue()` is called first, so a queued download can take the freed slot during the back-off. |
| 14 | The remaining `pop(0)` calls are on bounded, non-hot lists (the hook milestone list, the output-file list). The O(n) URL scans were replaced by an index. |
| 15 | The cancel watchdog uses a bounded pool with a matching FFmpeg timeout. |
| 16 | `verbose` is only set when the configuration asks for it. |
| 20 | `url_guard.py` fails **closed** on a DNS failure for profile fetches (`_dns_host_is_blocked`, `fail_closed_dns`), and the media path keeps the documented availability policy. |
| 27 | Playlist detection is host-based, not a substring test. |
| 28 | Output templates are validated for a per-item unique field, and a template without one is warned about (`docs/output_templates.md`). |
| 29 | Remote profiles are size-capped (`_MAX_PROFILE_BYTES = 256 KiB`), fetched through the pinned, proxy-free, DNS-validated opener, and revalidated on redirect. |
| 32 | FTS4 is the primary search path (`downloads_fts` with triggers); the `LIKE` query survives only as the fallback when FTS4 is unavailable. |
| 38 | The cleanup loop no longer uses `Queue.empty()` as a proxy for "done" — the code documents why and uses a different signal. |
| 42 | The wake-lock renewal runs on a dedicated executor (`powerLockExecutor`), not on the main thread. |
| 49 | Slot closing is generation-token based, so a watchdog that fires after a fast retry cannot close the new worker's slot. |
| 51 | The verify matrix has an API-35 Android IPC smoke job and a Flutter coverage floor enforced by `tool/check_flutter_coverage.py`. |
| 54 | The proxy is stripped from the config JSON on **write**, on **read** and by a migration pass over the existing rows. |

(16 rows: #2 is counted here as upstream-plus-hardening.)

---

## 4. Not applicable, or deliberately different from the audit's proposal

| # | The audit's proposal | What was done instead | Why |
|---|---|---|---|
| 6 | Add `androidx.security:security-crypto` for the cookie jar | An app-private `0600` file behind a `CookieSecretStore` interface | `security-crypto` 1.1.0 deprecated **every** API it exposes. The repository already treats a cookie jar as a *file* (the WebView flow writes `cookies.txt` the same way), and a jar can be hundreds of kilobytes — a poor fit for a preferences store. |
| 17 | Move `ensureInitialized()` into `runZonedGuarded` | The **entire** startup body moved inside the guarded zone | Moving only the call leaves `ensureInitialized()` in the root zone, which is the defect. |
| 35 | `INSERT … ON CONFLICT DO UPDATE` | Explicit UPDATE-then-INSERT | `ON CONFLICT DO UPDATE` needs SQLite 3.24 (API 30); `minSdk` is 24 and sqflite runs on the **platform** SQLite, so the statement fails outright on older devices. |
| 47 | Make `EngineEnvelope.decodeResponse` throw | The codec keeps its documented lenient contract; the **transports** detect the empty result and answer `ERROR_PROTOCOL` | The codec's `{}` fallback is a tested, documented contract (`engine_codec_test.dart`). Changing it would ripple through every consumer for no security gain. |
| 60 | Make `BootReceiver` unexported | Kept exported, but with `android:permission="android.permission.RECEIVE_BOOT_COMPLETED"` | A receiver for `BOOT_COMPLETED` **must** be exported to receive the system broadcast. The real gap was the missing sender restriction, which is now closed. |
| 37 | Move to a per-download provider (full state-management refactor) | One indexed lookup + one list copy per event | The session list holds the active downloads, not the whole history, so the measured cost was a pointer copy, not thousands of object allocations. A provider refactor touches every screen and cannot be validated without `flutter test` in this environment — the wrong risk for a "Medium" finding. |
| 56 | Remove the debug signing fallback | The fallback survives **only** for non-release tasks; a release task without a keystore fails loudly | Local `flutter build apk` (debug) must keep working on a machine without the release keystore. |

---

## 5. What was tested, and what could not be

**Executed here**

* `python -m pytest engine/tests -q` → **769 passed, 0 failed**
  (736 pre-existing + 33 new in `test_review_2026_10_19.py`).
* `ruff check --select F engine/` → *All checks passed* (F401 included).
* `dart format --output=none` on every changed Dart file → no syntax
  errors.
* **Full Kotlin type-check against the real Android and Flutter
  APIs** (the eight `com/theonly/grablytic/*.kt` files, compiled with
  **Kotlin 2.2.20** — the exact version pinned in
  `android/settings.gradle.kts` — against):
  * a genuine **API 35 `android.jar`**
    (`org.robolectric:android-all:15-robolectric-12650502`);
  * the genuine **Flutter embedding** for **Flutter 3.41.4**, the
    version this repository pins
    (`io.flutter:flutter_embedding_release:1.0.0-e4b8dca3…`);
  * `androidx.core` / `core-ktx` / `work-runtime` / `room-runtime` /
    `sqlite` / `lifecycle-common` / `activity` / `fragment` /
    `savedstate` / `annotation`, `kotlinx-coroutines-core-jvm:1.8.1`,
    `org.json:20231013` and `commons-compress:1.26.2`.

  Result: the unpatched base commit `c7a1a8a` and the patched tip
  produce the **identical error multiset** (40 errors each, all of
  them `com.chaquo.python` — Chaquopy is not published to a public
  Maven repository — plus one `iterator() is ambiguous` cascade from
  the same missing Chaquopy types). **No new error class, no
  regression, and no unresolved `android.*` or `io.flutter.*`
  symbol anywhere in the tree.** Every Android, Flutter and androidx
  reference in the changed code resolves.

  This is the evidence for finding **#4**: `javap` over the real
  API-35 `android.app.Service` shows both `public void onTimeout(int)`
  and `public void onTimeout(int, int)`, and the patched
  `DownloadService` overrides *both* overloads, so the API-35
  `onTimeout(startId, fgsType)` contract is genuinely implemented
  rather than merely assumed.

  The check caught two real defects during the work — a `replyError`
  signature that did not accept the `details` argument, and
  `Dispatchers.NonCancellable + Dispatchers.Main`, which resolves to
  `CoroutineScope.plus` and therefore does not type-check; the
  correct form is the top-level `NonCancellable + Dispatchers.Main`.
* The manifest and the workflow YAML were parsed after the edits.

**Not executed here — CI is authoritative**

* `flutter analyze` and `flutter test` (no Flutter SDK in the sandbox).
  The new Dart tests — `test/providers/download_terminal_events_test.dart`,
  `test/providers/cookie_secret_storage_test.dart`,
  `test/core/database/download_record_copywith_test.dart` — are written
  against the documented behaviour and have **not** been executed.
* The Gradle build and the Android lint job (no Android SDK). The
  Kotlin sources have nevertheless been type-checked against the real
  API-35 and Flutter 3.41.4 APIs as described above, which covers the
  compile-time half of that job. Enabling `abortOnError` may surface
  pre-existing lint findings on the first CI run; that is the intended
  visibility, and it is in a separate job from the release artifact.

---

## 6. Commits on this branch

| Commit | Scope |
|---|---|
| `6963b94` | `fix(engine)`: the engine-side findings (#3, #10, #12, #21, #30, #31, #39, #40, #43, #48, #58 and the `scrub_text` hardening) |
| `45df9a5` | `fix(app)`: the Flutter-side findings (#6, #7, #8, #9, #17, #18, #19, #33, #34, #36, #37, #46, #47, #50, #53, #59) |
| (this branch, final) | `fix(android)`: the Android-side findings (#4, #5, #22, #23, #24, #25, #26, #41, #44, #45, #57, #60) and the CI/build findings (#52, #56) |
