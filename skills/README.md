# Skills

Agent skills written for this project, published so other people can use or
adapt them. Each folder has a `SKILL.md` with frontmatter (`name`,
`description`) and the instructions an agent needs.

These are not framework plugins. They are Markdown procedures. Any agent that
can read a file and follow instructions can use them.

## What is here

| Skill | What it does |
|---|---|
| [`flaws-hunter-endlessly`](flaws-hunter-endlessly/SKILL.md) | Repeats an audit, research, fix, and prove cycle until a full rescan finds nothing. |
| [`secret-scan`](secret-scan/SKILL.md) | Audits the working tree and commit history for credentials. Includes a small Python scanner. |
| [`stop-slop`](stop-slop/SKILL.md) | Removes AI writing tells from prose. Vendored from [hardikpandya/stop-slop](https://github.com/hardikpandya/stop-slop), MIT. Required reading before any prose, per `AGENTS.md`. |
| [`studio-critic-loop`](studio-critic-loop/SKILL.md) | Renders a Flutter screen, sends only the screenshot to a fresh critic, fixes one thing per round until it scores 9/10. |
| [`teardown-myproject`](teardown-myproject/SKILL.md) | Adversarial review across architecture, debt, edge cases, security, and onboarding. |
| [`verified-implementation`](verified-implementation/SKILL.md) | Research, cross-check, map the blast radius, implement, then test and retest. |

One pack stays local and is not published:

- `doc-workflow` maintains the project knowledge vault. It lives in
  `.agents/skills/` and is not part of the published pack. The vault itself is
  tracked at `.agents/vault/`; the skill still does not commit or push on its
  own.

## Path placeholders

Skills that touch local files use two variables:

```bash
REPO_ROOT="${REPO_ROOT:-$HOME/grablytic}"
VAULT_ROOT="${VAULT_ROOT:-$REPO_ROOT/.agents/vault}"
```

The default vault path is `.agents/vault`, which is tracked in this repository.
Other `.agents/` contents stay local and ignored. Some people keep notes
elsewhere, including directly in `$REPO_ROOT`. If the path is wrong, the agent
should ask you where the repo or vault lives and continue with your answer. It
should not guess or write your personal path into a tracked file. Local answers
go in `.agents/local-paths.md`, which is ignored by git.

## Install

Copy a folder into the skills directory your agent reads. Common locations:

- `~/.agents/skills/` for a user-wide install.
- `<repo>/.agents/skills/` for a project-local install.
- The equivalent directory for your tool, if it uses a different name.

For example:

```bash
cp -r skills/verified-implementation ~/.agents/skills/
```

Read the target tool's documentation before copying. Some tools expect a
different frontmatter format or a plugin manifest.

## Writing your own

- Put the trigger in `description`. The body is only read after the skill is
  selected.
- Write commands that work when pasted. Avoid pseudo-commands.
- State what the skill must not do, not only what it should do.
- Use placeholders for paths that differ per machine.
- Keep it short enough to read in one sitting. Link to deeper docs instead of
  pasting them.

## License

Skills written here are part of Grablytic and use the same license as the
repository: GPL-3.0. See [`LICENSE`](../LICENSE).

One exception: [`stop-slop`](stop-slop/SKILL.md) is vendored from
[hardikpandya/stop-slop](https://github.com/hardikpandya/stop-slop) and keeps
its MIT license, included at [`stop-slop/LICENSE`](stop-slop/LICENSE).
