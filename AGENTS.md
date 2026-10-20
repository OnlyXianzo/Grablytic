# AGENTS.md

Working notes for anyone, human or agent, changing Grablytic. Read this before
you touch code. If something here conflicts with a closer `AGENTS.md`, the
closer file wins.

## What this project is

Grablytic is a media downloader for Android, Windows, and Linux. Flutter draws
the UI. A Python engine built on yt-dlp does extraction and downloading. On
Android, Kotlin sits between Flutter and Python through Chaquopy.

This is a student hobby project, vibe coded end to end with AI agents. A human
maintainer verifies the result: reading the diff, running the test suites, and
trying the builds on real devices before a release. Real code, not AI slop:
every change has to compile, run, and survive the tests.

## Commands

Run these from the repo root.

```bash
flutter pub get
flutter analyze
flutter test
flutter test test/features/home/format_picker_output_test.dart
pytest engine/tests/ -v
pytest engine/tests/test_format_selector.py -v
python3 tool/check_doc_links.py
ruff check --select F --ignore F401 engine/
```

Python setup for the engine:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r engine/requirements.txt
pip install -e engine/
```

Builds:

```bash
flutter build apk --release
flutter build apk --release -PtargetAbi=arm64-v8a -PjsRuntime=deno
flutter build linux --release
flutter build windows --release
```

`flutter analyze` must report zero issues. Run the full test suite before you
say a change is done. If a command fails, report the failure and the output.
Do not describe a run you did not perform.

## Where things live

| Path | Role |
|---|---|
| `lib/features/` | Screens and widgets, grouped by feature |
| `lib/providers/` | Riverpod state |
| `lib/core/engine/` | Dart side of the engine bridge |
| `lib/core/theme/` | Colors and text styles |
| `lib/core/database/` | Download history SQLite |
| `engine/grablytic_engine/` | Python engine modules |
| `engine/tests/` | pytest suite |
| `test/` | Flutter widget and unit tests |
| `android/app/src/main/kotlin/com/theonly/grablytic/` | Kotlin native layer |
| `docs/` | Product docs |
| `skills/` | Published agent skills |
| `.agents/vault/` | Project knowledge notes, tracked; read before large changes |
| `.agents/` (rest) | Local agent workspace, ignored by git |

Useful docs: [architecture](docs/architecture.md),
[contributing](docs/contributing.md), [building](docs/building.md),
[security](docs/security.md), [troubleshooting](docs/troubleshooting.md),
[knowledge vault](.agents/vault/index.md).

## Hard rules

### Verify before you commit

- Write a failing test first when you fix a bug.
- Run the full relevant suite, not only the file you changed.
- Never weaken, skip, or rewrite a test to make a broken change pass.
- Never mark something healthy just because a file exists. Run it or probe it.
- If you could not test a platform, say so in the commit and the report.

### Keep user data private

- No telemetry, accounts, ads, or analytics SDKs. Crash reporting is off by
  default and only runs when the user enables it in Settings.
- Settings, history, logs, and optional cookies stay in app-private storage.
  Cookie files are written with `0600` permissions.
- `allowBackup="false"` stays. Do not add backup or cloud-sync paths for
  cookies, tokens, or history.
- Never log cookies, tokens, authorization headers, or signed URLs. The
  existing redaction in `AppLogger` and the Python logger is load-bearing.
- Do not add `REQUEST_INSTALL_PACKAGES`, helper APKs, or code that executes a
  downloaded binary on Android.
- Downloads are written to the folder the user picks. Treat downloaded media,
  archive members, and remote sites as untrusted input.

### Android platform traps

- Android 10+ enforces W^X. Executables must live in `nativeLibraryDir` as
  `lib*.so`. Do not copy a binary to app-private storage and `chmod +x` it.
- Every shared library needs its full `DT_NEEDED` closure. Versioned sonames
  such as `.so.1` are dropped by AGP and rejected by the platform loader.
- Chaquopy passes Java maps as proxies, not Python dicts. Coerce inputs before
  unpacking.
- `DownloadService` stays a `dataSync` foreground service with
  `START_NOT_STICKY` and `onTimeout()` stop. Do not switch it to
  `mediaPlayback` or add auto-restart flags.
- `EngineEventListener` stays a public interface. R8 strips anonymous
  callbacks in release builds.
- Bundled jniLibs paths win. Keep the SHA-256 pins and the in-place execution
  path in `BinaryPackageManager`.

### Engine

- Use the `YoutubeDL` class API. Never shell out to the yt-dlp binary.
- Blocking work runs in a thread with a cancel event. Do not block the IPC
  reader.
- Pass every binary path through `set_paths()`. Do not hardcode paths.
- Extract archives only through `_safe_extract_zip` / `_safe_extract_tar`.
  Never call `extractall()` directly.
- Clamp aria2c chunks to 1–16 and validate the speed argument. Never route
  DASH or HLS through aria2c.
- Do not set `merge_output_format` and `remux_video` at the same time.
- Subtitle post-processors run in this order: EmbedSubtitle, ModifyChapters,
  Metadata.
- Use timezone-aware UTC datetimes.

### Flutter

- Shared state goes through Riverpod. `setState()` is only for short-lived
  widget state such as a loading flag or a text controller.
- Colors come from `GrablyticColors`. Do not write hex literals in widgets.
- Headings use Bricolage Grotesque, body text uses Figtree. Numbers, URLs, and
  format codes use IosevkaCharonMono through the text theme. InstrumentSans
  remains only in legacy settings screens; migrate it when you touch them.
- Interactive targets are at least 48x48. Add semantic labels to icon-only
  controls.
- Use `const` constructors where they fit. Keep widgets free of business logic.
- Machine-readable output goes through the logger, not `print()`.

### Git

- Branch from `main`. Use a plain name such as `fix/engine-cancel-race` or
  `docs/publish-agent-guidance`. No codenames or agent names.
- Conventional commits: `type(scope): summary`. One logical change per commit.
- Open a pull request. Do not push directly to `main` and do not force-push a
  shared branch.
- Stage only product files. Private `.agents/` files, local notes, logs,
  `.env`, `key.properties`, keystores, and build output stay out. The tracked
  vault at `.agents/vault/` is the exception.
- Run `git status --short` before every commit and read the list.
- Do not commit secrets. If a credential ever lands in a commit, rotate it
  first, then clean history with the maintainer.

### Docs

- Update `docs/` when behavior, commands, or architecture change. Update the
  README when the user-facing story changes.
- Run `python3 tool/check_doc_links.py` after editing Markdown.
- Write for a new contributor. Concrete file names and commands beat abstract
  advice.
- Do not add internal audits, scratch notes, or work logs to `docs/`.
- The vault at `.agents/vault/` is tracked project knowledge. Keep it free of
  secrets, personal paths, and stale working-state notes.

## Writing style

This project gets a lot of AI-generated text. Keep it readable and specific.

- Start with the point. Skip the warm-up sentence.
- Prefer short, plain sentences. Mix lengths so it does not read like a
  template.
- Use "is" and "does". Avoid "serves as", "stands as", "acts as a testament".
- Do not use: delve, seamless, robust, leverage, landscape, pivotal, vibrant,
  tapestry, realm, unlock, elevate, game-changer.
- Do not use: "it's worth noting", "in today's world", "not just X but Y",
  "the future is here", "let's dive in".
- Do not stack hedges. One qualifier per claim.
- Do not invent numbers, benchmarks, or quotes. Cite the file, command, or
  test output.
- Do not use em dashes as a rhythm crutch. A period or a comma usually works.
- Avoid rule-of-three lists when two items are enough.
- End with something concrete. No "the possibilities are endless".

## Skills

Published skills live in [`skills/`](skills/README.md). Read the relevant
`SKILL.md` before using it.

Skills use placeholders for machine-specific paths:

- `$REPO_ROOT` defaults to `~/grablytic`.
- `$VAULT_ROOT` defaults to `$REPO_ROOT/.agents/vault`.

If a skill needs a path you do not know, ask the user. Record the answer in
`.agents/local-paths.md` (ignored by git) and use it locally. Do not hardcode
personal paths into tracked files, and do not push a local path file.

## Before you open a pull request

- [ ] `flutter analyze` is clean.
- [ ] `flutter test` passes.
- [ ] `pytest engine/tests/ -v` passes.
- [ ] `python3 tool/check_doc_links.py` passes if Markdown changed.
- [ ] New behavior has a test.
- [ ] No secrets, logs, build output, or private `.agents/` files are staged.
      The tracked vault at `.agents/vault/` is the exception.
- [ ] The PR description says what changed, why, and what you ran.
