# Release notes

How to write the section that ships with a tag. The record lives in
[`CHANGELOG.md`](CHANGELOG.md); this page explains what goes in it and why.

## Who reads it

Two people. Someone deciding whether to install this build, and someone who
already hit the bug and wants to know it is gone. Neither of them can read a
diff, and neither cares which function changed.

Write the section for them. If a detail only matters to a contributor, put it
under `### For contributors` at the end, or leave it in the commit message.

## Where the number comes from

`pubspec.yaml` is the only place the version is written. `build.yml` reads it,
derives the tag (`v` plus the part before `+`), stamps the full value into the
app as `GRABLYTIC_APP_VERSION`, and names the assets after it. Nothing else
should hardcode it; `tool/check_version_literals.py` enforces that for `lib/`.

## Shape of a section

```markdown
## v0.0.7 — 2026-11-02

One or two sentences. What is this release about, phrased for a person who
will read only this paragraph.

### Fixed
- The symptom, then what happens now. Past tense. One sentence.
- A second bullet if the first one would need a semicolon to hold both halves.

### Changed
- Behaviour that is different on purpose, including anything a user relied on.

### Added
- Only things they can point at in the UI or the file system.

### Upgrade notes
- What they have to do: reinstall, rename a folder, re-enable a setting.

### Known issues
- What is still broken, and the issue link.

### For contributors
- Gates, tooling, or migration notes that only matter inside the repo.
```

Drop any heading with nothing under it. A short release is a good sign, not a
gap to pad.

## Rules that matter

1. **Lead with the symptom, not the mechanism.** "Downloads in a subfolder
   never brought back the interrupted-downloads card" beats "fixed the
   recursion depth in the evidence probe".
2. **One claim per bullet.** If a bullet needs two "and"s, it is two bullets.
3. **Name the number, date, or limit.** "Three-report cap" is checkable.
   "Improved reliability" is not.
4. **Say what did not change.** After a release that looks large, one line
   about the parts that are untouched saves the reader a support thread.
5. **Upgrade notes are not optional when they apply.** A changed data path, a
   new permission, a reset setting: each one gets a line.
6. **Known issues stay honest.** An empty section means you looked, not that
   you hoped.
7. **No commit hashes, task IDs, file paths, or agent names in the user-facing
   part.** The automated commit appendix is fine at the very bottom, collapsed.
8. **Never describe a fix you have not seen pass.** Run the suites, read the
   CI result, or leave it out.

## Words that cost you credibility

- "various fixes and improvements"
- "performance improvements" with no number
- "now more robust", "seamless", "streamlined"
- "should now work" when you know it does, or when you do not

Say what you measured or drop the sentence. The writing rules in
[`AGENTS.md`](../AGENTS.md) and [`.agents/skills/stop-slop`](../.agents/skills/stop-slop/SKILL.md)
apply here like everywhere else.

## Before you tag

```bash
grep '^version:' pubspec.yaml          # the number the tag will use
pytest engine/tests/ -q                # engine suite
flutter analyze && flutter test        # app suite and analyzer
python3 tool/check_doc_links.py        # docs still resolve
python3 tool/check_version_literals.py # no version literal crept back in
```

Then dispatch **Build and Release** from `main`. It runs the verify gate
first, builds every platform, and creates the release. Run **Publish Release
Assets** afterwards to attach `SHA256SUMS` and the cosign bundles.

## Housekeeping in `CHANGELOG.md`

- Newest section first, plain `##` heading: `v0.0.7 — 2026-11-02`.
- Older sections are frozen. Fix a typo if it embarrasses you, do not rewrite
  history to look tidier.
- `tool/generate_release_changelog.py` can generate the commit appendix from a
  tag range. Keep that appendix at the bottom of the section, not at the top.
