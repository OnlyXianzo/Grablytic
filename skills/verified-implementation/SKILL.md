---
name: verified-implementation
description: >-
  Use for ANY non-trivial code change, bug fix, or feature — not only
  when research is explicitly requested. Trigger whenever about to write
  a fix from memory or one quick search instead of verified current
  practice. Especially for architecture bugs (concurrency, IPC,
  async/event pipelines, polling vs push, platform APIs like Android,
  Chaquopy, JNI, protocol design), things whose best-practice changes
  over time (SDKs, libraries, security), and anything flagged as
  important or not to be broken. Workflow: multi-source research (not
  one search), then cross-verification across sources, then blast-radius
  analysis of the codebase, then implementation, then a test-fix-retest
  loop until confident nothing broke, then report back. Use parallel
  subagents wherever supported. Skip only for trivial one-line or typo
  fixes, or when the user says to skip research and apply a known fix
  directly.
---

# Verified Implementation Workflow

## Why this skill exists

Left alone, an agent tends to: read the bug, remember something that sounds
right from training data, and patch it — without checking whether that's
still the current best practice, without checking who else in the codebase
depends on the thing being touched, and without testing hard enough to
notice it broke something else. The user then has to catch this by hand,
explain the same context again, and ask for another pass.

This skill forces four phases in strict order, with a hard gate between
each: **Research → Verify → Implement → Prove**. No phase may be skipped
to save time. If you (the orchestrating agent) find yourself about to write
implementation code before Phase 2 has produced a written findings report,
stop and go back.

## When to use multiple agents

Use subagents (Task tool / parallel agent dispatch) whenever the runtime
supports it, with no artificial cap on how many run in parallel — spin up
as many research and verification agents as the problem has independent
angles. If the environment has no subagent capability, run every phase
below sequentially yourself, in the same order, without skipping steps.

---

## Phase 0 — Scope the problem

Before dispatching anyone, write a one-paragraph problem statement:
what's broken or being built, which files/subsystems it touches (use the
repo's own map/docs if one exists — e.g. `docs/REPO_MAP.md`,
`docs/repo_map/*.md` — read these first if present, they're cheaper than
re-discovering the codebase), and what "done" looks like. This statement
is what you hand to every research subagent so they aren't guessing at
context.

If the problem statement can't be written confidently — e.g. genuinely
ambiguous requirements — ask the user one clarifying question before
proceeding. Otherwise proceed without asking.

## Phase 1 — Research (parallel subagents, mandatory)

Dispatch at least 3 research subagents in parallel (more for genuinely
broad problems), each with a distinct angle. Do not let a single agent
do a single web search and call it research — that is explicitly the
failure mode this skill exists to prevent.

Typical angle split:
- **Agent A — Official/primary sources.** Official docs, changelogs,
  RFCs, the actual library/platform source code if available locally
  or via package registry. For a platform API question (e.g. Android
  Chaquopy, JNI, coroutines), this means the actual current official
  docs, not a blog post about them.
- **Agent B — Real-world production practice.** How do maintained,
  popular open-source projects solve this same class of problem right
  now? Search GitHub for real implementations (not toy examples),
  read actual merged PRs/issues where people hit this exact problem
  class, check dates — deprioritize anything that reads as stale
  relative to the current date.
- **Agent C — Failure modes and tradeoffs.** What goes wrong with the
  naive/obvious fix? Search specifically for postmortems, GitHub
  issues, Stack Overflow answers with real engagement (not just top
  hit) describing why the obvious approach breaks in practice, and
  what the accepted fix actually is.

Each subagent must return a **written findings report**, not a verbal
summary, with:
- Every source consulted, with URL and rough date/recency
- The specific claim each source supports
- Explicit note of any disagreement between sources
- A confidence level (high/medium/low) per claim, based on how many
  independent sources agree and how authoritative they are

**Hard rule: no single-source conclusions.** If only one source supports
a claim and it materially affects the implementation, that subagent must
either find a second independent source or explicitly flag it as
unverified in the report, not silently treat it as settled.

## Phase 2 — Cross-verify and reconcile (gate before implementation)

The orchestrating agent (you) reads all subagent reports and produces a
single **Verified Approach** document:
- The approach to take, with every material decision traced back to
  which source(s) support it
- Explicitly list anything the subagents disagreed on and how it was
  resolved (prefer: most recent + most authoritative + most corroborated)
- Explicitly list anything still uncertain after research, and how the
  implementation will hedge against that uncertainty (e.g. feature flag,
  fallback path, extra logging)

**Do not proceed to Phase 3 until this document exists.** If you catch
yourself writing implementation code before this, stop.

Show this document to the user for non-trivial or high-blast-radius
changes before implementing, unless the user has told you to proceed
without checkpoints for this task.

## Phase 3 — Blast-radius analysis, then implement

Before touching code:
- Grep/search the codebase for every call site, every consumer, every
  place that depends on the current behavior of what you're about to
  change. Do not assume you know every caller — check.
- For each call site, note: does this change break it, does it need a
  matching update, or is it unaffected? Write this down before editing.
- If the repo has cross-layer boundaries (e.g. this project's
  Dart↔JSON-RPC↔Python, or Kotlin↔Chaquopy↔Python), check **both sides**
  of every boundary you're touching — a fix on one side that isn't
  mirrored on the other is exactly how contract-mismatch bugs happen.

Then implement, following the Verified Approach document from Phase 2.
Keep changes scoped to what the blast-radius analysis identified — don't
opportunistically refactor unrelated code in the same pass.

## Phase 4 — Test-fix-retest loop (repeat until actually confident)

This is not "run the tests once." Loop:

1. Run the full relevant test suite (not just tests for the changed
   file — anything the blast-radius analysis flagged as a consumer).
2. If anything fails, fix it, and **go back to step 1**. Do not
   selectively re-run only the previously-failing test — rerun the full
   relevant suite, since a fix can introduce a new break elsewhere.
3. If the change affects a code path without existing test coverage,
   write a test for it before considering the loop done — untested is
   not the same as unbroken.
4. Where feasible, exercise the actual runtime path end-to-end (not
   just unit tests) — e.g. actually drive the JSON-RPC protocol, or
   actually invoke the platform channel — the way a real user/caller
   would, since contract mismatches between layers often don't show up
   in unit tests scoped to one side.
5. Only exit the loop when: all relevant tests pass, the specific bug
   is confirmed fixed via direct reproduction, and you've explicitly
   re-checked every call site from the Phase 3 blast-radius list.

If after 3 full loop iterations something still fails, stop and report
to the user rather than continuing to patch blindly — this usually means
the Verified Approach itself needs revisiting, not another quick patch.

## Phase 5 — Report back

Return to the user (or to the main/parent agent, if this was dispatched
as a subagent task) with:
- What was actually wrong (root cause, not just symptom)
- What the research found, and which source(s) the final approach is
  grounded in
- What was changed, file by file
- What was tested, and how you confirmed the fix works end-to-end
- Anything flagged as uncertain or worth future revisiting

Keep this concise — a dense report the user will actually read beats an
exhaustive one they'll skim past.

---

## Anti-patterns this skill exists to prevent

- Writing a fix from memory/training data without checking if it's still
  current practice
- One search query treated as sufficient research
- Trusting a single blog post or Stack Overflow answer without
  corroboration
- Fixing one side of a cross-layer contract without checking the other
- Running tests once and declaring victory
- Re-implementing something differently on a retry because the agent
  "forgot" what was actually wanted — Phase 2's Verified Approach
  document exists specifically so there's a written record to check
  against instead of re-deriving intent from scratch each time
