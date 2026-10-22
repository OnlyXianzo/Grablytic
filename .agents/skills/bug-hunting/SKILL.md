---
name: bug-hunting
description: >-
  Reproduce, localise, and fix software defects — crashes, wrong output, flaky tests, regressions, hangs, and "it works on my machine" failures. Use whenever the user reports a bug, pastes an error or stack trace, asks why something is failing or flaky, wants a regression bisected, wants a failing test written before a fix, or asks for a code review focused on correctness rather than style. Also use before claiming a fix works: a fix is a hypothesis until the original reproduction stops failing.
license: GPL-3.0
compatibility: Needs git and a POSIX shell. Works in any agent runtime that can read files and run commands; degrades to read-only analysis when it cannot execute code, with the evidence level stated.
metadata:
  version: "1.0"
  author: OnlyXianzo
  domain: software-correctness
---

# Bug hunting

A bug is not fixed when the code looks right. It is fixed when the original reproduction stops failing, a test that failed before now passes, and nothing else broke. Everything here serves that sentence.

The expensive failure in debugging is not being wrong — it is being wrong *confidently* and shipping it. So: reproduce before explaining, explain before editing, and verify with the thing that was broken, not with a proxy for it.

## Non-negotiables

1. **Reproduce first.** No fix without a failing case, unless reproduction is genuinely impossible — and then say so and write the closest thing you can (a unit-level call, a stripped-down harness, a recorded input). "Should be fixed" is not a status.
2. **Label `executed` vs `read`.** A stack trace you were shown is not a stack trace you produced.
3. **One hypothesis at a time.** State it, predict what you will see if it is true, then run the experiment. Changing three things and seeing the symptom vanish teaches nothing.
4. **Fix the cause, not the symptom.** Wrapping the call in `try/except` to stop the crash is a decision that needs the user's consent, not a default.
5. **Never edit the test to match the bug.** If the assertion encoded the intended behaviour, the code is wrong.
6. **Check for siblings.** One instance of a bug almost always means a pattern; grep the shape and list every other site.

## Workflow

```
Task progress:
- [ ] 0. Ground truth: ref, build, test command, environment
- [ ] 1. Reproduce: exact steps, expected vs actual
- [ ] 2. Minimise: smallest input, config, or commit
- [ ] 3. Localise: bisect commits, bisect inputs, instrument boundaries
- [ ] 4. Explain: falsifiable hypothesis naming the broken invariant
- [ ] 5. Red: a test that fails for the right reason
- [ ] 6. Fix: smallest change that restores the invariant
- [ ] 7. Green: new test + full suite + the original reproduction
- [ ] 8. Variant scan: other call sites with the same shape
- [ ] 9. Report what changed, what did not, and what is now unverified
```

### 0. Ground truth

Run `scripts/ground_truth.sh <repo>`; it prints the ref, dirty files, build manifests, and the test commands it detects. Then confirm the failure exists on **this** ref before assuming the report is accurate. The most common wasted hour is debugging a bug that was already fixed, or a stale build.

If the user is on a different version, say so and reproduce on theirs.

### 1. Reproduce

Copy the exact command, input, and environment. Record:

- **Expected:** what should happen.
- **Actual:** what happens, verbatim, including the exit code.
- **Frequency:** every time, or one in N? If it is intermittent, that changes everything downstream — write down how many runs you did before you saw it fail.

If reproduction needs a tool that is missing, say what is missing rather than substituting a weaker check and calling it a reproduction.

### 2. Minimise

Reduce the reproduction while it still fails. Fewer inputs, fewer lines, fewer flags. A minimal repro is not a chore — it usually *is* the diagnosis, because everything you cannot remove is everything that is not the cause.

Bisect in three dimensions, whichever applies:

- **Commits:** `git bisect run <command>` with an automated pass/fail.
- **Inputs:** halve the data, drop the fields, shorten the path.
- **Configuration:** default config, empty database, single thread.

### 3. Localise

