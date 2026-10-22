# Contributing

> Last updated: **2026-10-21**.

Thanks for contributing to Grablytic.

The project ships with a [Code of Conduct](../CODE_OF_CONDUCT.md). By taking
part, you agree to it.

## Getting Started

1. Fork the repository.
2. Create a feature branch from `main`.
3. Make your changes following the code style and guidelines below.
4. Verify your changes pass all checks.
5. Submit a pull request targeting `main`.

## Code Style

### Flutter / Dart

- Follow [Effective Dart](https://dart.dev/effective-dart) guidelines and the settings in `analysis_options.yaml`.
- Use **Riverpod** for shared state. Never use `setState()` for state shared across widgets. Use `ConsumerWidget` / `ConsumerStatefulWidget` with providers.
- Headings use the bundled Bricolage Grotesque family, body text uses Figtree (`app_theme.dart`). InstrumentSans remains only in legacy settings screens; migrate it when you touch those screens. Mono text (speeds, URLs, format codes) uses `Theme.of(context).textTheme.mono` (the `GrablyticTextStyles` extension on `TextTheme` that provides IosevkaCharonMono).
- All colors must reference DESIGN.md tokens via `GrablyticColors`. Never hardcode hex values.
- Use `const` constructors where possible. Avoid mutable state in widgets.
- Aim for 48x48 minimum touch targets for interactive elements.
- Add semantic labels (`Semantics` widget) for screen reader support (WCAG 2.2 AA).
- Run `flutter analyze` before committing. It must pass with zero errors.
- Regexes with backslashes: use **triple-quoted raw strings** (`r'''…'''`),
  as `AppLogger._redact()` does. Plain raw strings with `\` escapes once
  produced a wall of analyzer errors.

### Python

- Follow **PEP 8** formatting standards.
- Use the `YoutubeDL` class API from yt-dlp. Never call `subprocess.run()` with the yt-dlp binary.
- All blocking operations must run in `threading.Thread` with a cancel event.
- Use structured JSON for Flutter communication. No `print()` statements for machine-readable output (use `get_logger()`, whose logs go to file + IPC queue).
- Keep functions focused on a single responsibility. Each module in `engine/grablytic_engine/` owns one concern.
- Use `set_paths()` to inject all binary paths. Never hardcode paths.
- Extraction of zips/tars: always go through `_safe_extract_zip` / `_safe_extract_tar` (Zip-Slip/Tar-Slip guards). Never call `extractall()` directly.
- JS execution: local snippets must be SHA-256-allowlisted via `verify_js_code()` (covers only the two inert PO-token stubs). Remote/fetched JS (the `ejs:github` challenge solver) is NOT covered by that gate. Its integrity comes from yt-dlp's SHA3-512
  checksum and version pin; do not claim otherwise (T0-6).
- Time: always use timezone-aware UTC datetimes.
- Run `pytest engine/tests/ -q` before committing. The whole suite must pass.

### Kotlin (Android)

- `EngineEventListener` must stay a **public interface** (R8 strips anonymous `Any()` callbacks in release builds).
- `BinaryPackageManager`: bundled jniLibs paths win; never `chmod +x` app-private copies and try to execute them (blocked on targetSdk > 28, so run them in place).
- `DownloadService` must stay `dataSync` type with `START_NOT_STICKY` + `onTimeout()` stop. Never use `mediaPlayback`/`specialUse` types or auto-restart flags.
- Never add `REQUEST_INSTALL_PACKAGES` or helper-APK flows.

## Commit Conventions

Use conventional commit format:

```
type(scope): description in present tense
```

Types: `init` (scaffold), `feat` (new feature/screen), `fix`, `chore` (config/deps), `docs`, `style` (formatting, no logic change), `refactor`, `test`, `perf`.

Scope is optional but recommended (e.g. task ID like `P4-003`, or `android`, `engine`, `logging`, `ci`).

**One logical change per commit.** Never bundle unrelated changes in a single commit. Each commit diff should be reviewable in under 2 minutes.

## Branch Strategy

- **main**: stable, always deployable.
- **feature branches**: branch from `main`, name by task (e.g. `feat/sponsorblock-settings`, `fix/cancel-race`).
- Squash merge into `main` when the PR is approved.

## Testing

Always run these before committing:

```bash
# Flutter static analysis
flutter analyze

# Flutter widget & unit tests
flutter test

# Python engine tests (needs yt-dlp installed: uv pip install --system yt-dlp pytest -e engine/)
pytest engine/tests/ -v
```

The CI pipeline in `.github/workflows/verify.yml` enforces all three on every push and PR.

### Testing conventions

- **Flutter tests**: Write widget tests for screens via `WidgetTester`. Mock providers using `ProviderScope` overrides. Place tests in `test/`.
- **Python tests**: Write pytest functions for each module in `engine/tests/test_<module>.py`. Use plain `assert` statements. One test class per module.
- **Security tests**: extraction guards (`test_bootstrap_extract.py`), JS allowlist, aria2c validation, and Android-detection tests must stay hermetic (mock `shutil.which`, `java.android`, network).

## Pull Request Process

1. Ensure your branch is up to date with `main`.
2. Run the full test suite (`flutter analyze`, `flutter test`, `pytest engine/tests/ -v`).
3. Fill out the pull request template: motivation, description, verification steps.
4. Mark which platforms you tested on (Android / Windows / Linux).
5. A maintainer reviews your changes. Address feedback before merging.
6. Squash commits if requested by the reviewer.

## Changelog and release notes

A user-visible change gets a line in [`CHANGELOG.md`](CHANGELOG.md) when the
tag is cut, not in the same commit as the fix. The section says what changed
for someone installing the build, what they have to do about it, and what is
still broken. Commit hashes, task IDs and function names stay out of it.

[`release-notes.md`](release-notes.md) has the template and the rules. Read it
before writing a release section.

## Writing

Prose in this repository follows three skills, in this order:

1. [`write-in-my-style`](../.agents/skills/write-in-my-style/SKILL.md) sets the
   voice.
2. [`stop-slop`](../.agents/skills/stop-slop/SKILL.md) removes AI tells.
3. [`humanizer`](../.agents/skills/humanizer/SKILL.md) audits the result.

That covers README, `docs/`, `.agents/vault/`, commit bodies, pull request
descriptions and release notes. [`AGENTS.md`](../AGENTS.md) has the short rule
list and wins on conflicts.

## Architecture Rules

- **yt-dlp**: `YoutubeDL` class API only. Never `subprocess.run()` with yt-dlp binary.
- **Downloads**: Always in `threading.Thread` with a cancel event. Never block the main thread.
- **Events**: Android progress goes through `event_callback.onEvent(json)` with queue fallback. Streaming progress capped at 99%; terminal `finished` carries 100% + `filesize_bytes`.
- **State**: Riverpod `ConsumerWidget`/`Notifier`/`AsyncNotifier`. Never `setState()` for shared state.
- **Fonts**: Headings = bundled Bricolage Grotesque, body = bundled Figtree (never a runtime webfont fetch). InstrumentSans is legacy and only remains in older settings screens. Mono = `Theme.of(context).textTheme.mono` (IosevkaCharonMono). Never system fonts.
- **Colors**: Always from DESIGN.md tokens via `GrablyticColors`. Never hex literals.
- **Config**: Never hardcode paths. All binary paths go through `set_paths()`, which takes eleven arguments in this order: `data_dir`, `output_dir`, `ffmpeg_path`, `cache_dir`, `cookies_path`, `aria2c_path`, `deno_path`, `po_token`, `ffmpeg_ld_path`, `nodejs_path`, `log_level`. The Kotlin bridge passes them positionally, so a new argument goes at the end or every platform breaks at once.
- **Format options**: Never use both `merge_output_format` and `remux_video` simultaneously in yt-dlp options.
- **Subtitles**: Embed via `FFmpegEmbedSubtitle` PP, ordered EmbedSubtitle → ModifyChapters → Metadata. Never rely on the (non-existent) `embedsubs` param.
- **Sections**: Use `download_range_func` (FFmpeg-only). Invalid specs warn-and-skip.
- **aria2c**: Clamp chunks 1–16, validate speed regex, native downloader for DASH/HLS.
- **Layout structure**: Screens go in `lib/features/<feature>/screens/`. Providers go in `lib/providers/`. Theme and engine bridge go in `lib/core/`.

## How to Add a New Screen

1. **Create the screen file:** `lib/features/<feature>/screens/<name>_screen.dart`.
   - Extend `ConsumerWidget` or `ConsumerStatefulWidget` (if you need local state like text controllers).
   - Use the `SuperRef` pattern: accept `super.key` and pass it to super.
2. **Add a provider (if needed):** `lib/providers/<name>_provider.dart`.
   - Extend `StateNotifier<State>` or `AsyncNotifier<State>` for shared state.
   - Expose the provider as a global `final`.
3. **Wire navigation:**
   - Use `Navigator.of(context).push(MaterialPageRoute(...))` for simple navigation.
   - For bottom-nav screens, add the route in `lib/features/shell/screens/app_shell.dart`.
4. **Update the app entry point (rare):**
   - If the screen is a top-level route (onboarding, standalone), add it in `lib/main.dart`.
5. **Add semantic labels** for accessibility.
6. **Write a widget test** in `test/` covering the screen's basic rendering and interactions.

## How to Add a New Python Module

1. **Create the module:** `engine/grablytic_engine/<module>.py`.
   - Import from sibling modules where needed (e.g. `from grablytic_engine.paths import ...`).
   - Keep one responsibility per module.
2. **Add tests:** `engine/tests/test_<module>.py`.
   - Write pytest functions with plain `assert` statements.
   - Cover normal cases, edge cases, and error paths.
3. **Wire into the IPC dispatch** in `engine/grablytic_engine/__main__.py`:
   - Add an `elif method == "<namespace>/<action>"` branch that calls your function.
   - Return a JSON-serializable dict (include `"success": True/False` for error reporting).
4. **Update the public API** in `engine/grablytic_engine/__init__.py` if the function should be accessible from the package level.
5. **Run tests:** `pytest engine/tests/ -v` and verify all pass.
