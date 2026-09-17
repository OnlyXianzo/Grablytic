# Troubleshooting

> Last updated: **2026-09-11**.

## First step: check Diagnostics

**Settings → Diagnostics & Logs** shows engine/bootstrap health
(`ffmpeg_ok`, `aria2c_ok`, `deno_ok`, `quickjs_ok`, `js_runtime`,
`yt_dlp_version`, `needs_update`) plus the **Live Stream** log viewer.
Export `app_logs.txt` + `server_logs.log` when filing issues — the
GitHub auto-reporter may already have filed a deduped issue.

## Symptom → fix

| Symptom | Likely cause | Fix |
|---|---|---|
| YouTube fails (SABR / `n`-sig / PO Token) | No JS runtime | `js_runtime` must be `deno`/`quickjs`. Re-run bootstrap; on desktop ensure network for the Deno fetch; on Android rebuild **with** native packages (not `-PskipNativePackages`). See `JS_RUNTIMES_ANDROID_RESEARCH.md`. |
| `ffmpeg` missing on Android | Contributor build without jniLibs | Rebuild without `-PskipNativePackages`, or set a custom FFmpeg path in Settings. Bundled `libffmpeg.so` runs in place — don't copy it elsewhere. |
| `deno` missing on desktop | Bootstrap skipped/failed | Re-run `engine/bootstrap`; check logs for SHA-256 or network errors. System `deno`/`node` on PATH is used as fallback. |
| Slow fragment downloads | aria2c off or DASH source | Enable aria2c (Wi-Fi), raise chunks (≤16). DASH/HLS always use the native downloader by design (CVE-2026-50574). |
| Stuck at 99% | Post-processing stage | By design: streaming progress caps at 99%; only terminal `finished` = 100%. Check Live Logs for the PP stage (merge / embed / chapters). |
| `finished` never arrives | Cancel race / client polling | Update to latest `main` — finished events are delayed-popped to avoid the polling race; terminal events carry `filesize_bytes`. |
| Resume finds nothing | Expired/misplaced files | Only `.part` + `.info.json` younger than 24 h in the cache dir qualify. Verify cache dir in `paths/set`. |
| Subtitles not embedded | Old version | Fixed Sept 2026 via `FFmpegEmbedSubtitle` PP. Ensure `embedsubtitles` is on and FFmpeg is healthy. |
| Chapters not cut | PP order / no categories | SponsorBlock categories must be non-empty; cutter runs EmbedSubtitle → ModifyChapters → Metadata. |
| Geo/rate-limit errors | Region / IP throttling | Error card shows VPN hint (`suggests_vpn`); try proxy, `geo_bypass`, sleep interval, or cookies. |
| `paths/set not called before bootstrap` | Wiring race | `engineStatusProvider` awaits the `setPaths` future — don't call `bootstrap()` first (fixed June 2026, still worth checking in custom forks). |
| Desktop engine restarts loop | Bad venv / missing module | Check `.venv` detection (`engine/.venv` → root `.venv` → `python3`); `PYTHONPATH` must include `engine/`. Logs show up to 3 auto-restarts. |
| `lintVital*` crash on release build | AGP/Kotlin-script bug | Already disabled in `build.gradle.kts`; leave disabled until AGP fix. |
| Notifications missing (Android) | FGS restrictions | `DownloadService` degrades gracefully — downloads continue without keep-alive rather than crashing. Check battery-optimization exemptions. |

## Log locations

| Layer | File | Notes |
|---|---|---|
| Flutter | `app_logs.txt` (app data dir) | 30 s flush worker; instant flush on ERROR/FATAL |
| Python | `server_logs.log` (data dir) | `RotatingFileHandler` |
| Bootstrap | `bootstrap_progress.jsonl` (data dir) | Per-step statuses |
| Live view | Settings → Diagnostics & Logs → Live Stream | Filter + export |
| Export | **Export log file** button (File Logs tab) | Android: app external `log-exports/` (no permission needed); desktop: `~/Downloads/Grablytic-logs/` |
| Full log | **Include full log** switch above the report button | Attaches up to 512 KB instead of the 100 KB tail |

## FAQ

**Do I need Deno/Node installed?**
No. Desktop bootstraps Deno automatically; Android ships `libdeno.so` in the
APK. System runtimes are only fallbacks.

**Why do binary updates need app updates on Android?**
Downloaded files can't execute on targetSdk > 28 — only APK-origin jniLibs
can. So `ffmpeg`/`deno` ride app releases; desktop keeps silent CDN updates.

**Which platforms are supported?**
Android 8+ (API 26+, primary), Windows 10/11, Linux (Ubuntu 20.04+, Fedora
34+, Debian 11+). iOS/Web are not supported.

## TrueStream → Grablytic rename: data migration

The Android application ID changed (`com.theonly.truestream` →
`com.theonly.grablytic`), so Android treats Grablytic as a **new app**: it
cannot auto-update an existing TrueStream install, and app-private data
(settings DB, history) does not carry over — install Grablytic, verify it
works, then uninstall the old app.

What **is** preserved automatically:

- **Download folder:** fresh installs use `Download/Grablytic`. If a
  legacy `Download/TrueStream` folder exists, it is renamed to
  `Download/Grablytic` best-effort on first run (see
  `getDefaultDownloadPath()` in `lib/providers/settings_provider.dart`).
  If the rename fails, the legacy folder keeps being used.
  Nothing is deleted; you can point Settings at either folder.
- **Linux native packages:** the `.deb` declares `Replaces:`/`Conflicts:`
  against the old `truestream` package; the AUR package declares
  `replaces=('truestream-bin')`. Remove any manually installed v0.0.1
  `truestream` package if your manager does not do it automatically
  (`install.sh --uninstall` only removes `grablytic`).
- **Old release assets:** `v0.0.1` files keep their `truestream-*` names and
  checksums forever (see `docs/security-scans.md`, which is intentionally
  preserved as a historical record). `install.sh` still installs them when
  pinned (`--version 0.0.1`) by falling back to the legacy asset names.
