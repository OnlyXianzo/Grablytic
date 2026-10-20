---
title: Grablytic Vault Index
date: 2026-10-20
tags: [grablytic, index, vault]
status: complete
---

# Grablytic Vault Index

Project knowledge vault for Grablytic (Flutter + Python [[system-overview|yt-dlp engine]] media downloader). The repository is the source of truth for code. This vault is tracked at `.agents/vault` and uses Obsidian wiki-links.

> **Reading on GitHub?** Obsidian wiki-links use double square brackets around a note name and do not render on GitHub. Open the target file by name in this folder.

> **Snapshot: 2026-10-20.** Most notes were first written 2026-10-08 against `redesign/ui` @ `bad0851`. That branch is merged into `main` and shipped in v0.0.5. Notes that say "updated against `redesign/ui` @ `bad0851`" record provenance, not current branch state. Product docs under `docs/` are the public source for current behavior.

## Link index (every wiki-link target in this vault must be one of these)

- [[index|index]]
- [[note|note template]] (`_templates/note.md`)
- [[architecture-decision|architecture-decision template]] (`_templates/architecture-decision.md`)
- [[open-questions|open-questions]] (`_inbox/open-questions.md`)
- [[system-overview|system-overview]]
- [[flutter-chaquopy-python-ipc|flutter-chaquopy-python-ipc]]
- [[download-pipeline|download-pipeline]]
- [[format-ladder|format-ladder]]
- [[batch-system|batch-system]]
- [[logging-diagnostics|logging-diagnostics]]
- [[storage-layout|storage-layout]]
- [[design-system|design-system]]
- [[url-guard-ssrf|url-guard-ssrf]]
- [[offline-queue-reminders|offline-queue-reminders]]
- [[local-analytics|local-analytics]]
- [[share-intent-flow|share-intent-flow]]
- [[engine-service-methods|engine-service-methods]]
- [[method-channel-surface|method-channel-surface]]
- [[dart-providers|dart-providers]]
- [[db-schema|db-schema]]
- [[settings-navigation|settings-navigation]]
- [[dev-setup|dev-setup]]
- [[nightly-release-workflow|nightly-release-workflow]]
- [[triage-export-workflow|triage-export-workflow]]
- [[bulk-archival-workflow|bulk-archival-workflow]]

## Architecture

- [[system-overview|system-overview]] — layered map: Flutter UI, Riverpod state, [[flutter-chaquopy-python-ipc|Kotlin bridge]], Python engine (19 modules), design layer.
- [[flutter-chaquopy-python-ipc|flutter-chaquopy-python-ipc]] — Android Chaquopy + [[method-channel-surface|MethodChannel/EventChannel]] + `onEvent` callback; desktop JSON-RPC stdio; main-thread discipline.
- [[download-pipeline|download-pipeline]] — URL → [[format-ladder|formats]] → `url_guard` gate → threaded `YoutubeDL` → hooks → FFmpeg PP → terminal event → transient auto-retry.
- [[format-ladder|format-ladder]] — tiered AV1→VP9→H264 ladder incl. the 2026-09-30 portrait fix, plus T01 extraction cache, T03 session toggles, T08 preview.
- [[batch-system|batch-system]] — multi-URL batch + playlists + FIFO queue; retry-failed, skip-existing, file import, storage meter, auto-retry.
- [[logging-diagnostics|logging-diagnostics]] — `AppLogger`, engine `logger`/`persistent`, live viewer, MediaStore export, GitHub dedup reporter; Dart 1 MB×5 chunks vs Python 2 MB×5.
- [[storage-layout|storage-layout]] — output dirs, app data, logs, cache, SQLite, thumbnails, and the SharedPreferences "local-only state" table.
- [[design-system|design-system]] — **new 2026-10-08.** Tokens (`GrablyticColors`/`Spacing`/`Radii`), 8 shared components, 5 bundled font families, `LogoVariant` + `AdaptiveLogo`, launcher icons.
- [[url-guard-ssrf|url-guard-ssrf]] — **new 2026-10-08.** The SSRF boundary: scheme/host/DNS-rebinding gates, the fail-open-on-DNS-failure residual, proxy carve-out, call sites.
- [[offline-queue-reminders|offline-queue-reminders]] — **new 2026-10-08.** T19 offline link queue + one-tap batch dispatch, T20 WorkManager reminders.
- [[local-analytics|local-analytics]] — **new 2026-10-08.** T21 strictly-local counters, 2000-event cap, failed-jobs list, why "no network" is provable.
- [[share-intent-flow|share-intent-flow]] — **new 2026-10-08.** `ShareActivity` + `shareMain` entrypoint, translucent overlay, T02 auto-download, clipboard capture.

## API

- [[engine-service-methods|engine-service-methods]] — `EngineService` abstract surface (all methods) + what deliberately did *not* grow it.
- [[method-channel-surface|method-channel-surface]] — IPC contract: the **complete** method-id table (Python vs Kotlin-only), envelopes, event shapes.
- [[dart-providers|dart-providers]] — Riverpod graph, plus the provider-less singletons and the offline-queue providers declared outside `lib/providers/`.
- [[db-schema|db-schema]] — SQLite `grablytic.db` v1→v4, tables, indexes, key queries, and what is deliberately *not* in SQL.
- [[settings-navigation|settings-navigation]] — **new 2026-10-08.** T14/T15 category list, 9 sub-screens, and a provenance-checked screen inventory (only 3 files are genuinely new).

## Guides

- [[dev-setup|dev-setup]] — Flutter + engine venv setup, test counts (2026-10-08), added deps, bundled fonts, build variants.
- [[nightly-release-workflow|nightly-release-workflow]] — nightly pipeline incl. the 10-commit gate, build matrix, rolling release, `verify.yml` jobs.
- [[triage-export-workflow|triage-export-workflow]] — diagnostics-first triage, expanded symptom table (aria2c, auto-retry, SSRF, disk), export paths.
- [[bulk-archival-workflow|bulk-archival-workflow]] — bulk/playlist/batch archival practice, incl. skip-existing semantics and offline capture.

## Inbox

- [[open-questions|open-questions]] — everything unclear from code; answered items graduate to notes above. **Read this before trusting any note.**

## Verification status (2026-10-20)

| Claim | How verified |
|---|---|
| Engine tests 564 passed (2026-10-08) | **Executed**: `PYTHONPATH=engine python3 -m pytest engine/tests/ -q` → `564 passed in 56.78s` |
| Module count 19, schema v4, 27 method ids, version 0.0.5+5 | Read directly from source |
| Screen inventory / "which files are new" | `git log --diff-filter=A` per file — **not** inferred from commit subjects |
| Flutter tests / `flutter analyze` | CI `Flutter Analyze & Test` passed on PR #14 (merge `4f35d27`). Static count on 2026-10-20: 583 declarations across 84 test files |

## Links

- [[index|index]]
- [[note|note template]]
- [[architecture-decision|architecture-decision template]]
