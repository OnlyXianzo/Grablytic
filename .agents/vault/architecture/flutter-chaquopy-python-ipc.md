---
title: Flutter ↔ Chaquopy ↔ Python IPC
date: 2026-10-08
tags: [grablytic, architecture, ipc, android, chaquopy]
status: complete
---

# Flutter ↔ Chaquopy ↔ Python IPC

Platform IPC between the Flutter UI and the Python engine. Repo paths: `lib/core/engine/`, `android/app/src/main/kotlin/com/theonly/grablytic/`, `engine/grablytic_engine/__main__.py`, `docs/architecture.md`.

> Updated 2026-10-08 against `redesign/ui` @ `bad0851`. The Chaquopy event bridge is unchanged. Two Kotlin components were added (`ShareActivity`, `QueueReminderWorker`) and the method surface grew by 11 ids — see [[method-channel-surface|method-channel-surface]] for the corrected table.

## Android path (Chaquopy + Kotlin)

- **Dart entry:** [[engine-service-methods|PlatformChannelEngineService]] (`[[engine-service-methods|platform_channel_engine_service.dart]]`).
- **Channels** (see [[method-channel-surface|method-channel-surface]]):
  - `MethodChannel com.theonly.grablytic/engine` — request/response.
  - `EventChannel com.theonly.grablytic/progress` — streaming progress.
  - `intent/shared_url` — share-intent receiver.
- **Kotlin bridge** (`[[flutter-chaquopy-python-ipc|MainActivity.kt]]`): Chaquopy startup, `paths/set` handling (bundled jniLibs win over Dart `bin/` paths), `EngineEventListener.onEvent(json)` callback sink, share-intent receiver, `DownloadService` start/update/done wiring, `download/queue_status` + `download/set_concurrency` + `download/clear_archive` handlers, `schedule/sync` handler, terminal alert routing.
  - `EngineEventListener` must stay a **public interface** (R8 strips anonymous `Any()` callbacks in release builds).
  - Kotlin Maps arrive in Python as Java proxies, not dicts — Kotlin sends config as JSON; Python `coerce_config()` normalizes.
