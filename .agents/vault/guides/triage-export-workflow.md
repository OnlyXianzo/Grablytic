---
title: Triage and Export Workflow
date: 2026-10-08
tags: [grablytic, guides, triage, diagnostics]
status: complete
---

# Triage and Export Workflow

How to sort a failure and get the right logs out. Covers Diagnostics & Logs, [[logging-diagnostics|log layers]], export paths, the aria2c verdict, and the auto-report dedup contract.

> Updated 2026-10-08: the export **default is now Downloads via MediaStore** (T10), and the aria2c row no longer masks an unusable binary.

## 1. First step: Diagnostics

**Settings → Diagnostics & Logs** shows engine/bootstrap health (`ffmpeg_ok`, `aria2c_ok`, `deno_ok`, `quickjs_ok`, `js_runtime`, `yt_dlp_version`, `needs_update`) + live log stream. Do this before anything else. Common verdicts (from `docs/troubleshooting.md`):

| Symptom | Check | Fix |
|---|---|---|
| YouTube SABR / n-sig / PO Token | `js_runtime` must be `deno`/`quickjs` | Re-run bootstrap; desktop needs network for Deno fetch; Android must rebuild **with** native packages |
| FFmpeg missing (Android) | contributor build? | Rebuild without `-PskipNativePackages` or set custom path; bundled `.so` runs in place only |
| aria2c "on" but no speedup | **new:** search the live log for `aria2c enabled but unusable` | The engine now names the cause (`no aria2c_path configured` / `binary missing or not executable at <path>`) instead of falling back silently. The `Download config: … aria2c=no|yes` line tells you whether it actually engaged. Android bundles no aria2c at all — the engine reports that as `unsupported` |
| Slow fragments | aria2c off / DASH source | Enable aria2c (Wi-Fi), chunks ≤16; DASH/HLS stay native by design |
| Stuck at 99% | PP stage in live logs | By design (merge/embed/chapters); only `finished` = 100% |
| Intermittent failure, then success | engine log `auto-retry attempt` | Transient errors retry up to 2 times (3 attempts) inside the same queue slot, backoff 5 s then 15 s. Permanent types never retry: `ERROR_PRIVATE`, `ERROR_UNAVAILABLE`, `ERROR_DRM`, `ERROR_QUOTA_EXCEEDED`, `ERROR_FORMAT_UNAVAILABLE`, `ERROR_FFMPEG_MISSING`, `ERROR_FILENAME_TOO_LONG`, `ERROR_CANCELLED` |
| `URL must be a public http(s) address` | the URL failed the SSRF gate | Localhost/private-IP targets, non-http(s) schemes and URLs with embedded `user:pass@` are rejected before admission — see [[url-guard-ssrf|url-guard-ssrf]] |
| Resume finds nothing | cache dir + age | Only `.part` + `.info.json` <24 h in `cache_dir` qualify |
| Geo/rate-limit | error card VPN hint | Proxy, `geo_bypass`, sleep intervals, cookies |
| "Disk … MB free" in logs, downloads still die | no threshold exists | The engine only **logs** free space; ENOSPC stays invisible until a write fails. Check it yourself with the [[batch-system|storage meter]] |

## 2. Triage the failure class

1. **Classify:** read the Error Recovery card (`error_type`, `recoverable`, `suggests_vpn`) — never the raw string. Per-download log (queue card / history row / overflow menu → log sheet) gives the `download_id`-correlated trail.
2. **Scope:** one URL (try format picker + `Best` ceiling — rules out the [[format-ladder|ladder]]) vs all URLs (engine/bootstrap or network) vs one site (cookies/profile/JS runtime).
3. **Dedup:** the GitHub auto-reporter (`[[logging-diagnostics|github_notifier]]` + `GithubReporter`) search-files crashes — check existing issues before filing; attach the export from step 3.
4. **Route:** engine defect → Python module owner (see [[system-overview|system-overview]]); IPC/transport → [[method-channel-surface|method-channel-surface]] + [[flutter-chaquopy-python-ipc|flutter-chaquopy-python-ipc]]; UI/state → [[dart-providers|dart-providers]]; data loss on death/reboot → [[batch-system|batch-system]] + [[db-schema|db-schema]] sweep path.

## 3. Export logs (so the report is actionable)

- **Live view:** filter by level/tag/search/source, tap-to-expand, auto-scroll; capped tail render (100 KB/1000 lines) keeps big logs safe. The viewer scrolls the full viewport via a collapsible card (T13).
- **Export button** — `exportLogToDownloads` / `log/export_to_downloads`. Default destination is **`Download/Grablytic-logs/`** via MediaStore (API 29+), with legacy paths below 29. Filename `grablytic logs - YYYY-MM-DD HH-mm-ss.log` — **dashes, not colons**, because colons are illegal in MediaStore display names on some launchers/MTP.
- **Both sinks are flushed first** — Kotlin calls `persistent_flush` *and* `flush_log_sinks` before copying, so `server_logs.log` and `engine_YYYY-MM-DD.txt` are both complete.
- **Over 5 MB exports as a tail** (header + last 5 MB). **Android only** — the desktop path copies the whole file.
- **Fallback** only when MediaStore fails: app-private `Android/data/<pkg>/files/log-exports/` on Android (needs no permission under scoped storage), `~/Downloads/Grablytic-logs/` on desktop. The UI says `'Downloads unavailable (<reason>) — exported instead to: <path>'`.
- **Full-log toggle:** attaches up to 512 KB instead of the 100 KB tail for the GitHub report.
- Files: `app_logs.txt` + `log_YYYY-MM-DD.txt` (Flutter, 30 s flush, **1 MB × 5 chunks**, no day-based retention) and `server_logs.log` (Python, **2 MB × 5 backups**); bootstrap trail in `bootstrap_progress.jsonl`. See [[logging-diagnostics|logging-diagnostics]] and [[storage-layout|storage-layout]].

> `docs/troubleshooting.md:40` still documents the *fallback* path as if it were the default. When following that doc, prefer this note.

## Links

- [[index|index]]
- [[logging-diagnostics|logging-diagnostics]]
- [[download-pipeline|download-pipeline]]
- [[format-ladder|format-ladder]]
- [[batch-system|batch-system]]
- [[db-schema|db-schema]]
- [[url-guard-ssrf|url-guard-ssrf]]
- [[open-questions|open-questions]]
