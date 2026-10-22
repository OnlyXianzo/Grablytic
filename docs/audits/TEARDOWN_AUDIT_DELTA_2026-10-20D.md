# Third pass: the four residuals, and the seven new findings

`e0a212f` was the baseline. The third-pass audit called 79 of 83 findings
closed, kept four open on principle, and raised seven new ones — five about
memory and startup, two about correctness. This round closes all eleven, and
every performance claim below is measured in this repository rather than
estimated.

## The four that were "correct but not ideal"

**#18 — the version was pinned, the bytes were not.** `yt-dlp==2026.08.19`
said which release we tested. It did not say the wheel *is* that release: a
compromised PyPI account, a mirror, or a TLS-terminating proxy can serve
different bytes under the same version number, and `uv pip install -r` would
install them inside the process that holds the user's cookies and proxy
credentials. The engine now fetches the wheel itself, hashes it against
`wheel_pin.PINNED_SHA256`, and hands only the verified file to `uv`. A
mismatch deletes the download and fails the attempt — there is no fallback to
an unverified install. The desktop transport does the same through
`uv pip install --require-hashes --no-deps -r <temp file>`, with the digest in
`EngineContract.ytDlpWheelSha256`. `test_wheel_pin.py` fails if the constant,
`requirements.txt`, the Chaquopy pin and the Dart mirror drift apart.

**#37 — `_replaceItem` still copies the list, and that is the accepted
answer.** `StateNotifier` only notifies when the state object changes, so a
new `List` per coalesced tick is the mechanism, not an accident. What the copy
costs is a pointer array: 200 items is ~1.6 KB of pointer writes per tick, and
the notifier already coalesces progress to ~10 Hz. The alternative the audit
floats — a family provider per download — moves the same allocation into a
different place and adds a rebuild-ordering risk to the hot path. Recorded as
a residual with the numbers rather than silently "fixed".

**#61 — the ratchet had never gone down.** It has now: 168 → 165 Dart and
237 → 234 Python, with `tool/broad_catch_budget.json` updated to the new
numbers. The six Python removals are handlers that could not fire
(`threading.Event.set`, a lock-protected dict read, `Queue.put`) or could only
fire with `queue.Full` / `queue.Empty`; the three Dart ones were
`await db.close()` and two FTS probes, which only ever throw
`DatabaseException`. The rest of this round's new handlers were written narrow
from the start (`RuntimeError` for a shut-down executor, `ValueError` for a
semaphore over-release) so the budget did not have to absorb them.

**#71 — `paths/set` no longer runs on the stdin reader.** It resolves
binaries and opens log files; `download/clear_archive` unlinks a file. Both
can stall for as long as the filesystem wants (FUSE, adopted storage, a
sleeping SD card), and while they did, the reader could not read the next
line — including a cancel. They now run on a single-threaded **maintenance
lane**, and the ordering invariant they were inline for is kept differently:
every slow-lane request captures the lane's tail at submission and waits for
it on a pool worker before running. `download/start` still cannot be admitted
against unmapped paths; the cancel path no longer waits behind it. The wait is
bounded at 10 s, and past that the request runs and the engine log says the
ordering was lost — a wedged filesystem must not become a wedged engine.

## The seven new findings

**#84 — 40 MiB and a yt-dlp import before the first frame.** Three changes,
because there were three ways in:

* `logIngesterProvider` no longer watches `engineProvider`. It opens the
  `com.theonly.grablytic/progress` EventChannel directly and filters for
  `type: log`. Kotlin keeps a *list* of sinks, so this second listener does
  not displace the engine's; both receive every event. Desktop still uses the
  engine's stream — there is no interpreter to pay for there.
* `PlatformChannelEngineService.setPaths` now **holds** the paths. Nothing
  crosses the bridge until the first call that actually needs Python, which
  applies the held paths first and then the call. Calls that are pure Kotlin
  (notifications, intents, WorkManager schedule, battery/metered probes, icon
  switching) never trigger a start at all — otherwise a queue reminder
  toggled in Settings would have started a 40 MiB interpreter.
