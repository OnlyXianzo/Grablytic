# Third-pass review: the files nothing had read yet

The first two passes walked the same surfaces — the download pipeline, the
Python engine's guards, the storage layer. The third pass went at the files
that had never been line-audited: `app_logger.dart`, `thumbnail_cache.dart`,
`history_guard.dart`, `batch_provider.dart`, `QueueReminderWorker.kt` and
`tool/check_flutter_coverage.py`. Twelve findings came back. This is what
happened to them.

Same method as before: read the claim, read the code, keep what the code
supports. Two of the twelve described a real defect with a mechanism that
turned out to be wrong, and one described a bug that the code had already
avoided by accident. Both are recorded as such rather than quietly "fixed".

## Outcome

| Surface | Defect | Severity | Outcome |
|---|---|---|---|
| `QueueReminderWorker.kt` | `ObjectInputStream.readObject()` on a prefs blob (CWE-502) | High | **Removed** — the branch is gone, the count is read structurally |
| `QueueReminderWorker.kt` | Unparseable queue state returned `0`, which cancels the periodic work | High | **Fixed** — `-1` means unknown, work stays scheduled |
| `app_logger.dart` | A failed flush dropped the whole batch | High | **Fixed** — re-queued unless the error is permanent |
| `app_logger.dart` | Tail reader decoded bytes with `String.fromCharCodes` | Medium | **Fixed** — UTF-8, one shared decoder |
| `app_logger.dart` | Console mirror printed before the enabled check | Medium | **Fixed** — gated, and debug-only |
| `thumbnail_cache.dart` | Partial downloads were cached and served for ever | Medium | **Fixed** — temp file, validate, then promote |
| `thumbnail_cache.dart` | Nothing ever deleted a thumbnail | Medium | **Fixed** — `prune()` with a live-id set and a byte budget |
| `history_guard.dart` | Look-alike hosts matched as YouTube | Medium | **Fixed** — exact host match |
| `history_guard.dart` | Normalisation ignored fragment, `www.`, port and case | Low | **Fixed** |
| `batch_provider.dart` | Off-window batch left one item spinning `downloading` | Medium | **Fixed** — the gate runs before the status change |
| `batch_provider.dart` | A cancelled item could be flipped back to completed | Medium | **Fixed** — terminal statuses are not overwritten |
| `check_flutter_coverage.py` | A file with no executable lines was a hard error | Low | **Fixed** — empty records are valid |

## The ones where the report was wrong

**The queue count did not die the way the report said.** The claim was that
the fast path used `Base64.decode` + `ObjectInputStream`, and that a bad blob
threw and reset the count. Half of that was right: the deserialisation was
there, and it is gone — reading attacker-influenced `ObjectInputStream` is
never worth it, and current `shared_preferences_android` does not produce that
encoding anyway.

But the *reason* the fast path failed is duller. Dart writes `setInt`, which
lands in SharedPreferences as a `Long`; the Kotlin side called `getInt`, which
throws `ClassCastException`. In production the writer is `setStringList`, so
`getStringSet` already answered on the real path and the broken branch was
mostly decorative. What was genuinely broken is adjacent: anything the reader
could not parse returned `0`, and `doWork()` treats "zero pending items" as
"nothing to do, cancel the periodic work". One unreadable pref silently killed
the reminder schedule until the next launch. `readQueueCount` now returns
`-1` for unknown and `doWork()` keeps the work scheduled.

**The thumbnail cache was not corrupting images — it was refusing to replace
them.** Writing straight to `<id>.jpg` meant a stream error left a truncated
file at the final path, and the next call's `exists()` check returned that
fragment as a hit. The `contentLength > maxBytes` guard only catches servers
that declare an honest length; chunked responses sail past it. The fix is the
ordinary one: write to `.part`, check the JPEG magic bytes, then rename.
Renaming is atomic on the same filesystem, so a reader sees either nothing or
a whole file.

## The one that was already fine

`markAlreadyHaveItems` was reported as double-suffixing on a second run. It
checks `title.endsWith(alreadyHaveSuffix)` and returns the item untouched, so
it is idempotent. No change.

## Judgement calls worth defending

**`kDebugMode` around the console mirror.** Turning off logging now silences
stdout as well as the file — before, `setEnabled(false)` only quietened the
file and every line still went to the console. In release builds the mirror is
off entirely: a logcat buffer is shared with every other app on the device and
rotates fast, and a downloader's lines carry titles, URLs and file paths. The
in-memory `LogBuffer` is still fed before that gate, so the in-app log viewer
is unaffected.

**Re-queueing a failed flush.** The batch is detached from `_pending` before
the write, so a failure used to drop up to 10,000 lines — including the
`ERROR`/`FATAL` that triggered the flush, which is exactly the line a crash
report needs. It goes back at the head of the queue unless the error is one of
`ENOSPC`, `EACCES` or `EIO`, where retrying is a battery drain rather than a
retry. The 10,000-line cap still applies, so a permanently broken disk cannot
loop.

**Eviction rides on the prefetch, not a timer.** `_prefetchThumbnail` in
`download_provider.dart` calls `prune()` with the ids it still holds, right
after the fetch and regardless of whether the fetch worked. One directory
listing per new download is cheaper than a periodic worker that wakes up to
find nothing to do, and it lands exactly when the cache is about to grow. The
byte budget is the backstop: 64 MB, oldest first, so a user who never deletes
anything still cannot grow the cache without bound. The files are in
app-private storage — the user cannot see them and cannot clear them from
Settings — which is what made the leak worth a fix at all.

**`_normalizeUrl` now rebuilds the URI.** Two links that differ only by
`#t=30` compared unequal, so the "already have" guard missed every second URL
for non-YouTube hosts (YouTube fell through to the video-id check, which is
why nobody noticed). Case, `www.`, a default port and the fragment are all
dropped before comparison. Query strings are kept and compared verbatim:
`?list=` changes what a URL means.

## Verification

* `pytest engine/tests tool/tests -q` → **788 passed** (5 new: two for empty
  LCOV records, and the existing three still pass).
* `ruff check --select F engine tool` → clean (one pre-existing unused import
  removed from `tool/generate_release_changelog.py`).
* `python3 tool/check_broad_catches.py` → holds at 168 Dart / 237 Python. The
  new `thumbnail_cache.dart` error handling is written as `on
  FileSystemException` where the type is known and `on Object catch (error)`
  with a reason where it is not, so the Dart count did not move.
* `python3 tool/check_doc_links.py` → 22 files clean.
* **Dart is not compiled here** — no Flutter SDK in this sandbox. Five files
  changed plus three test files; `flutter analyze` and `flutter test` are the
  gate. The new tests cover the schedule gate, the cancel race, the UTF-8
  tail, `prune()` against a real temp directory, and the look-alike hosts.
* **Kotlin is not compiled here** — no Android SDK. `QueueReminderWorker.kt`
  is the only Kotlin file touched, and it is a net deletion.

## Residual risk, accepted

| Item | Why it stays |
|---|---|
| Thumbnail `prune()` still needs a caller on the delete path | The provider passes live ids at prefetch time; a delete that races a prefetch leaves one orphan until the next prefetch run. The byte budget bounds it. |
| Only JPEG is accepted as a thumbnail | A PNG/WebP cover is dropped and the UI shows the placeholder it already shows for a missing file. Sniffing three formats would add a decoder dependency for a cosmetic gain. |
| `_pending` is still an unbounded-ish in-memory list | Capped at 10,000 lines, but 10,000 long lines is real memory. The flush worker runs every 30 s; a producer that outruns it that badly has a different problem. |
