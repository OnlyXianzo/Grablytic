---
title: Open Questions
date: 2026-10-20
tags: [grablytic, inbox, questions]
status: complete
---

# Open Questions (Inbox)

Anything unclear from code goes here. Resolve it by reading code and tests, then move the answer into the covering note and delete the row. Highest-impact first.

> Updated 2026-10-20. Most notes were first written 2026-10-08 against `redesign/ui` @ `bad0851`; that branch is merged into `main` and shipped in v0.0.5. Line numbers from that snapshot may have moved.

## Open

1. **Bulk archival field-practice source.** The [[bulk-archival-workflow|bulk-archival-workflow]] note is assembled from repo capabilities and the 2026-09-30 portrait-reel session quoted in commit `6cea501` (54 reels, 551×871 → 996×1772). The repo has no separate field log, device list, or network-condition record. *Needed:* a field log if one exists.

2. **Portrait-ladder width semantics for non-YouTube or muxed listings.** The `bestvideo*[width<=H][aspect_ratio<1]` rung assumes `width` and `aspect_ratio` are populated for every extractor. Audiobook, podcast, or muxed-only listings may omit them, in which case the rung silently skips. *Needed:* a yt-dlp field-population check or a muxed-portrait test pin.

3. **`aspect_ratio` availability by yt-dlp version.** The ladder relies on yt-dlp computing `aspect_ratio`. The floor is `yt-dlp>=2025.11.12`; it is unclear when that computation landed and whether stale desktop venvs degrade gracefully. *Needed:* a version-vs-field check. The engine suite was last run with yt-dlp 2026.08.19.

4. **BootReceiver SQLite access path.** `BootReceiver` sweeps SQLite `downloads` (Kotlin, serialized with busy-timeout and retry) while Dart owns `DownloadHistoryDb` through sqflite. It is unclear whether both open the same `grablytic.db` file (WAL and locking interplay) or separate stores. *Needed:* read `BootReceiver.kt` and confirm the DB file path.

5. **Cache-dir vs output-dir for `.part` resume.** `scan_resume_candidates(cache_dir)` documents the cache dir, but the v0.0.4 notes say partials stream straight to the output dir. It is unclear which directory the scan covers for fresh downloads. *Needed:* read `resume.py` and the `downloader.py` outtmpl/paths wiring.

6. **Triage/export workflow beyond log export.** No formal triage SOP or export-format spec exists beyond the Diagnostics screen, `exportLogToDownloads`, and the GitHub dedup reporter. The [[triage-export-workflow|triage-export-workflow]] note is a synthesis, not a quote of an existing process. *Needed:* confirm no hidden SOP exists.

7. **Exact `set_paths` arity on each transport.** The desktop call passes 8 arguments plus `ffmpeg_ld_path` and `nodejs_path`; Android differs. *Needed:* document the per-platform matrix from `MainActivity.kt:500` and `__main__.py:241`.

8. **`seen_source_videos` retention and GDPR story.** No expiry or prune path was found; `clearSeenSourceVideos` is manual. *Needed:* decide whether retention needs a timer or a documented manual-only policy.

9. **`download_archive` file location and naming.** The setting is referenced in settings and features docs, but no path convention was found in the scanned files. Compounding this: `url_guard.safe_archive_path` is exported and unit-tested but has **zero production callers**, and `clear_download_archive` re-implements containment with a different primitive (`startswith(dir + sep)` at `downloader.py:1668` vs `commonpath` at `url_guard.py:280`).

10. **`scheduler_check.py` vs `ObservedSourcesPollWorker` Atom parsing parity.** Two RSS parsers exist (Python helper and Kotlin worker). It is unclear which is authoritative and whether entity-expansion guards match. *Needed:* compare both parsers on the same feed.

11. **`AccountsSettingsScreen` is referenced but does not exist.** A leftover comment at `settings_screen.dart:202` names it, but there are 9 Settings sub-screens and none is called Accounts. *Needed:* confirm whether the comment is stale or a screen was dropped.

12. **`open_offline_queue` deep link is dead.** `QueueReminderWorker.kt:189` puts that extra on the notification `PendingIntent`, but nothing in the repo reads it. Tapping the reminder just opens `MainActivity`. *Needed:* implement the handler or drop the extra.

13. **Queue Reminders toggle is duplicated in three places.** `PermissionsSettingsScreen` (`settings_screen.dart:265-298`), `AutomationSettingsScreen` (`:782-815`), and the offline banner icon (`offline_queue_banner.dart:168-217`). *Needed:* pick one canonical home.

