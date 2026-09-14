# RENAME IMPACT ASSESSMENT — TrueStream → Grablytic

> **Status: PROPOSAL ONLY. Nothing has been renamed.**
> This document is the deliverable of a planning/assessment task. No source
> file, repo setting, website copy, DMCA contact line, distribution listing,
> branch, or commit history item was changed to produce it. Execution happens
> only after the user resolves the open decisions in §5.
>
> **Confirmed target name:** Grablytic (stylization still open — see D1).
> A session-level web check found no conflicting product, package, or repo
> using this exact name (WWW sources, npm, GitHub). That is a useful filter,
> **not** a legal clearance — a real registrar/trademark check is checklist
> item #1 in §4.

Method: `verified-implementation` skill discipline (multi-source research →
cross-verification → blast-radius map → ordered plan), stopped before any
implementation step. All repo paths below verified against `main` on
2026-09-14. Origin: `https://github.com/OnlyXianzo/TrueStream.git`.

---

## 1. Phase 1 — How real projects handle a rename (research findings)

Each claim carries a confidence level (high = multiple independent +
authoritative sources agree; medium = one authoritative or several weak).

### 1.1 GitHub repository rename — redirects are automatic, with two hard edges

- Renaming `OnlyXianzo/TrueStream` → `OnlyXianzo/Grablytic` automatically
  redirects **web traffic, `git clone`/`fetch`/`push`, issues, wikis, stars,
  followers** to the new location. No action needed from cloners, though
  updating local remotes is recommended.
  ([GitHub Docs — Renaming a repository](https://docs.github.com/en/repositories/creating-and-managing-repositories/renaming-a-repository), current; corroborated by the 2013–2019 repository-redirects announcement. **High.**)
- **Edge 1 — GitHub Pages project-site URLs are NOT redirected.** Renaming a
  repo with a Pages site breaks `*.github.io` links. Mitigation per GitHub:
  use a custom domain. Relevance here: the self-hosted F-Droid repo
  (`truestream-fdroid` per the distribution plan, served via GitHub Pages)
  and any Pages-hosted APT index would break unless fronted by a custom
  domain or re-pointed. (**High.**)
- **Edge 2 — reusing the old name kills the redirect.** If anyone (including
  the owner) later creates a repo at `OnlyXianzo/TrueStream`, all redirects
  to the new name stop working. Related: transferring a repo with 100+
  clones/Actions uses permanently retires the old name. Practical
  consequence: after renaming, **do not recreate anything at the old name**,
  and monitor it for squatting. (**High.**)
- Integrations (webhooks, CI references by URL) do not always follow
  redirects cleanly — e.g. documented AWS CodeBuild webhook breakage after
  renames. Our workflows reference `github.repository ==
  'OnlyXianzo/TrueStream'` (see §2.6) and must be updated in the same pass.
  (**Medium-high.**)

### 1.2 Package registries — there is no "rename", only "new + deprecate"

- **npm:** no rename command exists. The procedure is: publish under the new
  name, then `npm deprecate` the old package pointing at the new one. The old
  name stays on the registry permanently as a tombstone.
  ([npm docs — deprecating packages](https://docs.npmjs.com/deprecating-and-undeprecating-packages-or-package-versions/); corroborated by production
  rename PRs such as `0gfoundation/0g-compute-ts-sdk` which shipped a thin
  re-export stub under the old name. **High.**)
- **Applicability to us:** limited but instructive. Our engine is **not**
  published to any registry (`pubspec.yaml: publish_to: 'none'`;
  `engine/pyproject.toml` name `truestream-engine` is consumed via Chaquopy
  `srcDir` + desktop bundle copy, never uploaded to PyPI). So there is no
  registry tombstone to maintain — but the *pattern* (new identity + pointer
  from old) is exactly what F-Droid/Flathub/AUR/WinGet each implement in
  their own way (see §1.4).
- **F-Droid:** the metadata filename **is** the application ID
  (`metadata/<app-id>.yml`). Maintainers treat an app-ID change as **a new
  app** (precedent: KOReader → `org.koreader.launcher.fdroid`, CoolReader —
  new metadata, deprecate/notify on the old listing).
  A pure *repo-URL* rename (same app ID) only needs the `SourceCode` /
  `IssueTracker` / `Changelog` / `Repo` fields updated.
  ([F-Droid forum](https://forum.f-droid.org/t/change-package-name-app-id-of-an-app-on-the-main-repo/13543),
  [submission guide](https://f-droid.org/docs/Submitting_to_F-Droid_Quick_Start_Guide/). **High.**)

### 1.3 SEO / domain rename — 301s do the work, Search Console assists

Verified against current Google guidance (Google Search Central + Search
Console help, both current as of 2026):

- Use **permanent server-side redirects (`301`/`308`)**, mapped **1:1 old URL
  → closest new URL**. Never bulk-redirect everything to the homepage; dead
  pages should return `404`/`410`. Avoid chains (>3 hops). (**High.**)
- `301`/`308` **do not lose PageRank** (Google's explicit statement).
  (**High.**)
- File a **Change of Address** in Search Console (domain-level properties
  only; each www/non-www/subdomain variant separately). It emphasizes
  crawling of the new site and forwards signals for **180 days**, then lapses.
  (**High.**)
- **Keep redirects live ≥ 1 year** (Google; Bing says 1–2 years) and **keep
  paying for the old domain ≥ 1 year** so it can't be re-registered
  maliciously. (**High.**)
- Do **one change at a time** (domain move first, redesign/CMS later) and
  avoid staggered/partial moves — Google explicitly warns partial migrations
  produce "messy" split-signal states. This supports a **big-bang website
  cutover**, not a page-by-page drift. (**High.**)
- Relevance: our accumulated search authority is small (pre-1.0, no custom
  domain in the repo — see §2.7), so the redirect burden is light. The rename
  itself **resolves** the SEO task's core finding (crowded "TrueStream"
  keyword space); keyword strategy must be redone around "Grablytic" at
  execution time (§2.9).

### 1.4 Android application ID — the highest-risk single item

- **"Once you publish your app, you should never change the application ID.
  If you change the application ID, Google Play Store treats the upload as a
  completely different app."** — Android developer docs (page updated Feb
  2026). Changing it requires the same signing cert *and* ID for updates;
  a changed ID installs **alongside** the old app, cannot update it.
  (Corroborated by a decade of Stack Overflow consensus + 2026 Base44
  postmortems. **High.**)
- This is **OS-level, not store-level**: it applies equally to
  Obtainium/direct-APK/F-Droid users. Changing `com.theonly.truestream`
  means every existing install must **uninstall + reinstall**, losing local
  data (`SharedPreferences`, SQLite history DB, `Download/TrueStream/`
  paths) unless a manual backup/migration is built.
- Real-world precedent for the alternative: Google's Talk → Hangouts rebrand
  kept package `com.google.android.talk` — display name changed, app ID did
  not. (**High.**)
- `namespace` (Kotlin/R-class) and `applicationId` can diverge safely **only
  because** `applicationId` is explicitly set (it is — see §2.2). Renaming
  code namespaces without touching `applicationId` preserves update
  continuity.
- **Per-channel rename mechanics if the ID does change:**
  - *Obtainium:* tracks by source URL and **detects GitHub repo renames**,
    prompting the user to update the URL
    ([PR #2742](https://github.com/ImranR98/Obtainium/pull/2742), wiki
    "Check for Repo Rename"). A repo-only rename is therefore near-seamless
    for Obtainium users. An **app-ID change is not**: the installed package
    and the new APK are different apps; users must add a new entry. **Medium-high.**
  - *F-Droid (official):* new `metadata/<new-id>.yml` submission; old listing
    annotated to point at the new one. Effectively a new listing. (**High**
    per §1.2.)
  - *IzzyOnDroid:* repo-URL rename = metadata/link update; app-ID change =
    new listing. (**Medium.**)
  - *Self-hosted F-Droid repo:* fully in our control — rebuild index under
    the new ID; old repo file can carry a migration note. (**High** — it's
    our infrastructure.)
  - *WinGet:* no rename primitive. Procedure per maintainers: one PR to
    **remove** each old-identifier version + a separate PR to **add** it under
    the new identifier (`OnlyXianzo.Grablytic`), submitted together; community
    `YamlCreate.ps1` has a "move package" helper. Breaking for
    `winget export`/`import` users.
    ([Discussion #316247](https://github.com/microsoft/winget-pkgs/discussions/316247). **High.**)
  - *Flathub:* resubmit under the new ID, add old ID to `provides`/`replaces`
    in the new metainfo, then publish an `end-of-life-rebase` on the old ID —
    Flatpak **prompts users to migrate and moves `~/.var/app` data
    automatically**. This is the smoothest app-ID migration of any channel.
    ([Flathub maintenance docs](https://docs.flathub.org/docs/for-app-authors/maintenance). **High.**)
  - *AUR:* upload new `pkgname`, request a **merge** of old into new
    (preserves votes/comments), use `provides`/`conflicts`/`replaces`.
    ([ArchWiki AUR guidelines](https://wiki.archlinux.org/title/AUR_submission_guidelines). **High.**)
  - *Accrescent:* not yet listed (distribution plan stage); if the rename
    lands first, just list under the new ID — no migration needed.
    (**Medium.**)

---

## 2. Phase 2 — Full blast-radius map

Format per item: **current → becomes**, plus special handling.
Nothing below has been changed — this is the map, not the work.

### 2.1 GitHub repo & git-level surfaces

| # | Item | Current | Becomes | Handling |
|---|------|---------|---------|----------|
| G1 | Repo name | `OnlyXianzo/TrueStream` | `OnlyXianzo/Grablytic` (org `OnlyXianzo` unchanged, per confirmed scope) | GitHub auto-redirects web+git (§1.1). Update local remotes. **Never recreate anything at the old name** (kills redirect). Monitor old name for squatters |
| G2 | Remote URL | `https://github.com/OnlyXianzo/TrueStream.git` (verified `git remote -v`) | `.../Grablytic.git` | `git remote set-url` on every clone incl. agent worktrees; `install.sh` `REPO=` constant; all docs links |
| G3 | Open branches (7+ active: `arjun/distribution-launch`, `anaya/onboarding-permissions`, `ishaan/dmca-notice`, `meera/obtainium-updater`, `priya/*`, `devraj/apk-size-split`, `aarav/log-audit`) | Base `main` at old URL | Same branches, new base URL | Rename first requires all agents to re-point remotes; **reason to execute the rename only when the tree is quiet** (see §4 ordering) |
| G4 | Tag `v0.0.1` + 13 release assets | Under old repo URL | Same tags/assets, new URL | Redirect covers old links, but release-asset *naming* for future releases changes (§2.6). Published checksums for v0.0.1 must never be re-cut |
| G5 | Commit history | Contains "TrueStream" throughout | **Untouched** — history is immutable record | Explicit non-goal per task scope |

### 2.2 Android application ID / package name — ⚠️ HIGHEST RISK

| # | Item | Current | Handling |
|---|------|---------|----------|
| A1 | `applicationId` + `namespace` (`android/app/build.gradle.kts:21,35`) | `com.theonly.truestream` | **Decision D2.** Changing breaks update continuity for every existing install (Obtainium/direct-APK; §1.4). Keeping preserves updates; only display name changes |
| A2 | Kotlin package dir `.../kotlin/com/theonly/truestream/` (5 files: `MainActivity.kt`, `DownloadService.kt`, `BootReceiver.kt`, `BinaryPackageManager.kt`, `ObservedSourcesPollWorker.kt`) | `package com.theonly.truestream` | Mechanical move if renamed; safe to rename independently of A1 *only if* `applicationId` stays pinned (it is explicit, so safe) |
| A3 | IPC channel strings (`MainActivity.kt:33-34` + Dart mirror `lib/core/engine/platform_channel_engine_service.dart` + README contract table) | `com.theonly.truestream/engine`, `.../progress`, `intent/shared_url` | **Both sides of the boundary must change together** — Kotlin + Dart + docs. Mismatch = silent engine death. If A1 is kept, these SHOULD still change only if the package dir changes; they are string constants, not OS identity — recommend aligning with whatever D2 decides, atomically |
| A4 | `AndroidManifest.xml:18` `android:label` | `TrueStream` | Display name — safe, change regardless of D2 |
| A5 | `android/app/packages.gradle.kts` (3 refs: native-package fetch into our jniLibs) |6793 URLs / paths with old name | Update in same pass as G1 (release URLs move) |
| A6 | `fastlane/metadata/android/en-US/` (`title.txt`, `short_description.txt`, `full_description.txt`, `changelogs/2.txt`) | "TrueStream …" | Rename title/summary/description; changelogs for already-shipped build 2 stay historical |

### 2.3 App display name & desktop metadata

| # | Item | Current → becomes | Handling |
|---|------|-------------------|----------|
| N1 | `pubspec.yaml:1` `name:` | `truestream` → `grablytic` | Dart package name; mechanical but touches imports? No — imports use relative/`package:truestream/`? **Verify**: check for `package:truestream/` imports before executing (grep flagged `lib/main.dart` etc. — include in execution checklist) |
| N2 | `lib/main.dart` — `TrueStreamApp` class + `title: 'TrueStream'` | Rename class + title | Class rename is a medium mechanical diff (referenced in tests? `test/` has 8+ refs via `frame_rate_audit` etc. — verify) |
| N3 | `AndroidManifest` label, Linux `my_application.cc:48,52` window titles, `linux/CMakeLists.txt` (`BINARY_NAME`, `APPLICATION_ID`), `windows/CMakeLists.txt` (`project()`, `BINARY_NAME`), `windows/runner/Runner.rc` (`CompanyName com.theonly`, `FileDescription/ProductName/InternalName/OriginalFilename truestream`), `windows/runner/main.cpp` window title | → Grablytic equivalents | All safe, user-visible. `APPLICATION_ID` Linux value is cosmetic (not Android app ID) but rename for consistency |
| N4 | Debian/RPM/Arch packaging in `.github/workflows/build.yml` (~30 refs: `Package: truestream`, `/opt/truestream`, `/usr/bin/truestream`, `.desktop`, icons) | → `grablytic` paths | Changing `/opt/truestream` + `/usr/bin/truestream` **orphans existing Linux installs** (package manager sees a new package; old files linger). Plan a `replaces`/transitional handling per format (deb `Replaces:`, rpm `Obsoletes:`, pacman `replaces=`) — cf. AUR §1.4 |
| N5 | Release-asset convention (`truestream-vX.Y.Z-<variant>.apk`, `truestream-<ver>-linux-*.tar.gz/.deb/.rpm/.pkg.tar.zst`, `truestream-windows-x64.zip`, `truestream.exe`) + `install.sh` (`REPO`, `[truestream]` log prefix, `PM_REMOVE truestream`, asset filename patterns) | → `grablytic-v…` convention | Old asset **filenames for v0.0.1 stay frozen** (checksums published). New convention applies from the first post-rename release. `install.sh` must handle both patterns during transition or cut over with a major-version note |

### 2.4 In-app UI strings (every screen — verified by grep)

| Screen/file | Current string(s) |
|---|---|
| `about_screen.dart` (6 refs) | Title `TrueStream`, body copy, `showLicensePage(applicationName: 'TrueStream')`, logo asset path, `_repoUrl`, `_feedbackEmail = 'truestream.support@gmail.com'` ⚠️ (product-tied email — decision D5) |
| `onboarding_screen.dart` + `onboarding_permissions_step.dart` (6+ refs) | Hero `TrueStream`, permission explainers ("TrueStream works without these…", "Exempting TrueStream…", "Finished files save to the TrueStream folder…"), `Downloads/TrueStream` path copy |
| `settings_screen.dart` | `About TrueStream` row, FGS notification copy ("TrueStream shows download progress…") |
| `log_viewer_screen.dart` | Bug-report prompt ("…from the TrueStream Android/desktop media downloader app"), issue-URL copy |
| `home_screen.dart` | Semantics label `TrueStream download icon` |
| `app_logger.dart` | Export dir `TrueStream-logs`, filenames `truestream-<stamp>-<name>` |
| `settings_provider.dart` | Default download dir `/storage/emulated/0/Download/TrueStream` (+ desktop equivalent) — ⚠️ changing the default orphans users' existing folders; needs migration/alias decision |
| Notifications (`DownloadService.kt`, 11 refs) | Channel/content text — check each of the 11 lines at execution |

### 2.5 Brand assets — new artwork required, not find-replace

- `assets/brand/truestream_logo.png`, `truestream_logo_circle.png`;
  `assets/branding/Truestream-logo.png` (note inconsistent capitalization);
  `distribution/flathub/truestream.png`; `distribution/aur/truestream.png`;
  Android `mipmap` launcher icons (from the square-icon task);
  website hero logo (when the site lands).
- `DESIGN.md:34` — the mark is a white geometric **"T"** in a hexagonal tile:
  letter-tied to the old name, must be redesigned, not recolored.
- 11 screenshots in `assets/screenshots/` (+ website showcase copies):
  `about-page.jpg` almost certainly shows "TrueStream" in-frame (About
  screen title); others need a visual pass at execution — do **not** assume
  they are name-free. Retake only the ones with the name visible.
- **Fonts need no change:** Instrument Sans (body) + Iosevka Charon (mono)
  are name-independent; nothing in `DESIGN.md` ties them to the word
  "TrueStream". The *token class names* (`TrueStreamColors`,
  `TrueStreamTextStyles.mono`) do need renaming as code identifiers (§2.8).
- Per task scope, **no new assets are produced in this pass** — commissioning
  them is prerequisite step P0 in §4.

### 2.6 Distribution channels (each has a different rename procedure — §1.4)

| Channel | State | Rename procedure |
|---|---|---|
| IzzyOnDroid | `distribution/izzyondroid/inclusion_request.md` (6 refs: repo URL, license URL, `truestream-v0.0.1-*.apk` names) | Same app ID → update links/names in place. New app ID → new listing |
| Self-hosted F-Droid | Planned `truestream-fdroid` Pages repo (branch work, not in `main` tree) | Ours to rebuild; Pages URL breaks on repo rename unless custom domain (§1.1 Edge 1). **Cheapest if named `grablytic-fdroid` from birth — argues for deciding before this ships** |
| Official F-Droid | Recipe draft `distribution/fdroid/com.theonly.truestream.yml` | Same ID → field updates. New ID → new `metadata/<new>.yml` + sunset note on old |
| Accrescent | Planned, not yet listed | List under new ID directly — no migration |
| Obtainium | README deep links (dozens; embed `com.theonly.truestream` + repo URL + `name=TrueStream` + per-variant `apkFilterRegEx`) | Repo-only rename: users get an in-app "repository moved" prompt (§1.4). App-ID change: every link must be regenerated **and** users must re-add the app |
| WinGet | `distribution/winget/manifests/o/OnlyXianzo/TrueStream/0.0.1/` (3 YAMLs) + `winget-create.yml` + `winget-submit-first.yml` (guard `github.repository == 'OnlyXianzo/TrueStream'`) | Identifier rename = remove-PRs + add-PRs per version (`OnlyXianzo.Grablytic`); update workflow guards/identifiers the same day |
| Flathub | `com.theonly.truestream.{yml,desktop,metainfo.xml}` + png | Resubmit new ID + `provides`/`replaces` + `end-of-life-rebase` — the only channel with **automatic user-data migration** |
| AUR | `PKGBUILD` (`pkgname=truestream-bin`, `provides/conflicts`, release URLs) + `.SRCINFO` + desktop/png | New `grablytic-bin` + merge request for votes/comments + `replaces=` |
| CI packaging (`build.yml`) | ~30 `truestream` refs (filenames, `/opt`, desktop entries, icon copy) | Rename in lockstep with N4/N5; keep v0.0.1 asset names reproducible |

### 2.7 Website — current state is simpler than the task premise

Verified in the `main` tree on 2026-09-14: **no `website/` dir, no `.vercel/`,
no `*.vercel.app` project file, no marketing-copy doc, no SEO findings doc.**
The website exists only as plan/branch work (`.agents/docs/master-distribution-and-web-plan.md`:
Astro static site `truestream-web`, Vercel Hobby, OS/arch router; owners:
Arjun/Priya). Consequences:

- There is **no live domain to 301-redirect yet** — if no custom domain was
  acquired (no evidence one was), the site can launch *as Grablytic from day
  one* and skip the SEO migration entirely (§1.3 becomes mostly moot).
- Execution checklist must still verify: Vercel project name, any custom
  domain purchase, `SoftwareApplication` schema `name`, meta/OG tags,
  sitemap, and the screenshot showcase (§2.5) — wherever that branch work
  currently lives.
- If a custom domain **was** acquired outside the repo, add the full §1.3
  playbook (1:1 301s, Change of Address, ≥1-year retention).

### 2.8 Code identifiers & engine (mechanical, large, low-risk-if-atomic)

- `TrueStreamColors` (`app_theme.dart`, 52 refs) · `TrueStreamTextStyles`
  (`text_styles.dart`) · `TrueStreamError` + `classify_error` (`errors.py`,
  8 refs) · `TrueStreamApp` (`main.dart`) · `truestream_engine` package dir +
  imports across **16 engine modules + `__main__`** + Chaquopy `srcDir`
  (`build.gradle.kts:117`) + desktop bundle copy (`build.yml:191,324`) +
  `python -m truestream_engine.*` invocations · `pyproject.toml`
  (`truestream-engine`, description, `Source` URL) · `DEFAULT_REPO =
  "OnlyXianzo/TrueStream"` (`github_notifier.py:33`) + Dart mirror
  (`github_reporter.dart`) · `DEFAULT_CFG`/user-agent strings (`config.py`,
  `opts_builder.py` 15 refs — check for UA/identifier strings) · log
  namespaces (`truestream_engine.*`) mirrored in **33 assertions in
  `test_log_bridge.py`** and 20+ other engine tests.
- Scale: `rg` counts **100+ files** containing the old name; test files alone
  account for ~100 assertions referencing it. This is a **large mechanical
  diff, not a quick edit** — it must land as one atomic commit + full suite
  (`flutter analyze` + `flutter test` + `pytest`) per AGENTS.md, because a
  half-renamed tree (Dart channel renamed, Kotlin not, or vice versa) is a
  dead app (§2.2-A3).
- Lower priority than user-facing surfaces, but do not split across releases.

### 2.9 Docs, legal, history

- **Actual doc set in `main`** (the task's premise names three files that do
  **not** exist — there is no `THREAT_REGISTER.md`, `QA_Test_Plan.md`, or
  `Deployment_Release.md` in `docs/`): `architecture.md` (37 refs),
  `building.md` (14), `contributing.md` (9), `features.md`, `troubleshooting.md`,
  `security.md`, `security-scans.md` (17), `JS_RUNTIMES_ANDROID_RESEARCH.md`,
  `testing/ACCESSIBILITY_AUDIT.md`, `testing/PERFORMANCE_AUDIT.md`,
  `CHANGELOG.md`, plus root `README.md` (36), `DESIGN.md` (8), `DMCA.md`
  (10), `SECURITY.md` (3), `CODE_OF_CONDUCT.md` (no refs — verify at
  execution), `LICENSE` (GPL-3.0, no name headers — verify at execution).
- `DMCA.md`: update project-name references; **keep `xianzo.help@gmail.com`
  unchanged** (person-tied, confirmed scope). Same for F-Droid `AuthorEmail`.
- **Notable discrepancy for D5:** `about_screen.dart` uses
  `truestream.support@gmail.com`, a *different, product-tied* address from
  the DMCA contact. Decide whether a `grablytic.*` address is created or a
  single person-tied address is used everywhere.
- `.agents/truestream/` (17 files incl. `full-plan.md`) + root
  `session-ses_f66e.md`: **recommend leaving as historical record** (they
  describe what actually happened under the old name), starting new logs
  under `.agents/grablytic/` post-rename. Decision D3 to confirm.
- License headers: none found referencing the project name (spot-check
  `LICENSE`, `build.yml` Maintainer/Copyright lines reference the
  *publisher* `OnlyXianzo`, which is unchanged). Confirm at execution.

### 2.10 SEO opportunity (genuine improvement, not just overhead)

The SEO task's core problem — a crowded "TrueStream" keyword space forcing a
long-tail workaround strategy — **disappears with Grablytic**, for which the
session-level check found no exact-name collisions. At execution: redo the
long-tail keyword strategy around "Grablytic" from scratch (don't port the
old keyword list), and apply the §1.3 redirect playbook only to whatever
authority actually exists by then (likely near-zero — verify Search Console
state first).

---

## 3. Phase 3 — Ordered execution plan (for when the user says go)

Reasoning principle: **identity flows downstream** — repo → code/package ID →
build artifacts → distribution listings → website/SEO. Each layer must agree
with the one above before the next moves, minimizing the window where
surfaces disagree. Irreversible steps are batched at an explicit go/no-go
gate (step 5).

**P0. Prerequisites (all reversible, do first):**
1. Resolve open decisions D1–D6 (§5).
2. Run the step-0 clearance checklist (§4, item 1): domains, trademarks,
   GitHub org/repo + npm/PyPI/package-name availability, F-Droid/Play
   collision check.
3. Commission new brand assets (logo, launcher icons, hero) — planning only
   in this pass, explicitly out of scope here.
4. Freeze the tree: land or shelve the 7 open branches (§2.1-G3); execute
   from a clean `main`.

**P1. Repository (easily reversible within minutes):**
5. Rename repo `TrueStream` → `Grablytic` on GitHub (redirects begin).
   Update local remotes, `install.sh` `REPO`, workflow `github.repository`
   guards. Verify: old URL redirects, CI triggers on the new name.

**P2. Codebase display-name + identifiers (reversible via revert, but large):**
6. Single atomic commit: display strings (§2.4), desktop metadata (§2.3-N3),
   `pubspec` name, Dart/Theme/engine identifiers (§2.8), IPC channels both
   sides (§2.2-A3), `DEFAULT_REPO` both sides, log/export dirname defaults
   (with old-dir fallback read), docs + README + DMCA copy.
   Verify: `flutter analyze` + `flutter test` + `pytest engine/tests/ -v`
   green; grep for残留 `truestream`/`TrueStream` shows only intentional
   historical hits.

**P3. ⛔ GO/NO-GO GATE — irreversible step (app ID + artifact identity):**
7. **Only after explicit user sign-off on D2:** change `applicationId`
   (and package dirs/namespaces) **or** formally keep it. Same commit-window:
   new release-asset naming convention (§2.3-N5), Linux `/opt` + binary paths
   with transitional `Replaces`/`Obsoletes` (N4), download-dir migration note.
   Cut the first `grablytic-v*` release. Old `truestream-v0.0.1` assets stay
   frozen. **Why here:** everything downstream (listings, Obtainium links)
   keys off this decision; reversing it means a *second* breaking migration.

**P4. Distribution listings (mostly reversible, some slow to review):**
8. Self-hosted F-Droid + Pages (ours — first, validates the new artifacts).
9. IzzyOnDroid metadata update (or new listing if D2=new-ID).
10. Official F-Droid (field updates or new `metadata/<new>.yml` + sunset note).
11. Flathub resubmit + `end-of-life-rebase` (only channel with auto-migration).
12. AUR new package + merge request.
13. WinGet remove+add PR pairs + workflow identifier updates.
14. Regenerate **all** Obtainium deep links in README (they embed app ID +
    repo URL + variant filters); publish a "re-add the app" notice if D2=new-ID.
15. Accrescent: list fresh under the new ID (no migration if we get there first).

**P5. Website & SEO (easily reversible right up to DNS cutover):**
16. Re-skin copy/meta/schema/sitemap to Grablytic; redo keyword strategy
    (§2.10); audit the 5 showcase screenshots for in-frame old name (§2.5).
17. If a custom domain exists by then: 1:1 301s + Change of Address +
    ≥1-year retention (§1.3). If still `*.vercel.app`: project rename only.

**P6. Close-out:**
18. Sunset notices on old listings (deprecation stubs where the channel
    supports them); keep old domain + GitHub redirect alive ≥1 year.
19. New logs continue under `.agents/grablytic/` (D3); old logs frozen.
20. Post-rename grep audit + full test suite + user-facing "we renamed"
    release notes + in-app notice (one release, then remove).

---

## 4. "Before you execute" checklist

1. **☐ Real clearance check** (session search was a filter, not clearance):
   domain availability (`.com`/`.dev`/`.app` + common alts), USPTO/relevant
   trademark-database search, GitHub repo/org name availability, npm + PyPI
   (`grablytic`, `grablytic-engine`) availability even though we don't
   publish there (defensive), F-Droid + Google Play package-name collision
   check for the candidate app ID, and a general web-pass for non-software
   collisions. Owner: user or a future task, **immediately before execution**.
2. ☐ D1–D6 resolved (§5) and recorded here.
3. ☐ New brand assets delivered (logo, launcher/mipmap set, hero, `.desktop`/store icons).
4. ☐ Tree quiet: open branches landed/shelved; `main` green.
5. ☐ `package:truestream/` imports, `LICENSE`/`CODE_OF_CONDUCT.md` name refs,
   `publish-release.yml` refs, UA strings, notification-text lines, and
   screenshot in-frame text all re-verified (spot-checks in this doc may have
   missed instances — the execution pass must end with a full `rg` audit).
6. ☐ Rollback note: P1–P2 revert cleanly; P3 (app ID) does not — hence the
   gate.

---

## 5. Phase 4 — Open decisions (user resolves; agent must not default these)

- **D1. Stylization:** `Grablytic` vs `GrabLytic` vs `grablytic` (display) and
  `grablytic` vs `grablytic-app` (slugs/IDs). Affects every surface; locks
  domains, package names, and asset prefixes.
- **D2. Android application ID: change or keep? (the big one).**
  Research (§1.4) says changing = fresh installs for all existing users
  (uninstall + reinstall, local data loss without a migration build) + new
  listings on F-Droid/WinGet/AUR (+ smooth Flathub rebase). Keeping
  (`com.theonly.truestream` under the hood, "Grablytic" on screen — the
  Talk→Hangouts precedent) = zero disruption, at the cost of a permanently
  mismatched internal ID. Outline which existing-install base matters:
  Obtainium early adopters + direct-APK users today.
- **D3. Historical logs:** recommendation is preserve `.agents/truestream/`
  + `full-plan.md` + `session-ses_f66e.md` as-is, start `.agents/grablytic/`
  fresh. Confirm or override.
- **D4. Timing:** big-bang (repo→code→listings→site in one window, §3) vs
  staged (e.g. repo + display name now, app-ID decision deferred — note that
  deferring D2 *after* re-listing channels means doing distribution twice).
- **D5. Support contact:** keep person-tied `xianzo.help@gmail.com`
  everywhere (and retire `truestream.support@gmail.com`), or create a
  product-tied `grablytic.*` address? DMCA line itself stays unchanged
  regardless.
- **D6. Asset/package naming:** confirm `grablytic-vX.Y.Z-<variant>.apk`
  convention, `/opt/grablytic` + `/usr/bin/grablytic` paths, `grablytic-bin`
  AUR name, `OnlyXianzo.Grablytic` WinGet ID, `com.theonly.grablytic`
  candidate app/Flatpak ID (only if D2 = change).

---

## Appendix — Sources consulted (Phase 1)

- GitHub Docs, "Renaming a repository" (current) + enterprise-cloud mirror +
  source markdown in `github/docs`.
- GitHub Blog, "Repository redirects are here!" (2013, updated 2019).
- GitHub Community discussions on redirect duration/reuse (#22669, #110367).
- npm Docs, "Deprecating and undeprecating packages"; npm naming-rules analysis
  (namekit, 2026); 0G SDK rename PR #203 + stub PR #204 (production precedent).
- Google Search Central: "Site moves with URL changes", "Redirects and Google
  Search", "Change of Address tool" help page; Stox migration checklist +
  Change-of-Address explainer (2026); BrightEdge 2025 migration guide;
  StanVentures/Mueller staggered-migration warning (Dec 2025).
- Android Developers, "Configure the app module" (Feb 2026); Stack Overflow
  consensus (multiple, 2013–2026); AxonBuild Base44 postmortem (Aug 2026).
- F-Droid: forum app-ID-change thread (KOReader/CoolReader precedent, 2021),
  submission guide, build-metadata reference, forum repo-rename thread (2023).
- WinGet: `winget-pkgs` discussions #316247 (identifier rename procedure),
  #236595 (Dev Proxy org-move precedent).
- Flathub: app-authors maintenance docs (`end-of-life-rebase`), metainfo
  guidelines (ID-rename + `provides`/`replaces`), Discourse threads.
- ArchWiki AUR submission guidelines (`replaces`/merge procedure); AUR forum
  rename threads.
- Obtainium: PR #2742 (repo-rename detection), issue #2637, wiki (App Sources,
  UI Overview).
- Repo ground truth: `git remote -v`, `android/app/build.gradle.kts`,
  `AndroidManifest.xml`, `MainActivity.kt` channel constants, `pubspec.yaml`,
  `engine/pyproject.toml`, `engine/truestream_engine/__init__.py`,
  `distribution/*`, `fastlane/metadata`, `.github/workflows/*`, `DESIGN.md`,
  `README.md`, `DMCA.md`, `install.sh`, full `rg` sweep (100+ files).

*Disagreements between sources: none material. Closest call: Google's "keep
redirects ≥180 days" (Search Console page) vs "≥1 year" (site-move guide) —
document uses the conservative 1-year figure, matching Bing's 1–2 years.
Uncertainties flagged inline (Accrescent/IzzyOnDroid medium-confidence items,
screenshot in-frame audit, `package:truestream/` import check).*
