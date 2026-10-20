---
title: Nightly Release Workflow
date: 2026-10-08
tags: [grablytic, guides, ci, release]
status: complete
---

# Nightly Release Workflow (incl. 10-Commit Gate)

Scheduled + manual release pipeline. Repo paths: `.github/workflows/nightly.yml`, `build.yml`, `verify.yml`, `publish-release.yml`, `winget-create.yml`, `winget-submit-first.yml`, `tool/generate_nightly_notes.py`, `tool/generate_release_changelog.py`, `install.sh`.

> **Re-verified 2026-10-08:** the 10-commit gate is intact and no workflow changed in that window. `pubspec.yaml` is now `0.0.5+5`; the redesign merged in v0.0.5. There are **6** workflow files; the two `winget-*` ones predate 2026-09-17.

## Pipeline (`nightly.yml`: gate → prep → verify → build → publish-nightly)

1. **gate — 10 new commits since `nightly`?** (added 2026-09-30, commit `30f2f5d`; env `MIN_COMMITS: '10'` at `nightly.yml:33`; outputs `should_run`, `commit_count`, `base`; gate job `:40-92`).
   - `workflow_dispatch` (manual) **bypasses** the gate (`should_run=true`, `commit_count=manual`, `:59-65`).
   - Scheduled runs: base = `refs/tags/nightly`, else newest `v*.*.*` tag (`:68-79`); `COUNT=$(git rev-list --count "$BASE"..HEAD)` (`:81`); `COUNT -ge THRESHOLD` (`:86-92`). Verified locally on 2026-09-30: `nightly..HEAD=116` → RUN; boundary 9 → SKIP, 10 → RUN.
   - `prep` needs `gate` + `if: should_run == 'true'`; verify/build/publish skip by cascade.
   - Why: nightlies rebuilt every night with no backlog, wasting CI minutes and spamming the rolling release.
2. **prep** — stamps `suffix=-nightly-<YYYYMMDD>-<sha>`, `datestamp`, `sha`.
3. **verify** (reused `verify.yml`) — `flutter analyze` + `flutter test` + `pytest`; red tree = no nightly, nothing uploaded.
4. **build** (reused `build.yml`, `publish_to_release: false`) — full matrix: 6 Android APKs (arm64-deno/node, armv7-node, x86_64-deno/node, universal), Linux `.deb`/`.rpm`/`.pkg.tar.zst`/`.tar.gz` (x64 + arm64), Windows portable zip. Keystore signing flows when `KEYSTORE_BASE64` set.
5. **publish-nightly** — `tool/generate_nightly_notes.py` → notes; stage assets (dated names); refresh rolling `nightly` tag **in place** (delete old dated assets first); prerelease. Emulator-Doze + FTL Robo jobs exist but are commented out (runner/secret constraints).

## Naming

- Nightly Android: `grablytic-v<ver>-nightly-<YYYYMMDD>-<sha>-<variant>.apk`; Linux `grablytic-<ver>-nightly-<…>-linux-<arch>.tar.gz` (+ `.pkg.tar.zst`; `.deb`/`.rpm` native conventions); Windows `grablytic-windows-x64-nightly-<…>.zip`. Release builds use empty suffix → Obtainium-safe identical names. Tags: `v<version-core>` from `pubspec.yaml` (currently `0.0.5+5`); rolling `nightly` tag refreshed in place.

## Verification job (`verify.yml`, 148 lines) — unchanged in this window

Jobs, in order: `flutter_verify` (`:33-56`: `flutter pub get`, `flutter analyze`, `flutter test --coverage`, uploads `coverage/lcov.info` as artifact `flutter-coverage`), `python_verify` (`:58-92`: matrix `["3.11","3.12"]`, `fail-fast: false`; `uv pip install --system yt-dlp pytest pytest-cov -e engine/`; `pytest engine/tests/ -q --cov=engine/grablytic_engine --cov-report=term --cov-fail-under=75`; ruff pinned to `astral-sh/ruff-action@278981a28ce3188b1e39527901f38254bf3aac89 # v4.1.0`, `version "0.16.7"`, `src "engine/"`, `args "check --select F --ignore F401 --output-format=github"`), `docs_links` (`:94-106`: `python3 tool/check_doc_links.py`), `secrets_scan` (`:108-118`: gitleaks, `fetch-depth: 0`), `workflow_lint` (`:120-148`: inline Python that `yaml.safe_load`s every workflow, asserts top-level `on`/`jobs`, handling the YAML 1.1 `on:`→`True` quirk at `:140-141`).

Concurrency `group: verify-${{ github.ref }}` with `cancel-in-progress: true` (`:28-30`).

**Documented non-gates** (`:9-16`): `dart format` (55 files predate formatting), a Flutter coverage floor (24%, artifact only), and ruff *style* rules (BLE/SIM etc.).

`bad0851 "fix(ci): make Verification green on redesign/ui"` changed **Dart source, not any workflow**: it removed two dead locals in `home_screen.dart` `_statusPlaceholder()` (`isCancelling`, `badgeText`, plus now-unused `is4k`) to clear `flutter analyze` exit 1, and made `adaptive_logo.dart` always load bundled assets via `Image.asset` instead of a CWD-dependent `File.existsSync` check, which had broken 3 `adaptive_logo_test` cases.

## Stable releases

`build.yml` manual dispatch → verify gate → all platforms → tag from `pubspec.yaml` → GitHub release (stable, not prerelease, so Obtainium picks it up; per-variant APK filters pin updates). `publish-release.yml` hardens afterward: `SHA256SUMS` (preferred fail-closed by `install.sh`, API-digest fallback) + keyless cosign/Sigstore bundles; `run_id` auto-resolves to the latest successful build of the tag commit. Linux one-liner: `curl -fsSL …/install.sh | bash` (distro+arch auto-detect, SHA256 verify); per-family `.deb`/`.rpm`/`.pkg.tar.zst` one-liners in README; APT repo + AUR `grablytic-bin` are next.

## Links

- [[index|index]]
- [[dev-setup|dev-setup]]
- [[system-overview|system-overview]]
- [[logging-diagnostics|logging-diagnostics]]
- [[open-questions|open-questions]]