You are looking for the first place where a value stops matching its contract. Instrument the boundaries, not the interior: print the argument on each side of a function call and find the pair that disagrees.

Useful questions, in order of payoff:

- Is this code even reached? (A surprising number of bugs are in the wrong branch entirely.)
- What is the type and units here? (`str` vs `bytes`, ms vs s, 0-based vs 1-based)
- What changes between the passing and failing case? Diff the two runs, not the two files.
- What did the last successful run have that this one does not? Config, state, ordering.
- Is the error the cause, or a downstream symptom? Read the trace bottom-up, then the message top-down.

### 4. Explain

Write the hypothesis as a sentence that can be false:

> "When the feed is chunked, `contentLengthLong` is `-1`, so the size check never fires and the read loop runs until the peer closes."

Then say what you will observe if it is true (a chunked response should hang, a length-delimited one should not) and run that. If the observation does not match, the hypothesis is wrong — do not adjust it until it fits, discard it.

Name the invariant that was violated. "The path must stay inside the download root" is an invariant; "the check is broken" is not.

### 5. Red

Write the test at the lowest level that still reproduces the bug, in the project's existing framework and file layout. Run it against the **unfixed** code and confirm it fails with the right message — not an import error, not a missing fixture. Quote that output; it is the only proof the test is load-bearing.

If the project has no test framework, a script with an assert and a comment is fine. A regression test that nobody runs is worse than none; wire it into the existing command.

### 6. Fix

Smallest change that restores the invariant. Match the surrounding code — its error handling, its naming, its logging. Do not refactor while fixing; a security or correctness fix that also reorganises the module cannot be reviewed.

State the trade-off if behaviour changes: "files in a folder the user has since switched away from no longer open from history" is the kind of consequence that must be in the description, not discovered by a user.

### 7. Green

Three things, not one:

1. The new test passes.
2. The full suite passes — paste the counts.
3. **The original reproduction passes**, run the way the user ran it. A unit test that passes while the reported symptom persists means you fixed a different bug.

If the suite cannot run here (no SDK, no device, no service), say which of the three you verified and which you did not. That sentence is the difference between a fix and a hope.

### 8. Variant scan

Grep for the shape, not the message. If a function mishandled `None`, every caller of that function may. If a guard canonicalised one path and not another, find the other. List every site, and either fix them in the same change or file them as follow-ups with locations.

### 9. Report

Use `references/report-template.md`. The report answers: what was broken, how you know, what you changed, what you verified, and what remains unverified.

## Triage

Severity is `impact × reachability × frequency`, and it is not the same as "how annoyed the reporter is". See `references/triage.md` for the matrix and for the three questions that decide whether something is a defect at all: is it a deviation from documented behaviour, does a user hit it, and does the fix have a cost the maintainer would accept.

## Ways this goes wrong

- **Shotgun debugging.** Three changes at once, symptom gone, cause unknown. The bug returns in a different costume.
- **Fixing the test.** The assertion was right; the code was wrong. Changing the assertion hides a real defect and poisons the suite.
- **Catching the exception.** Turning a crash into a silent no-op converts a visible failure into a data-integrity problem.
- **Trusting the passing suite.** A green suite means the tests you have pass. It is not evidence about the case the user reported.
- **Declaring victory from a code read.** "The logic now looks correct" is a hypothesis. Run it.
- **Debugging the description instead of the system.** Users describe symptoms in the vocabulary of their guess. Reproduce the observable thing.

## Self-check before you finish

- [ ] The original reproduction was run after the fix, not just the new test.
- [ ] The new test fails on the pre-fix code, for the right reason, and that output is quoted.
- [ ] The full suite result is stated with counts, or the reason it could not run.
- [ ] Sibling sites were searched and are listed.
- [ ] Nothing was "fixed" by weakening an assertion or swallowing an error.
- [ ] Behaviour changes a user can see are called out explicitly.
- [ ] Anything still unverified is named as unverified.
