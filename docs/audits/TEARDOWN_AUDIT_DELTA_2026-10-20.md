# Second-pass review: what happened to findings #62–#71

The second-pass audit (Arena.ai Agent Mode, 2026-10-20) re-ran the teardown
against `78c43e2` and confirmed the first pass: 57 of the 61 original findings
fixed outright, 3 partial, 1 fixed with an accepted residual, none open in its
original form. It also raised **10 new findings in the new code** and one
methodology finding (#61) about counts moving the wrong way.

This document records what was done with each of them. The pattern from the
first pass holds: the finding's suggested patch was read, then checked against
the actual code, and applied only where it was right.

## Outcome

| # | Finding | Severity | Outcome |
|---|---|---|---|
| 61 | Broad-catch counts rose (158→168, 181→233) | Medium | **Ratcheted** — CI gate holds both counts |
| 62 | Every launch re-hashes every native package | Medium | **Fixed** — stat fast path + weekly deep verify |
| 63 | stderr mirror printed before the level gate | Medium | **Fixed** — gated, one serialization |
| 64 | Retry can be starved by the queue pump | Medium | **Fixed** — the slot is reserved |
| 65 | FTS failure downgrades search for the session; LIKE unescaped | Medium | **Fixed** — re-probe + escape |
| 66 | No index on `downloads.timestamp` | Low | **Fixed** — schema v8 |
| 67 | Cookie jar written non-atomically; 0600 claim false | Low | **Fixed** — temp+rename, honest perms |
| 68 | `EngineLogger` has no `warning()` | Low | **Fixed** — alias + test |
| 69 | Notification ids are a 24-bit hash fold | Low | **Fixed** — allocated counter |
| 70 | `activeCallbacks` uncapped | Low | **Fixed** — bounded, oldest evicted |
| 71 | "Fast lane" runs mutating work inline | Low | **Partly fixed** — measured, not moved (see below) |

## The judgement calls

### #64 — reserve the slot instead of releasing it

The finding is a fairness bug hiding behind a correct lock. `_running_count()`
excludes a download that is sleeping through a retry backoff, which is what
makes the engine usable during the sleep; but the freed slot was then handed to
the next queued entry, and in a deep queue every completion can refill it before
the retry wakes. `_begin_backoff` promised it would "re-acquire a slot"; nothing
guaranteed it ever would.

The fix keeps the entry out of `_running_count()` — it is not working — and adds
`_backoff_reservations()`, which counts it against the budget in **both**
admission paths (`_pump_queue` and `start_download`). The slot is a reservation,
not a donation. The cost is asymmetric in the right direction: with the default
limit of two, one backing-off download still leaves a slot for the queue, and the
worst case becomes "the queue waits a few seconds" instead of "the retry waits
for the queue to drain".

`_begin_backoff` also has a deadline now (`_MAX_BACKOFF_SLOT_WAIT_S`, 300 s). It
can only expire if the limit was lowered while the download slept, and when it
does, the retry proceeds and logs `backoff_slot_wait_expired` — a download that
never retries and never fails is worse than a temporary over-admission of one.

`engine/tests/test_backoff_slot_release.py` was rewritten around the new
contract. Its old `test_backoff_promotes_a_queued_download` asserted exactly the
behaviour that caused the starvation, so it became
`test_backoff_reserves_the_slot_against_the_queue`.

### #71 — measure the inline lane instead of moving it

The audit proposed a separate maintenance pool for `paths/set`,
`download/set_concurrency` and `download/clear_archive`. That would trade a
bounded delay for an **ordering** bug: `paths/set` is a barrier. The host sends
it before the first download, and if it runs on a worker while `download/start`
goes to the extraction pool, a download can be admitted against unmapped paths.
The same applies to a concurrency change or an archive clear that the client
follows immediately with a start.

So the methods stay inline and the *claim* was corrected to what the code
actually guarantees: bounded local work, no network, ordering preserved. What
can still go wrong is a pathological filesystem, so the dispatcher now times
each inline call and logs a warning past 250 ms. A device whose `paths/set`
takes two seconds leaves a diagnosable line instead of a vague "cancels are
slow".

### #62 — trust-on-first-use, with the boundary stated

`isCurrentExtraction()` hashed the archive and the tree *before* looking at the
recorded length/mtime, so its "quick reject hint" comment described a branch
that did not exist. On a warm launch that is hundreds of megabytes of reads for
files the app installed itself.

The stamp schema went to v6 with a `verified_at_ms` field:

* same size and mtime, verified within 7 days → trust, return;
* same size and mtime, older → re-hash the tree only;
* size or mtime changed → re-hash the archive, then the tree;
* v5 stamps (no timestamp) are treated as stale, so the first launch after the
  upgrade re-verifies once and writes a v6 stamp.

`init(context, forceVerify = true)` is the escape hatch for a future "Verify
installation" action. This is deliberately trust-on-first-use, and the docstring
says so: the stamp is excluded from the tree hash (it is the root marker), so it
is not a defence against something that can already write to app-private
storage — the sandbox is. It is a defence against "we pay the full cost on every
launch for a package we wrote ourselves".

### #61 — a number that only goes down

`catch (_)` in `lib/` and `except Exception` in the engine are mostly
load-bearing (a logging sink must not take a download down; a storage primitive
must not crash the settings screen). Deleting them to satisfy a review would be
the wrong change. What is measurable is direction:
`tool/check_broad_catches.py` holds both counts in
`tool/broad_catch_budget.json` and fails CI when either grows. Reducing them is
`--update`, which is a reviewable diff. Wired into `verify.yml` as
"Broad-catch ratchet".

## Verification

What was actually run, and what could not be:

* `pytest engine/tests -q` → **783 passed** (770 at the audited commit; 13 new
  tests: 12 in `test_review_2026_10_20.py`, and the rewritten backoff file).
* `ruff check --select F engine/` → clean.
* `python3 tool/check_broad_catches.py` → holds at 168 Dart / 237 Python.
* `python3 tool/check_doc_links.py` → 20 files clean.
* **Dart changes are not compiled here** — no Flutter SDK in this sandbox. Three
  files changed (`download_history_db.dart`, `cookie_secret_store.dart`) plus a
  new test file; CI's `flutter analyze` and `flutter test` are the gate.
* **Kotlin changes are not compiled here** — no Android SDK. Three files
  changed (`BinaryPackageManager.kt`, `DownloadService.kt`, `MainActivity.kt`);
  CI's `android_ipc_smoke` job is the gate. All three changes are logic-level
  (a stamp field, an allocator, a bounded map), not type-level.

## Residual risk, accepted

| Item | Why it stays |
|---|---|
| `yt-dlp` pinned by version, not by wheel hash | From the previous register. A PyPI compromise is still possible; vendoring the wheel closes it. |
| Proxied traffic bypasses socket pinning | Documented at `url_guard.py`; a SOCKS proxy resolves the origin itself. |
| Inline lane can still be slow on a pathological filesystem | Measured and logged (#71). Moving it breaks ordering. |
| Cookie contents are plaintext inside the app sandbox | Android has no `chmod` from Dart and no keystore-free alternative that survives deprecation (`androidx.security` 1.1.0 beta deprecated every API). Verbatim contents are the trade for a jar that can be megabytes. |