* `MainActivity.configureFlutterEngine` no longer calls `Python.start` on the
  platform thread. A `@Synchronized ensurePython()` starts the VM inside the
  `Dispatchers.IO` handler that first needs it, and the failure is latched:
  Chaquopy forbids retrying a failed start, so every later call answers
  `ERR_ENGINE_UNAVAILABLE` instead of re-attempting.

The concurrency setting was the trap here: it arrives from a settings
listener that may fire before any download, and native used to answer
`ERR_ENGINE_UNAVAILABLE` so the value was lost for the session. It is now
parked and replayed (newest value only) once the paths are in.

**#85 — five thumbnails decoded at source resolution.** `lib/core/widgets/thumb.dart`
adds `thumbCacheWidth`, `thumbCacheWidthFor` (for build helpers that have no
`BuildContext`), `fullWidthCacheWidth` and a `CachedThumb` widget (not `Thumb`
— Material exports a slider `Thumb` of its own, and both at once makes every
call site an ambiguous import), and all five bare call sites now go through
it. A 1280×720 cover at `cacheWidth: 112` is
27.6 KiB instead of 3.52 MiB. The device pixel ratio is applied but clamped
to `[1, 2]`: a 3× screen gains nothing visible from a 3× bitmap and pays 9×
in pixels. `imageCache.maximumSizeBytes` is also capped at 40 MiB (from
Flutter's 100 MiB default) with 250 entries, so the cache evicts rather than
growing into a fifth of a small phone's heap.

**#86 — every log record was filtered after it was retained.** `LogBuffer.add`
now gates on level *before* it builds the per-download entry, so a DEBUG
record that no sink will show costs a comparison instead of an allocation. The
buffer also exposes `view` (an unmodifiable view for export) and
`snapshot(limit:)` (a bounded copy for rendering), and
`LogBuffer.forThisPlatform()` sizes the ring at 2,000 entries / 200 per
download / 10 downloads on mobile against 5,000 / 500 / 50 on desktop.

**#87 — the logger paid for I/O it would never do.** `_log()` calls a
`_wants(level)` gate first, so a dropped record is ~11.4 µs of nothing instead
of ~33.3 µs that also ran `makedirs` + `realpath` + `strftime`. The daily sink
path is memoised per day (`_daily_sink_path`, `_day_stamp`), and the
persistent bridge registers its level with `set_persistent_bridge_level` so
the gate knows a rotating handler exists and cannot drop records only it
would have written.

**#88 — the poll loop woke 864,000 times a day to find nothing.** `poll_queues`
is event-driven: `threading.Event` is set by `notify_poll()` from every
producer (`_put_bounded` on both paths, the new `_put_result`, the queue
pump), and the drain waits on it with a 1 s safety timeout instead of sleeping
0.1 s. The flag is cleared *before* draining, so a write that lands during the
drain re-arms it and the next iteration sees it — no lost wakeups.

That change made a latent bug deterministic: the terminal `filesize_bytes` was
derived by draining the progress queue, so any second consumer emptied it
first and the field came back as 0 (the existing bridge test caught it). The
hook is the only place that sees every sample, so `hooks` now records the last
`(size, filename)` per download (bounded to 256 ids, cleared when a download is
reaped) and the terminal path falls back to it. The queue is still
authoritative when it has an answer.

**#89 — the live log view re-filtered 5,000 entries per keystroke.** Each
`LogEntry` now carries `searchBlob` (computed once, lowercased) with a
`matches(needle)` helper; the view lowercases the needle once, snapshots at
most 2,000 newest rows, and filters in a single pass. Export still walks the
whole ring through `buffer.view`, which does not copy.

**#90 — six sequential platform round trips before `runApp`.** The documents
and temporary directories are now awaited together (`.wait`), so the first
frame waits for the slower of the two instead of their sum. The default
download path stays before `runApp` on purpose: `settingsProvider` reads the
whole preference set once, so writing it behind the first frame would leave
the session on the legacy placeholder until the next launch — and it only ever
runs on a fresh install.

## Verification

* `pytest engine/tests tool/tests -q` → **815 passed** (up from 785; 10 perf,
  5 IPC-lane, 8 wheel-pin).
* `ruff check --select F engine tool` → clean.
* `tool/check_broad_catches.py` → holds at **165 Dart / 234 Python** (was
  168 / 237).
* `flutter analyze` → no issues; `flutter test` → **688 passed** (687 + the
  new lazy-start file). Both were run in CI, not here: this workspace has no
  Flutter SDK, and the first CI runs are what caught the three analyze errors
  and the two test expectations this round fixed (the redundant `painting`
  import, the `late final` field on a `const` constructor, the `Thumb` name
  clash, parking a concurrency change when no paths exist to start the engine
  with, and `entries` no longer being read-only).
* Dart and Kotlin are otherwise source-verified only — no Flutter or Android SDK in
  this workspace, so CI is the gate. `lazy_engine_start_test.dart` pins the
  ordering contract: `setPaths` alone sends nothing, the first Python-bound
  call sends `paths/set` first, a parked concurrency change is replayed once,
  pure-Kotlin calls never start the engine, and a failed start is retried by
  the next call.

## Residual risk, accepted

| Item | Why it stays |
|---|---|
| `_replaceItem` allocates a list per tick (#37) | `StateNotifier` needs a new state object to notify; the copy is ~1.6 KB of pointers per coalesced tick. The per-item provider refactor is a larger change with its own ordering risk. |
| `Python.start` now runs on an IO thread | Chaquopy's own guidance is "call it after checking `isStarted()`" with no thread restriction; `start` is `synchronized` and the failure is latched. Every other entry point (poll worker, DownloadService) still guards with `isStarted()`. |
| The maintenance-lane wait is 10 s | Past it the request runs and the log records the ordering violation. The alternative is an engine that never answers because a filesystem never answered. |

---

# Fourth pass: eight findings, and the one that undid pass 3

The third pass moved the engine start behind a "first Python call" rule and
then left two callers on the home screen holding the trigger. This round
addresses #91–#98. #37 stays where it was: a pointer copy per coalesced tick
is not worth a commit of its own.

## The finding that mattered: #91, the engine started itself anyway

`engineStatusProvider` awaits `engineSetPathsFuture` and then calls
`bootstrap()`, and `_EngineStatusBanner` watched it — so the default tab
started Chaquopy and imported yt-dlp on every returning launch. Measured cost
of that import, from pass 3: **40.5 MiB RSS, ~480 modules**. Pass 3 added a
test that `setPaths` alone sends nothing; nothing tested what the first frame
does.

The status provider is now split in two:

* `engineStatusProvider` — the live read. It awaits `bootstrap()` and
  publishes the result into…
* `cachedEngineStatusProvider` — a `StateProvider<EngineStatus?>`. The banner
  watches this, so it renders the last known status and starts nothing.

The banner refreshes the live provider once, after the engine has actually
started, so a stale status from an earlier session is corrected as soon as
something needs the engine. The start is reported by the transports through
`engine_start_signal.dart` — `markEngineStarted()` in `_applyPaths` (Android,
where `paths/set` is what starts the interpreter) and in `_doEnsureRunning`
(desktop) — and the UI listens.

`ResumeNotifier`'s constructor used to call `scan()`, which made *creating*
the notifier a Python call. `downloadProvider` reads that notifier, so the
engine started on first frame whether or not the interrupted-downloads card
was rendered. The constructor no longer scans; `scanIfNeeded()` is called by
the card.

That leaves the card itself, which is how a user resumes a download that was
interrupted by a dead battery. Waiting for them to start a *second* download
before the resume card appears would have quietly deleted the feature, so the
card checks for evidence first: a non-recursive listing of the download folder
for `*.part`. Evidence → scan (engine starts). No evidence → nothing (and
nothing was going to be shown anyway).

## #92 — redaction ran on one sink out of three

`sanitize()` was applied by the rotating `server_logs.log` handler only. The
same record also went to the daily `engine_*.txt` file and out over the UI
bridge verbatim, so `sig=…` was masked in one file and readable in the other —
including the copy the Diagnostics screen hands the user for an issue report.

Redaction now happens once, on the event dict, before `json.dumps`. It is
targeted rather than a deep copy of the whole record: `message` and
`exception` go through `scrub_text`, and `context`/`extra` get the key-aware
pass only when they are non-empty. A deep copy of the record measured
**14.8 µs**, of which ~90% was walking `type`/`level`/`ts`/nulls.

| Path | Before | After |
|---|---|---|
| INFO, no secret shapes | 27.92 µs | 16.05 µs |
| INFO, signed URL present | — | 31.42 µs |
| DEBUG, written | 44.66 µs | 33.09 µs |
| DEBUG, gated out | 0.16 µs | 0.16 µs |

## #93 — every record written twice

The bridge to the rotating file forwarded INFO and DEBUG too, so each line
that already existed in `engine_*.txt` was sanitized again (29.3 µs for a
129-byte line) and written a second time. The bridge floor is now WARNING:
`server_logs.log` keeps the records worth attaching to a crash report, the
daily file keeps the narrative.

`persistent._scrub_string` also short-circuits on a "does this look like it
could hold a secret" regex (2.64 µs, returns the same object when nothing
matches) so the sanitize pass on a clean line is a scan, not a rebuild.

## #94 — the gate nobody called

`_wants()` was correct and unreachable: `set_min_level` had zero call sites, so
with a daily file configured the gate always answered "yes" and saved 11.4 µs
instead of 33.3. It is now a setting. `paths/set` carries the host's
`log_level`, `_log_level_value` accepts a name or an int, and
`set_global_min_level` pushes it onto every logger present and future. The
default is INFO; Diagnostics → "Detailed engine logging" raises it to DEBUG
for the session.

This is the one place where the fix costs something a user can notice: a
release build no longer writes yt-dlp's DEBUG flood to the daily file unless
asked. The trade is deliberate — the file that a user attaches to an issue is
the one that a support engineer can read, and "Detailed engine logging" is one
toggle away, labeled in the app. The gate is worth having precisely because
those lines are now optional.

## #95 — filtering after truncation

`LiveLogView` took `snapshot(limit: kLiveLogRowBudget)` and filtered the
result, so on desktop — where the ring holds more than the budget — a search
for something older than the budget returned nothing. `LogBuffer.filter`
walks the ring once and keeps the newest *matching* entries: O(n) time,
O(limit) memory.

## #96 — 4 MiB decoded to fill 28 logical pixels

The brand PNGs are 1024×1024. `AdaptiveLogo` renders them at 28 px in the hero
and 96 px elsewhere, and re-decodes on every theme flip. `cacheWidth` sizes
the decode to the render box: ~14 KiB instead of 4.00 MiB. The alternative —
bundling the pre-sized `variants/*_96.png` set — was rejected because it
needs one asset per (variant × size × device pixel ratio) and still leaves the
large masters in the bundle for the launcher icons.

## #97 — the first `paths/set` ate the second

`setPaths` parked the map and cleared it when the first apply finished. A
settings change that landed while `paths/set` was still in flight — that
handler runs `BinaryPackageManager.init()` and the engine import, so seconds —
was cleared by the older call's "we're done" step. The apply now counts
generations and re-sends while the box moved underneath it, bounded at four
attempts; then `_pathsApplied` is true and further changes go straight
through.

## #98 — two readers of one native stream

`PlatformChannelEngineService` and `logChannelProvider` each called
`receiveBroadcastStream()`, which registers a second Kotlin sink: every
progress event crossed the bridge twice, and was `jsonDecode`d twice, once only
to be discarded by a `type == 'log'` filter. `ProgressChannel` is now the one
reader — a single native subscription feeding a broadcast controller — and the
log provider derives its filtered view from it.

## Verification

* `pytest engine/tests -q` → **821 passed** (up from 808; 13 new in
  `test_pass4_logging.py`).
* `pytest tool/tests -q` → 7 passed.
* `ruff check --select F engine tool` → clean; `ruff format --check` on the
  touched files → clean.
* `tool/check_broad_catches.py` → holds at **165 Dart / 234 Python**.
* New Dart tests: `engine_start_signal_test.dart` (7), `progress_channel_test.dart`
  (6), four `LogBuffer.filter` cases, two lazy-start cases (#97 re-send, #91
  start signal).
* `flutter analyze` / `flutter test` are CI-only, as before — this workspace
  has no Flutter SDK. The two Dart changes that are easiest to get subtly
  wrong, the stateful banner and the `.part` probe, are also the two with no
  local compile check; that is the residual risk of this round.
