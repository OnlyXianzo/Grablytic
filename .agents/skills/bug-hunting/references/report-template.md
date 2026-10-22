# Report template

Two artefacts. The **bug report** goes to whoever triages; the **change description** goes with the fix. Keep them separate — a triager does not want your patch, and a reviewer does not want the archaeology.

## Bug report

```markdown
## Summary
One sentence: what breaks, for whom, under what condition.

## Reproduction
    $ <exact command>
    <exact output, exit code>

1. <step>
2. <step>

**Expected:** …
**Actual:** …
**Frequency:** N/N runs · environment: <os, version, commit>

## Minimal case
The smallest input or snippet that still fails, and what you removed to get there.

## Cause
The invariant that is violated, and where. `path/file.ext:LINE`.
If unconfirmed: "Mechanism confirmed by reading, not by execution."

## Impact
Who hits this, how often, and what it costs them. Data loss? Wrong results? A crash?

## Severity
Level — reach, frequency, impact, and the workaround if any.

## Proposed fix
One paragraph plus the diff. Say what it does not fix.

## Not covered
What you could not test, and what would be needed to test it.
```

## Change description (PR / commit body)

```markdown
<type>(<scope>): <what changed, imperative, ≤ 72 chars>

Why: the failure mode, in two sentences. Link the report.

What changed:
- file: the specific change, and the alternatives rejected

Evidence:
- `$ <test command>` → 14 passed (new: 3)
- Pre-fix, the same test fails: `<quoted failure>`
- Original reproduction re-run: `<quoted output>`

Behaviour change:
- <what a user will notice, or "none">

Not addressed:
- <sibling sites, deferred items, with file:line>
```

## Rules

**Quote, do not summarise, the failure.** `KeyError: 'status'` is evidence; "it throws an error" is not.

**One bug per report.** Two defects in one report means one of them gets ignored.

**Say what you removed** when minimising. "I dropped the auth header and the bug persisted" is a fact the maintainer needs.

**Never write "fixed" without the output.** The verification section is the whole value of the report.

**Name the unverified part.** Every report has one. Omitting it converts your uncertainty into the maintainer's surprise.
