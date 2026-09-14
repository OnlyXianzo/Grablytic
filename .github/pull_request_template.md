## Summary

What problem does this PR solve? Why does it matter now? What is the intended outcome?

```diff
// Optional: a key code or config snippet that illustrates the change.
```

---

## Documentation review

Before submitting, check which docs are relevant to your change and confirm you've read them.

- [ ] `docs/architecture.md` — high-level architecture and data flow
- [ ] `docs/building.md` — build instructions per platform
- [ ] `docs/contributing.md` — development workflow and standards

_If your change touches the download engine, IPC layer, or UI:_

- [ ] `docs/architecture.md` — Flutter ↔ Python IPC contract and engine architecture
- [ ] `DESIGN.md` — Grablytic design system tokens and guidelines

---

## Verification

- [ ] `dart analyze` passes with zero errors
- [ ] `flutter test` passes
- [ ] `pytest engine/tests/ -v` passes (if engine changed)
- [ ] Built and smoke-tested on affected platforms (Android / Linux / Windows)

What did you test, and on what platform?

---

## Checklist

- [ ] No hardcoded paths — all paths injected via `set_paths()`
- [ ] No hex color literals — all colors from DESIGN.md tokens
- [ ] No system fonts — body `GoogleFonts.instrumentSans()`, mono `Theme.of(context).textTheme.mono`
- [ ] No `setState()` for shared state — Riverpod only
- [ ] No `subprocess.run()` with yt-dlp — `YoutubeDL` class API only
- [ ] No new yt-dlp options that conflict with `merge_output_format` + `remux_video` together
- [ ] Changelog updated if user-facing behavior changed