- **Event delivery (current):** Python [[download-pipeline|hooks]] → `event_callback.onEvent(json)` → Kotlin → `EventChannel.Sink` → Flutter `Stream<Map>`. Replaces the old `startProgressPolling` queue path (no GIL/polling lag). Queue remains as fallback.
- **Binaries** (`[[flutter-chaquopy-python-ipc|BinaryPackageManager.kt]]`): resolves `libffmpeg.so`/`libdeno.so` in `nativeLibraryDir`, extracts `lib*.zip.so` support trees to `noBackupFilesDir/packages`, `--version` probes, zip-slip guard. Binaries run **in place** (copies won't execute on targetSdk > 28); `LD_LIBRARY_PATH` covers every support tree.
- **Keep-alive** ([[download-pipeline|DownloadService.kt]]): `dataSync` foreground service, ongoing progress notification, `START_NOT_STICKY`, `onTimeout` stop. Covers process *survival*; process *death* is covered by [[batch-system|DB resume]] + `BootReceiver` sweep (never starts FGS directly — Android 14+ background limits).
- **Background polling** (`ObservedSourcesPollWorker.kt`): WorkManager `observed-sources-poll`, inexact, battery/network constraints; two-tier poll (Atom RSS → Chaquopy `extract_flat`); dedup via [[db-schema|seen_source_videos]]; auto-queues to `downloads` as `pending`. Synced from Dart via [[engine-service-methods|syncSchedule]] / `schedule/sync`.
- **Second WorkManager job** (`QueueReminderWorker.kt`): `queue-reminders-poll`, 15-min flex, `ExistingPeriodicWorkPolicy.UPDATE`, battery-not-low only, self-cancels when the offline queue empties. Independent of the observed-sources worker. See [[offline-queue-reminders|offline-queue-reminders]].
- **Share activity** (`ShareActivity.kt`): a **separate Dart entrypoint** (`getDartEntrypointFunctionName() = "shareMain"`, `BackgroundMode.transparent`, `Intent.EXTRA_TEXT` as args) with its own `taskAffinity` and `excludeFromRecents`. See [[share-intent-flow|share-intent-flow]].

## Main-thread discipline (T09 pattern)

Two distinct guards, both **pre-dating** the 2026-10-02 wave (documented in `docs/CHANGELOG.md:32-35` for v0.0.4, 2026-09-17):

1. **Dart side** — `EngineEnvelope.decodeResponseAsync` (`lib/core/engine/engine_codec.dart:63-76`) moves JSON decoding of payloads ≥50 KB to a background isolate via `Isolate.run`, falling back to `{}` on throw. Applied on the Android transport for `getFormats`, `getPlaylistInfo`, `search` only; the desktop stdio path does not use it. Test: `test/core/engine/engine_codec_test.dart:78-98` (literally named `'T09: decodeResponseAsync …'`).
2. **Kotlin side** — `MainActivity.kt:614` *"T09: Start FGS synchronously on Main thread during user gesture"*: `DownloadService.start(...)` is invoked **inline on the Main thread inside the `download/start` handler** (`:615-624`), with only the Chaquopy call on `scope.launch(Dispatchers.IO)` (`:639`). Rationale in `DownloadService.kt:28-33` — `dataSync` FGS is capped (~6h/24h in background) and exceeding it without `stopSelf()` crashes; `BOOT_COMPLETED` must never start it (`BootReceiver.kt:12`, `ForegroundServiceStartNotAllowedException` on targetSdk 35+).

Every other MethodChannel branch follows the same shape: Python work on `scope.launch(Dispatchers.IO)`, reply only via `withContext(Dispatchers.Main) { result.success(...) }` — e.g. `download/clear_archive` `:663-675`, `log/export_to_downloads` `:918-944`, `engine/bootstrap` `:570-593`.

**Deep Doze is documented as a known limit, not fixed:** `DownloadService.kt:52-56` — *"deep Doze suspends network and ignores wake locks regardless of these holders … UIDT migration is the designated long-term path and a separate ticket"*.

> A commit `05dc457 "fix(T09): resolve Android 14 background freeze and UI-isolate blocking"` appears in the 2026-10-02 log **but its SHA is absent from this checkout** (no ref, no reflog). The T09 code above is therefore credited to the pre-existing implementation, not to that commit. See [[open-questions|open-questions]].

## Desktop path (JSON-RPC stdio)

- **Dart entry:** [[engine-service-methods|DesktopEngineService]] (`[[engine-service-methods|desktop_engine_service.dart]]`): spawns `python -m grablytic_engine`, `.venv` auto-detect (`engine/.venv` → root `.venv` → `python3`), line-delimited JSON-RPC with UUID correlation, 30 s timeout, auto-restart ≤3, crash-loop breaker.
- **Engine entry:** [[method-channel-surface|__main__.py]]: daemon `poll_queues` thread drains progress/result/log queues; stdin loop dispatches by method; slow extractions (formats/playlist/search) run on a bounded pool (8 workers) so cancel/status stay fast (fast-lane set: cancel, queue_status, set_concurrency, clear_archive + `paths/set` inline); stdout serialized under a lock; CLI one-shots (`bootstrap`, `formats <url>`).
- **Envelopes:** request `{"id","method","params"}`; response `{"id","result"}` or `{"id","error"}`; interleaved `{"type":"event",...}` and `{"type":"log",...}` on stdout. `ERROR_CANCELLED` maps to a distinct `cancelled` event (never `error`).

## Selection

`[[dart-providers|engineProvider]]` picks Android → PlatformChannel, Windows/Linux/macOS → Desktop, other → [[engine-service-methods|MockEngineService]] (tests/audits).

## Links

- [[index|index]]
- [[system-overview|system-overview]]
- [[method-channel-surface|method-channel-surface]]
- [[engine-service-methods|engine-service-methods]]
- [[download-pipeline|download-pipeline]]
- [[dart-providers|dart-providers]]
- [[db-schema|db-schema]]
- [[share-intent-flow|share-intent-flow]]
- [[offline-queue-reminders|offline-queue-reminders]]
- [[url-guard-ssrf|url-guard-ssrf]]
- [[logging-diagnostics|logging-diagnostics]]
- [[open-questions|open-questions]]
