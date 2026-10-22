# Skills

Agent skills written for this project, published so other people can use or
adapt them. Each folder has a `SKILL.md` with frontmatter (`name`,
`description`) and the instructions an agent needs.

These are not framework plugins. They are Markdown procedures. Any agent that
can read a file and follow instructions can use them.

The folder sits at `.agents/skills/` because that is where an agent working in
this repository looks first. It is tracked, and the rest of `.agents/` is not.

## What is here

| Skill | What it does |
|---|---|
| [`flaws-hunter-endlessly`](flaws-hunter-endlessly/SKILL.md) | Repeats an audit, research, fix, and prove cycle until a full rescan comes back clean. |
| [`security-auditing`](security-auditing/SKILL.md) | Audits a codebase, diff, or fix claim for exploitable defects. Findings carry evidence, severity, a patch, and a regression test. |
| [`bug-hunting`](bug-hunting/SKILL.md) | Reproduces, localises, and fixes a defect, then proves it with the original reproduction. |
| [`secret-scan`](secret-scan/SKILL.md) | Audits the working tree and commit history for credentials. Includes a small Python scanner. |
| [`stop-slop`](stop-slop/SKILL.md) | Removes AI writing tells from prose. Vendored from [hardikpandya/stop-slop](https://github.com/hardikpandya/stop-slop), MIT. Required reading before any prose, per `AGENTS.md`. |
| [`humanizer`](humanizer/SKILL.md) | Rewrites AI-sounding text without changing what it says. Vendored from [blader/humanizer](https://github.com/blader/humanizer), MIT. |
| [`write-in-my-style`](write-in-my-style/SKILL.md) | Matches this project's own voice, learned from its README, docs, changelog, and commit bodies. Local to Grablytic. |
| [`human-writing`](human-writing/SKILL.md) | Voice rules plus per-genre structure for READMEs, docs, changelogs, blog posts, and narration. The general case that `reddit-speak` specialises. |
| [`reddit-speak`](reddit-speak/SKILL.md) | How to write for Reddit so the post reads as a person, not a brand. Loads on the word "Reddit". |
| [`studio-critic-loop`](studio-critic-loop/SKILL.md) | Renders a Flutter screen, sends only the screenshot to a fresh critic, fixes one thing per round until it scores 9/10. |
| [`teardown-myproject`](teardown-myproject/SKILL.md) | Adversarial review across architecture, debt, edge cases, security, and onboarding. |
| [`verified-implementation`](verified-implementation/SKILL.md) | Research, cross-check, map the blast radius, implement, then test and retest. |

Two of these overlap on purpose and should not be merged. `teardown-myproject`
and `flaws-hunter-endlessly` are a diagnosis pass and a repair loop.
`security-auditing` is a third pass again: it asks whether something is
exploitable, which is a different question from whether it is broken. A combined
report buries one real vulnerability under twenty style notes, so run them
separately.

`human-writing` overlaps the three prose skills below on purpose too. It is the
genre layer, and they are the voice layer. Load it when the question is what a
README, a docs page, or a release note should contain and in what order. When
`write-in-my-style` has an opinion about how a sentence sounds, that opinion
wins, because it is learned from this repository. `human-writing` still supplies
the structure and the genre conventions.

## The prose pipeline

Three of these run in a fixed order on any prose in this repository. `AGENTS.md`
requires it for README, `docs/`, `.agents/vault/`, commit bodies, pull request
descriptions, release notes, and answers to the maintainer.

| Order | Skill | Input it needs | What you look for afterwards |
|---|---|---|---|
| 1 | `write-in-my-style` | a voice sample (README, changelog, a few past commit bodies) | The draft sounds like this repo, not like a press release |
| 2 | `stop-slop` | the draft, nothing else | No banned words, no rule-of-three padding, no "not just X but Y" |
| 3 | `humanizer` | the draft **and** the same voice sample | Sentence lengths vary, the opening is not a warm-up, the ending is concrete |

Order matters. Style first, because rewriting for voice changes the sentences
that `stop-slop` would flag. Humanizer last, because it is the audit pass and it
will undo a rewrite if you run it earlier and then edit again.

`reddit-speak` overrides all three for Reddit content. It is narrower and it
knows more about that audience than a general voice guide can.

`human-writing` sits before the pipeline, not inside it. Load it to decide the
shape of the piece: which genre, which sections, in what order. Then run the
three passes above on the prose that fills it.

### Running it by hand

1. Open the skill file and paste it into the agent along with your draft. One
   skill at a time, not all three at once.

   ```
   Read .agents/skills/write-in-my-style/SKILL.md and rewrite this section so it
   matches the voice described there. Keep every fact. Here is the draft:
   <paste>
   ```

2. Run the result through `stop-slop`. Ask for the specific list of tells it
   removed, so you can see whether it found anything real.

   ```
   Read .agents/skills/stop-slop/SKILL.md. Apply it to this text and list what you
   removed and why. Do not add new claims.
   ```

3. Run `humanizer` last, with two or three paragraphs of the project's own
   prose as the voice reference.

   ```
   Read .agents/skills/humanizer/SKILL.md. Audit this text against the voice sample
   below and rewrite what still reads as generated. Voice sample:
   <docs/features.md, first 30 lines>
   ```

4. Diff the result against your draft. If a fact moved, a number changed, or a
   sentence got vaguer, the pass failed. Rewrite by hand from the draft.

### Doing it on a whole doc set

Do not run the pipeline over a directory in one shot. It degrades into
"improve this" and rewrites things nobody asked about.

- One section at a time, then `git diff` before moving on.
- Facts are checked against the code, not against the previous wording. The
  pipeline will happily make a stale claim read better.
- Leave frozen records alone. `docs/audits/` and `docs/security-scans.md` are
  history; editing them for style is rewriting the record.

### When the skills disagree

`AGENTS.md` wins. It is the short list the three skills are meant to implement,
and it is the one a reviewer reads.

## Path placeholders

Skills that touch local files use two variables:

```bash
REPO_ROOT="${REPO_ROOT:-$HOME/grablytic}"
VAULT_ROOT="${VAULT_ROOT:-$REPO_ROOT/.agents/vault}"
```

Both defaults point at paths that are tracked in this repository. Anything else
you keep under `.agents/` stays local and ignored. Some people keep notes
elsewhere, including directly in `$REPO_ROOT`. If the path is wrong, the agent
should ask you where the repo or vault lives and continue with your answer. It
should not guess or write your personal path into a tracked file. Local answers
go in `.agents/local-paths.md`, which is ignored by git.

## Install

Copy a folder into the skills directory your agent reads. Common locations:

- `~/.agents/skills/` for a user-wide install.
- `<repo>/.agents/skills/` for a project-local install, which is where these
  live in this repository.
- The equivalent directory for your tool, if it uses a different name.

For example:

```bash
cp -r .agents/skills/verified-implementation ~/.agents/skills/
```

Read the target tool's documentation before copying. Some tools expect a
different frontmatter format or a plugin manifest.

## Writing your own

- Put the trigger in `description`. The body is only read after the skill is
  selected.
- Write commands that work when pasted. Avoid pseudo-commands.
- State what the skill must not do, not only what it should do.
- Use placeholders for paths that differ per machine.
- Keep the body short enough to read in one sitting. Put the long material in
  `references/` and point at it, so it loads only when the workflow reaches it.
- Say what the skill cannot verify. Every procedure has a blind spot, and the
  agent will fill a silent one with confidence.

## License

Skills written here are part of Grablytic and use the same license as the
repository: GPL-3.0. See [`LICENSE`](../../LICENSE).

Two exceptions are vendored and keep their own MIT license, included beside
each skill:

- [`stop-slop`](stop-slop/SKILL.md) from
  [hardikpandya/stop-slop](https://github.com/hardikpandya/stop-slop), license
  at [`stop-slop/LICENSE`](stop-slop/LICENSE).
- [`humanizer`](humanizer/SKILL.md) from
  [blader/humanizer](https://github.com/blader/humanizer), license at
  [`humanizer/LICENSE`](humanizer/LICENSE).
