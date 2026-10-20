# Post-merge round: CodeRabbit's two majors, plus what the addendum left

PR #18 merged the third-pass work. This round covers what came *after* it:
the two Major findings CodeRabbit raised on that PR, and the four addendum
items that were still open when it merged. Everything here is on surfaces
that already had tests, so each fix came with one.

## The two CodeRabbit majors

**A cancelled batch item kept downloading.** `cancelItem` flipped the queue
row to `failed` and stopped there. The engine had its own `downloadId` and
never heard about the cancel: the user saw "cancelled", the transfer kept
running, and the file landed anyway. The item now carries the engine id
(reserved *before* the status change, so a cancel that lands between the
state update and the dispatch still has something to send), and
`cancelItem` / `cancelAll` forward it to
`DownloadNotifier.cancelDownload`, which owns both the engine call and the
`ERROR_DOWNLOAD_NOT_FOUND` reconciliation. `retryFailed` clears the id, so a
retry never re-uses a dead one.

**An expired backoff slot resumed anyway.** The reservation is what stops a
deep queue starving a retry, and it has a 300 s deadline so a lowered limit
cannot hang it. What happened after the deadline was the bug: the retry
resumed *without* a slot. Lower the limit from five to one during a backoff
and all five sleepers wake up and run. `_begin_backoff` now reports whether
it got capacity, and `_maybe_retry_transient` ends the attempt when it did
not — a terminal, retryable error beats an engine running five downloads
against a limit of one.

## Four the addendum left open

**The schema version said 7 while the migrations went to 8.** `openDatabase`
was given `version: 7` and `onUpgrade` had an `oldVersion < 8` block, so the
block could never run on an existing install: the listing indexes were
created for fresh installs only, and every existing user kept doing a full
scan plus a temporary sort per page. The new tests passed because they build
a database from scratch, which is exactly the blind spot. The version is now
a named constant with a note that it moves in the same commit as any new
migration block.

**No WAL, no busy timeout.** `onConfigure` now sets `journal_mode = WAL`,
`busy_timeout = 5000` and `synchronous = NORMAL`. With the rollback journal,
a writer (progress updates, the history prune) blocks readers for the length
of the transaction, and two connections colliding get `SQLITE_BUSY` with no
retry window. Each pragma is individually forgiven: a build whose SQLite
refuses one still opens the database, slower rather than broken.

**The coverage gate could not see the files it was not measuring.**
`flutter test --coverage` only reports files that were instrumented, and the
percentage is computed over those — so deleting a weakly-tested module
*raised* coverage, and a broken import silently removed a file from the
denominator. The tool now lists every `lib/` file with no record at all,
prints them, and fails above a `--max-unloaded` budget. `--allow-unloaded`
exists for the files that genuinely have no executable lines.

**The pre-filter was O(items × history).** `markAlreadyHaveItems` called
`findDuplicate` per item, so a 500-entry playlist against a 5,000-row
history was 2.5M URL comparisons before the first download started. A
`CompletedVideoIndex` builds the normalized-URL and video-id sets once, and
the pre-filter is now two hash lookups per item. Same matching rule,
including the "audio already downloaded as video" case.

**A schedule start time with no end is not a window.** `22:00` was open
until midnight and then closed, so "run overnight" blocked at 00:30.
`AppSettings.scheduleWindowMinutes` (default 240) gives the window a length,
a window that crosses midnight belongs to the *previous* day's schedule
entry, and the early hours of the next day are covered by it. Existing
behaviour for same-day windows is unchanged.

## Verification

* `pytest engine/tests tool/tests -q` → **792 passed** (4 new: two for the
  expired-slot path, two for the coverage-completeness rules).
* `ruff check --select F engine tool` → clean.
* `tool/check_broad_catches.py` → holds at 168 Dart / 237 Python.
* Dart is source-verified here (no Flutter SDK); the two new batch tests
  need a hanging engine so the item is still `downloading` when it is
  cancelled, and the three schedule tests pin the midnight spill.
* Kotlin untouched this round.

## Residual risk, accepted

| Item | Why it stays |
|---|---|
| `--max-unloaded` needs a seeded number | The budget is set from one real report; until it is, the flag reports without failing. |
| `scheduleWindowMinutes` has no Settings control | It is read from preferences and defaults to four hours. A UI knob is a separate change with its own tests. |
| WAL adds `-wal`/`-shm` files next to the database | They are in the same app-private directory and SQLite reclaims them on close. |
