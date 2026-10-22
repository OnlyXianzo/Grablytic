<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/brand/grablytic_logo_dark.png">
  <source media="(prefers-color-scheme: light)" srcset="assets/brand/grablytic_logo_light.png">
  <img src="assets/brand/grablytic_logo_light.png" alt="Grablytic" width="150" />
</picture>

# Grablytic

A media downloader for Android, Windows and Linux.
Flutter for the app, yt-dlp for the actual work, no accounts and no telemetry.

**[grablytic.vercel.app](https://grablytic.vercel.app)**: screenshots, install
notes, and the longer version of what this is.

[![CI](https://img.shields.io/badge/CI-verify.yml-brightgreen?logo=githubactions&logoColor=white)](.github/workflows/verify.yml)
[![Version](https://img.shields.io/badge/version-0.0.6-blue)](pubspec.yaml)
[![License](https://img.shields.io/badge/license-GPL--3.0-blue)](LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Python](https://img.shields.io/badge/Python-3.11-3776AB?logo=python&logoColor=white)](https://www.python.org)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/OnlyXianzo/Grablytic)

[Install](#install) · [What it does](#what-it-does) · [What changed](#what-changed-in-006) · [Architecture](#how-it-fits-together) · [Build it](#build-it-yourself) · [Docs](#docs)

</div>

---

## What this is

Grablytic takes a link and gives you the file. It hands the extraction off to
yt-dlp, which covers well over a thousand sites, and wraps it in an app that
keeps the fiddly parts out of your way: picking the right stream, merging
video and audio, embedding subtitles and chapters, resuming a download that
died halfway.

It runs on Android 7.0 and up (the build sets `minSdk 24`), Windows 10/11 and
Linux. iOS is not
supported and there is no plan for it, mostly because everything here leans on
being able to spawn processes and write into the filesystem.

The project is at `0.0.6`, still early. It works and it is used, but treat it
like beta software: read the release notes, keep a backup of anything you
care about.

## Install

**Android, via Obtainium.** This is the easiest path and it keeps you updated.
Install [Obtainium](https://github.com/ImranR98/Obtainium/releases) first, then
tap one of the links in the table below. If the tap does not do anything, open
Obtainium, choose *Add App* and paste
`https://github.com/OnlyXianzo/Grablytic`.

| Build | CPU | JS runtime | Good for |
|---|---|---|---|
| [arm64 + Deno](https://apps.obtainium.imranr.dev/redirect?r=obtainium://app/%7B%22id%22%3A%22com.theonly.grablytic%22%2C%22url%22%3A%22https%3A%2F%2Fgithub.com%2FOnlyXianzo%2FGrablytic%22%2C%22author%22%3A%22OnlyXianzo%22%2C%22name%22%3A%22Grablytic%22%2C%22additionalSettings%22%3A%22%7B%5C%22apkFilterRegEx%5C%22%3A%5C%22arm64-deno%5C%22%7D%22%7D) | arm64-v8a | Deno | most modern phones, start here |
| [arm64 + Node](https://apps.obtainium.imranr.dev/redirect?r=obtainium://app/%7B%22id%22%3A%22com.theonly.grablytic%22%2C%22url%22%3A%22https%3A%2F%2Fgithub.com%2FOnlyXianzo%2FGrablytic%22%2C%22author%22%3A%22OnlyXianzo%22%2C%22name%22%3A%22Grablytic%22%2C%22additionalSettings%22%3A%22%7B%5C%22apkFilterRegEx%5C%22%3A%5C%22arm64-node%5C%22%7D%22%7D) | arm64-v8a | Node.js | arm64 phones, roughly 40 MB smaller |
| [armv7 + Node](https://apps.obtainium.imranr.dev/redirect?r=obtainium://app/%7B%22id%22%3A%22com.theonly.grablytic%22%2C%22url%22%3A%22https%3A%2F%2Fgithub.com%2FOnlyXianzo%2FGrablytic%22%2C%22author%22%3A%22OnlyXianzo%22%2C%22name%22%3A%22Grablytic%22%2C%22additionalSettings%22%3A%22%7B%5C%22apkFilterRegEx%5C%22%3A%5C%22armv7-node%5C%22%7D%22%7D) | armeabi-v7a | Node.js | older 32-bit budget phones |
| [x86_64 + Deno](https://apps.obtainium.imranr.dev/redirect?r=obtainium://app/%7B%22id%22%3A%22com.theonly.grablytic%22%2C%22url%22%3A%22https%3A%2F%2Fgithub.com%2FOnlyXianzo%2FGrablytic%22%2C%22author%22%3A%22OnlyXianzo%22%2C%22name%22%3A%22Grablytic%22%2C%22additionalSettings%22%3A%22%7B%5C%22apkFilterRegEx%5C%22%3A%5C%22x86_64-deno%5C%22%7D%22%7D) | x86_64 | Deno | emulators, Chromebooks |
| [x86_64 + Node](https://apps.obtainium.imranr.dev/redirect?r=obtainium://app/%7B%22id%22%3A%22com.theonly.grablytic%22%2C%22url%22%3A%22https%3A%2F%2Fgithub.com%2FOnlyXianzo%2FGrablytic%22%2C%22author%22%3A%22OnlyXianzo%22%2C%22name%22%3A%22Grablytic%22%2C%22additionalSettings%22%3A%22%7B%5C%22apkFilterRegEx%5C%22%3A%5C%22x86_64-node%5C%22%7D%22%7D) | x86_64 | Node.js | same, smaller download |
| [universal](https://apps.obtainium.imranr.dev/redirect?r=obtainium://app/%7B%22id%22%3A%22com.theonly.grablytic%22%2C%22url%22%3A%22https%3A%2F%2Fgithub.com%2FOnlyXianzo%2FGrablytic%22%2C%22author%22%3A%22OnlyXianzo%22%2C%22name%22%3A%22Grablytic%22%2C%22additionalSettings%22%3A%22%7B%5C%22apkFilterRegEx%5C%22%3A%5C%22universal%5C%22%7D%22%7D) | all | both | if you have no idea which one you need |

The APKs are built by [`build.yml`](.github/workflows/build.yml) and attached
to each release as `grablytic-v<version>-<variant>.apk`. Release builds are
published as normal (not pre-release) releases so Obtainium picks them up.

> Renamed from TrueStream in 0.0.2. The application ID changed from
> `com.theonly.truestream` to `com.theonly.grablytic`, so Android treats it as
> a brand new app. If you are coming from the old build, install Grablytic
> fresh and then remove TrueStream; your `Download/TrueStream` folder is
> renamed on first launch. There is a note about the data migration in
> [`docs/troubleshooting.md`](docs/troubleshooting.md#truestream--grablytic-rename-data-migration).

**Linux, one command.** The script works out your distro and architecture,
checks the SHA-256 and installs the native package:

```bash
curl -fsSL https://raw.githubusercontent.com/OnlyXianzo/Grablytic/main/install.sh | bash
```

If you would rather do it by hand, download the `.deb`, `.rpm` or
`.pkg.tar.zst` for your distribution from the
[releases page](https://github.com/OnlyXianzo/Grablytic/releases) and install it
with your package manager. A real APT repository is on the list but not done
yet; until then these one-shots are the whole story.

## What it does

**Downloading.** yt-dlp handles the extraction; Grablytic decides what to ask
it for. Formats are ranked AV1 → VP9 → H.264 with a quality ceiling you set, so
"best" means the best your device can actually play rather than the largest
file on offer. Playlists and channels get their own selection screen where you
can reorder, shuffle or drop entries before anything starts. There is a queue
with a configurable concurrency limit (one to five, two by default) and a
per-item menu for the usual follow-ups: download again, grab just the audio,
delete the file, or read that download's log.

**Media handling.** Thumbnails embedded into the file, chapters split or kept,
subtitles embedded as real subtitle tracks instead of loose `.srt` files next
to the video, and SponsorBlock segments marked or cut. Section cutting
(`*10:15-20:00`) works through FFmpeg alone, so it needs nothing extra
installed.

**Resuming.** Every download writes progress into SQLite as it runs. If the app
dies, gets killed by the system, or the phone reboots, the next start sweeps
anything unfinished into an `interrupted` state and offers to pick it up from
where it stopped. Filesystem `.part` files are also scanned as a fallback, so a
download that lost its database row still gets found.

**Errors that say something.** Failures come back typed (`GEO_BLOCKED`,
`RATE_LIMITED`, `ERROR_DRM`, and so on) with `recoverable` and `suggests_vpn`
flags, and the UI offers the matching action. You should not have to read a raw
traceback to know that the video is region-locked.

**Android specifics.** FFmpeg and Deno/Node ship inside the APK, so there is no
"install this helper app" prompt and no `REQUEST_INSTALL_PACKAGES` permission.
Downloads run in a foreground service with a progress notification and survive
screen lock. Sharing a link from another app opens a small sheet asking what
you want before anything downloads. PO tokens and YouTube's JS challenges are
handled by Deno, Node or QuickJS, in that order of preference.

**Privacy.** No account, no analytics, no ad SDKs. Cookies and logins are
opt-in and, when you do use them, stored in app-private files with owner-only
permissions rather than in the settings blob.

Crash reports are the only thing that ever leaves the app, and they only leave
when you press Send. When something goes wrong the app writes a redacted report
into its own folder. That happens whether or not you have opted into anything,
because otherwise the next launch would have nothing to offer you. On the next
launch a dismissible banner says we ran into a problem and asks what to do:
**Not now**, **Review report**, or **Send report**. The same report is always
under Settings → Report a problem, where a sentence and a
category are enough; the diagnostics are gathered for you and shown before
anything is sent. There is no GitHub token inside the app, so sending opens a
prefilled GitHub issue form in your browser and you press Submit there. The app
says exactly that instead of pretending it filed something.

*Send crash reports automatically* (Settings → System & Diagnostics) is a
separate switch and is off until you turn it on. Even then nothing is uploaded
by a build that has no token, which is every normal build.

The Python engine's own notifier is a developer tool: it needs
`GRABLYTIC_AUTO_REPORT=1` and a `GITHUB_TOKEN` in its environment, neither of
which a normal install sets. It never runs because the in-app switch is on.

Diagnostics are limited to the exception, the stack trace, app version,
platform, time, the category, and a short recent-log excerpt. URLs and local
paths are stripped, credentials and headers are masked, and redaction fails
closed rather than sending text it could not parse. A report can still contain
unforeseen private text, so read the draft before submitting. Capture covers
Flutter/Dart errors and an unexpected engine exit; it cannot recover a native
Android process crash or a forced OS termination. Uninstalling removes the
app's private data, and files you downloaded stay wherever you saved them.

## What changed in 0.0.6

Most of this release is about what the app does when something fails.

- **Crash reports are captured even when you never opted in**, written to the
  app's own folder, and offered on the next launch. Sending is still your
  decision, and Send opens a prefilled GitHub form you submit yourself.
- **An unexpected engine exit is reported.** It used to disappear behind the
  restart that follows it.
- **Redaction covers more of what leaks in practice**: `Basic` as well as
  `Bearer` credentials, whole header lines, every cookie in a header, and
  signed-URL expiry values. The app and engine scrubbers now agree.
- **One version everywhere.** About, the report composer and a crash body read
  the same stamped value instead of three hardcoded strings.
- **"Detailed engine logging" reaches yt-dlp**, not just the app log.
- **The interrupted-downloads card finds nested downloads** and aria2c control
  files, matching what the resume scan actually looks at.

The two review rounds behind 0.0.5 and 0.0.6 are written up in the
[changelog](docs/CHANGELOG.md) and the [audit records](docs/audits/), including
the findings that are still open.

## How it fits together

```
Flutter UI (Riverpod)
        │  EngineService  (one interface, two transports)
        ├── Android: Chaquopy + MethodChannel/EventChannel, Kotlin event callbacks
        └── Desktop: line-delimited JSON-RPC over the engine's stdin/stdout
        │
Python engine (yt-dlp's YoutubeDL API)
        opts · formats · downloader · hooks · errors · playlist
        resume · bootstrap · po_token · logger · persistent · notifier
```

A few rules keep that honest:

- yt-dlp is used through its `YoutubeDL` class, never by shelling out to the
  binary. Errors stay catchable, options stay typed.
- Each download runs in its own thread with a cancel `Event`. Nothing blocks
  the IPC reader, including the fast-lane calls, which run inline.
- All binary paths go through `set_paths()`. No module reads `PATH` on its own.
- Riverpod owns shared state. `setState` is only used for local widget state.
- The engine speaks a versioned contract (`1.0`); a major mismatch is refused
  instead of half-understood.

Typography is Bricolage Grotesque for headings and Figtree for body text, with
Iosevka Charon Mono for anything that reads like code: format ids, URLs, byte
counts. InstrumentSans survives only in older settings screens and goes away
when those are touched.

The IPC methods are listed in
[`docs/architecture.md`](docs/architecture.md), along with the provider graph
and the event flow from yt-dlp hooks to a progress bar.

## Build it yourself

You need Flutter (3.x, Dart 3.11), Python 3.11, and the usual platform
toolchains. Android builds also want the NDK; the desktop targets are happy with the
compiler your platform already has.

```bash
git clone https://github.com/OnlyXianzo/Grablytic.git
cd Grablytic
flutter pub get
flutter run
```

Platform prerequisites, signing, and the release variants (including the
`-PskipNativePackages` flag that skips the bundled binaries for contributor
builds) are covered in [`docs/building.md`](docs/building.md).

### Engine development

```bash
python3 -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install -r engine/requirements.txt
pip install -e engine/
pytest engine/tests/ -q
```

One thing worth knowing: the desktop app looks for a venv inside its own
directory and inside its data directory, not in whatever directory you happened
to launch it from. If your checkout has the venv at the repo root, point the app
at it explicitly when running a debug build:

```bash
GRABLYTIC_PYTHON="$PWD/.venv/bin/python" flutter run -d linux   # or -d windows
```

Without that, it falls back to `python3` on `PATH`, which usually does not have
yt-dlp installed, and the first request will tell you so.

## Tests and CI

```bash
pytest engine/tests/ -q                       # engine suite
flutter test                                  # widget + unit tests
flutter analyze                               # must report no issues
ruff check --select F engine/                 # must be clean
```

CI is [`.github/workflows/verify.yml`](.github/workflows/verify.yml) and runs on
every push and PR:

| Job | What it checks |
|---|---|
| Flutter Analyze & Test | `flutter analyze` clean, `flutter test --coverage`, 30% project-lib coverage floor |
| Linux desktop build | installs the GTK/ninja build deps, builds the release bundle, asserts the `grablytic` executable exists |
| Python Engine Tests | pytest on 3.11 and 3.12, 75% engine coverage floor, Ruff `F`/`E9`/`W605` gate over `engine/` and `tool/`, broad-catch ratchet, version-literal gate, `pytest tool/tests` |
| Android API 35 | release lint, then a real emulator run through Flutter → Chaquopy → Python |
| Docs Link Check | every relative link in the root Markdown files and `docs/` resolves, inline, reference-style and HTML forms, anchors included |
| Secret Scan | gitleaks over the full history |
| Workflow YAML Lint | every workflow file parses and carries the required keys |

Coverage floors are ratchets, not targets. They exist so a change that deletes
tests fails the build rather than quietly lowering the number.

## Security notes

The short list of things that were deliberately made difficult:

- Archive extraction rejects absolute paths, `..`, null bytes, symlinks and
  device nodes (Zip-Slip and Tar-Slip).
- Direct HTTP(S) requests from the engine, including redirect hops, are pinned
  to vetted public addresses. Explicitly configured proxies are treated as a
  trusted egress boundary, because the proxy resolves the origin.
- JS that comes from the network is allowlisted by SHA-256 before it runs.
- aria2c arguments are clamped (one to sixteen connections) and aria2c is never
  used for DASH/HLS.
- Temp directories are `0700`, downloaded binaries are checksummed or the
  download fails, and timestamps are aware-UTC.
- Logs and crash reports are scrubbed before they leave the process. Capture is
  local and automatic so a crash is not lost; sending stays your decision.

Found something? Please use
[private vulnerability reporting](https://github.com/OnlyXianzo/Grablytic/security/advisories/new)
rather than a public issue. Details are in [`docs/security.md`](docs/security.md).

## If something breaks

| Symptom | What to try |
|---|---|
| YouTube downloads fail or stop at the format list | Check Diagnostics for `js_runtime`. It should read `deno` or `quickjs`. Re-run bootstrap; on desktop the Deno download needs network access. |
| FFmpeg missing (Android) | You are probably on a contributor build made with `-PskipNativePackages`. Rebuild with the packages, or set a custom FFmpeg path in Settings. |
| Progress sticks at 99% | On purpose. The last percent is reserved for the terminal `finished` event. Check the live log for the post-processing stage. |
| Resume finds nothing | The scan covers the cache directory and the download folder, including subfolders. Files older than 24 hours are listed as expired, and Resume is offered only for fresh files that still have a recoverable URL, from the `.info.json` sidecar when one exists. |
| Anything else | Settings → Diagnostics & Logs → Export gives you `app_logs.txt` and `server_logs.log`. |

Longer answers live in [`docs/troubleshooting.md`](docs/troubleshooting.md).

## Docs

| Document | What is in it |
|---|---|
| [Architecture](docs/architecture.md) | Layers, IPC contract, providers, data flow |
| [Building](docs/building.md) | Prerequisites, per-platform builds, signing, release variants |
| [Features](docs/features.md) | The full capability list, mapped to settings |
| [Troubleshooting](docs/troubleshooting.md) | Symptom → fix, log locations, FAQ |
| [Security](docs/security.md) | Policy, supported versions, how to report |
| [Output templates](docs/output_templates.md) | Filename fields, uniqueness, length limits |
| [JS runtimes](docs/JS_RUNTIMES_ANDROID_RESEARCH.md) | Why Deno comes first, and what the alternatives cost |
| [Audit records](docs/audits/) | The review rounds, one row per finding, frozen after the round |
| [Knowledge vault](.agents/vault/index.md) | Project notes on architecture, IPC, storage and open questions |
| [Agent skills](.agents/skills/README.md) | The reusable review and verification procedures |
| [Changelog](docs/CHANGELOG.md) | What shipped in each release |
| [Release notes](docs/release-notes.md) | How a release section is written |

## How this is built

A student hobby project, written end to end with AI coding agents. That part is
not hidden, because pretending otherwise would be the dishonest version. What
balances it is the other half of the loop: a human reads every diff, runs the
suites, installs the builds on real hardware (including a couple of cheap
32-bit phones, which is where most of the interesting bugs show up), and
decides what ships.

The upside is speed. The last three days of work would have taken me weeks by
hand. The downside is that generated code is very good at looking finished. So
every change has to compile, pass the tests, and survive a deliberately
adversarial review pass before it lands. The rules the agents work under are in
[`AGENTS.md`](AGENTS.md); the procedures themselves are published in
[`.agents/skills/`](.agents/skills/README.md) if you want to try them on your own
project.

## Contributing

1. Fork and branch from `main`, using a `feat/…` or `fix/…` prefix.
2. Follow [Effective Dart](https://dart.dev/effective-dart) and PEP 8. Shared
   state goes through Riverpod. Colours come from `GrablyticColors`, never from
   hex literals in a widget. Touch targets stay at 48×48 or larger and carry
   semantics.
3. One logical change per commit, [conventional commits](docs/contributing.md#commit-conventions).
4. Run `flutter analyze`, `flutter test` and `pytest engine/tests/` before you
   push. CI runs them too, but it is faster to find out locally.
5. Open the PR with why you made the change, what you ran to verify it, and
   which platforms you tried.

The full checklist is in [`docs/contributing.md`](docs/contributing.md). If you
are an agent, read [`AGENTS.md`](AGENTS.md) first.

## License and legal

Grablytic is licensed under the [GNU General Public License v3.0](LICENSE).
Participation is covered by the [Code of Conduct](CODE_OF_CONDUCT.md).

This is a general-purpose downloader. It fetches what you point it at; what you
point it at, and whether you may, is your call. Copyright holders who want
something removed can email **xianzo.help@gmail.com**; the full notice is in
[DMCA.md](DMCA.md).

<div align="center">

*Your media, your device, your rules.*

</div>