14. **`LogoVariant.mark` is unreachable.** The enum has 5 values, but `_kLogoVariants` and the settings dropdown allow only 4. `test/features/settings/about_screen_test.dart:20` seeds `'mark'`, which the provider clamp silently rewrites to `'system'`. *Needed:* add a UI option or delete the enum value.

15. **`ExtractionCache` has one production consumer.** Only `FormatPickerScreen` uses it, despite a docstring that claims results are shared across the share overlay, auto-download, and preview. No `fast_fetch` symbol exists; "T01 fast-fetch" is Dart-side caching only. *Needed:* wire the overlay to the cache or correct the docstring.

16. **Local analytics under-report.** Neither `ShareOverlayScreen` nor any `FormatPickerScreen` records an event, so shares that arrive through the overlay are invisible and the dashboard counts are lower than reality. *Needed:* decide whether that is acceptable for a strictly local feature.

17. **`copy_link` has no test coverage.** Neither `download_overflow_menu_test.dart` nor `download_overflow_test.dart` asserts anything about the clipboard. *Needed:* add a clipboard assertion.

18. **Engine auto-retry provenance is unconfirmed.** `downloader.py:726-814` exists at HEAD, but no v0.0.4 changelog entry mentions auto-retry, so it may predate `eae1657`. *Needed:* confirm which commit introduced it.

19. **`DESIGN.md` has drifted from `app_theme.dart`.** The 2026-10-08 check found radius, `labelSmall`, and `BoxShadow` mismatches despite the file's own rule that `app_theme.dart` wins. *Needed:* re-check the three places and update `DESIGN.md` in one pass.

20. **`verify.yml` advertises a 70% coverage ratchet but enforces 75%.** The header comment at `verify.yml:5` says ">=70%"; line 80 runs `--cov-fail-under=75`. *Needed:* make the header match the gate.

## Resolved

- **`redesign/ui` merge.** The branch merged into `main`; v0.0.5 shipped on 2026-10-11 (`docs/CHANGELOG.md`). Older notes that call the redesign "branch-local", "not on `main`", or "unshipped" are historical.

- **Dirty working tree and untracked scratch.** The 12 modified files and scratch PNGs listed in the 2026-10-08 snapshot are gone. The tree is clean; `test_screenshot.png` and `session_*` are gitignored.

- **MaterialIcons font.** The two scratch tests that loaded `MaterialIcons-Regular.otf` (`test/redesign_verification_test.dart`, `test/capture_screen_test.dart`) are not in the tree. No current test references that font.

- **Flutter test count.** CI runs `flutter analyze` and `flutter test` on every PR, and the run for PR #14 (merge `4f35d27`) passed. The static count on 2026-10-20 is 583 `test(` / `testWidgets(` declarations across 84 test files; that is a declaration count, not an executed count.

- **Commit `05dc457`.** The Android 14 background-freeze fix is in `main`. The 2026-10-08 snapshot could not find it.

- **Tracked-doc typography drift.** `README.md`, `docs/architecture.md`, `docs/contributing.md`, `docs/features.md`, `AGENTS.md`, `.github/pull_request_template.md`, and `skills/studio-critic-loop/SKILL.md` now name Bricolage Grotesque for headings, Figtree for body, and IosevkaCharonMono for machine text. InstrumentSans remains only in legacy settings screens.

- **Log-export docs.** `docs/troubleshooting.md` now names MediaStore `Download/Grablytic-logs/` as the Android default and app-private `log-exports/` as the fallback.

- **Test-count drift.** Engine settled at 564 collected / 564 passed in 56.78 s on `redesign/ui` @ `bad0851` (yt-dlp 2026.08.19, Python 3.14.6, pytest 9.1.1). 41 `test_*.py` files. Recorded in [[dev-setup|dev-setup]].

- **Engine module count and `search_query` wiring.** 19 modules excluding `__init__.py` and `__main__.py`; the 19th is `url_guard.py`. `search_query` is imported in `__main__.py:11` and dispatched at `:183-189`, and is deliberately not in `_FAST_IPC_METHODS` so it runs on the 8-worker pool. Recorded in [[system-overview|system-overview]] and [[url-guard-ssrf|url-guard-ssrf]].

## Links

- [[index|index]]
- [[system-overview|system-overview]]
- [[dev-setup|dev-setup]]
- [[note|note template]]
