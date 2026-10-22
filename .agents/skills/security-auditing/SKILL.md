---
name: security-auditing
description: Audit a codebase, PR, diff, or dependency set for exploitable security defects and write findings a maintainer can act on. Use whenever the user asks for a security review, vulnerability assessment, penetration test, threat model, OWASP/ASVS/CWE mapping, "is this safe", "audit this", "check for injection/SSRF/IDOR/secrets", or asks whether a security fix actually closed the issue — even if they never use the word "audit". Also use when verifying someone else's security PR, since a merged fix is a claim until re-derived at the ref.
license: GPL-3.0
compatibility: Needs git and a POSIX shell; scripts are Python 3.9+ stdlib only. No network access required. Works in any agent runtime that can read files and run commands.
metadata:
  version: "1.0"
  author: OnlyXianzo
  domain: application-security
---

# Security auditing

The deliverable is not a list of suspicious lines. It is a set of **findings that survive a hostile reviewer**: each one names a real trust boundary, shows the mechanism, and tells the maintainer exactly what to change. Most of this job is refusing to believe things — including your own earlier findings, and including the PR title that says the issue is fixed.

Two failure modes dominate real audits, and both are self-inflicted: reporting a pattern instead of a mechanism (inflates severity, destroys trust), and asserting behaviour you never observed (a framework rule you did not read, a test you did not run). Everything below exists to prevent those two.

## Non-negotiables

1. **Pin the ref.** Audit `git rev-parse HEAD`, not "the code". Write the SHA into the report. If the tree is dirty, say so or stash it — a finding against uncommitted work is not reproducible.
2. **Label every claim `executed` or `read`.** Executed means a command ran in this session and the output is quoted. Read means you saw the bytes. Never let a read become an execution in the retelling.
3. **No manufactured findings.** A category with nothing in it gets "no evidence within supplied scope", never "this is secure".
4. **Severity is earned**, by privileges required, reachability, surface, and impact. A rule violation with no reachable path is a nitpick, and saying so is the job.
5. **Consolidate by root cause.** Six instances of one missing check is one finding with six locations, not six findings.
6. **Never claim a scan, fuzzer, or exploit ran unless it did.** If the toolchain is absent, say the property was verified by porting the policy, and say what that does and does not prove.

## Workflow

Copy the checklist and tick as you go. Skipping step 0 is how reports end up describing a different codebase.

```
Task progress:
- [ ] 0. Ground truth: ref, scope, toolchain, prior findings
- [ ] 1. Surface map: entry points, sinks, trust boundaries
- [ ] 2. Read every file in scope (no sampling, no omissions)
- [ ] 3. Prove or refute each hypothesis (execution ladder)
- [ ] 4. Adjudicate: severity, confidence, root-cause merge
- [ ] 5. Write findings in the fixed template
- [ ] 6. Verify any fix at its merged ref (red → green)
- [ ] 7. Assemble the report, score, and roadmap
```

### 0. Ground truth

```bash
git rev-parse --short HEAD; git status --porcelain | head; git log -1 --format='%s'
python3 --version; node --version; go version; java -version; rustc --version
```

Record which toolchain exists, because it decides what you can execute. A missing compiler does not stop the audit; it changes the evidence you are allowed to claim.

Ask for, or infer and state: what the system is, where it runs, who can reach it, what data it holds, and what the deployment looks like (server, on-device, library). A finding's severity is meaningless without that. If the user left it blank, infer it from the build files and say what you inferred.

Carry forward prior findings explicitly. Re-test them; do not re-report them as new.

### 1. Surface map

Enumerate **entry points** (routes, IPC channels, deep links, broadcast receivers, file parsers, CLI args, env, queues) and **sinks** (queries, shells, filesystem, deserialisation, HTTP clients, templates, crypto, logging). A vuln is a path between them.

`scripts/surface_scan.py <repo>` prints a categorised inventory of high-signal sink lines. It is a *starting index*, not a finding list — every line it prints still needs a data-flow read. Run it, then read the code it points at.

Bound the work: list what you are *not* covering (vendored code, generated code, third-party assets) and name it as a blind spot rather than silently skipping it.

### 2. Read

Read the whole file when you touch it. Security bugs live in the branch nobody checked — the `except`, the `finally`, the retry path, the cleanup handler. The audit that missed the redirect hop missed it because the guard was read and the *client* was not.

### 3. Prove or refute

Use the cheapest evidence that actually settles the question. The ladder, best first:

1. **Execute the code.** Write a harness, call the real function, print the real output.
2. **Port the policy, not the platform.** When the target language cannot run here, transliterate the *decision logic* statement-for-statement into a language that can, and run the hostile inputs through it. Say plainly: this proves the algorithm, not the compilation.
3. **Read the source and quote it**, with file:line.
4. **Cite upstream semantics** — and only after reading them. A framework claim is a hypothesis until you have the source or a reproduced error.

See `references/evidence-recipes.md` for the harnesses that settle the recurring questions: redirect following, timeouts vs slow drips, path containment, archive extraction, regex backtracking, deserialisation, and the red→green test.

### 4. Adjudicate

For each candidate, answer in order. The first "no" stops it:

- **Reachable?** From what entry point, by whom? No path → not a finding.
- **Boundary crossed?** Name the trust boundary and the asset.
- **Impact if successful?** Confidentiality / integrity / availability, and how bad.
- **Does an existing control stop it?** Read the control; do not assume it works because it exists.
- **Is this the same root cause as something already filed?** Then merge.
- **Would the maintainer's fix break a legitimate use?** If yes, your remediation is wrong, not the code.

Assign severity from `references/surface-checklist.md`. Never from the CWE name.

### 5. Write

Every finding uses the template in `references/finding-template.md`, with all eleven fields. A finding without a **Regression Test** and **Verification Steps** is an opinion, and reviewers are right to ignore it.

The remediation must be production code: complete, compiling, in the target language, using only APIs that exist. Pseudocode is acceptable only when clearly marked and immediately followed by the real patch.

Write the smallest safe patch first. If a refactor is genuinely required, say why the small patch is insufficient — do not smuggle a rewrite into a security fix.

### 6. Verify the fix

When the user reports a fix, or a PR claims one:

- Fetch and check out the **merged** commit, not the PR head. Then check the PR head separately if it differs.
- **Re-derive the original bug** at the parent commit, then at the fix. That is `red → green`, and it is the only evidence the fix addresses the finding.
- Read the diff for what it **does not close**, and for what it **regressed**. Fixes that tighten a guard break features more often than they break attacks.
- A green CI badge is not evidence unless you ran the gate. If you cannot run it, say that the result is the user's evidence, not yours.

### 7. Report

Fixed structure:

1. Executive summary — what the system is, what you did, the one-line verdict, counts by severity.
2. Findings by severity — CRITICAL/BLOCKER · HIGH · MEDIUM · LOW/NITPICK.
3. Corrected code — the patches.
4. Testing strategy — what to add, including the regression tests from the findings.
5. Tooling recommendations — matched to the actual stack, not a generic list.
6. Architecture and security health score, 1–10, with separate security / reliability / maintainability / testability scores and justification.
7. Prioritised roadmap — immediate containment, short, medium, long-term preventive.
8. Residual risks — including the ones you chose not to fix, and why.

## Severity rubric

| Level | Test |
|---|---|
| CRITICAL / BLOCKER | Unauthenticated remote code execution, or mass data exposure, reachable in a default install. |
| HIGH | Authenticated RCE or privilege escalation; auth bypass; a secret that grants broad access; mass data exposure under a realistic precondition. |
| MEDIUM | Real confidentiality or integrity impact with a precondition (local access, a hostile peer, a user action); or a control that is present but incomplete in a way an attacker can routinely walk past. |
| LOW | Defence-in-depth gap, hardening, incomplete error handling, a misleading comment where the code is sound. |
| NITPICK | Style, naming, documentation. Not a vulnerability — say so. |

Score CVSS only when you have the vector components; an unanchored "7.5" is worse than no score.

## Confidence ladder

| Label | Meaning |
|---|---|
| Confirmed from execution | A command ran and the output is quoted. |
| Confirmed from code | The bytes are visible and the mechanism follows from them alone. |
| Strongly indicated | The mechanism is clear but a runtime fact is assumed. Name the assumption. |
| Requires verification | Plausible path; the deciding fact is unavailable here. Say what would settle it. |
| Hypothesis | Worth recording, not worth a severity. |

## Ways this goes wrong

These are observed, not theoretical. Each one cost a real finding or a real regression.

- **Claiming framework behaviour from memory.** Reading is cheap; a retracted finding is expensive. When you cannot read the source, label it "Requires verification" and design a test that would falsify it.
- **Designing a verification step that cannot pass.** If your proof command is `adb shell am broadcast <protected action>`, it fails for reasons unrelated to the finding. Predict the outcome before you rely on it.
- **Guarding the entry point and not the client.** A URL validated before `connect()` is a lock on a door with the window open if the client follows redirects. Whatever consumes the validated value owns the property.
- **Replacing a parser with a regex.** Regex URL/host validation is how `allowed.host.evil.com` and `EVIL.HOST` get through. Parse, then compare components exactly.
- **Tightening a control until the feature disappears.** Check what legitimate inputs the guard now rejects; a fix that deletes a supported path is a regression with a security label on it.
- **Finding-count targets.** More findings is not a better audit. Five real findings beat fifty pattern matches, and the number is an output, not a goal.

## Output rules

- Redact secrets, tokens, cookies, and personal identifiers in the report. Show the shape, not the value.
- Quote exact lines with file:line; never paraphrase a snippet you are calling vulnerable.
- Do not write "the application is secure". Write what you checked, what you executed, and what you did not.
- Name your blind spots in the report: unreadable binaries, missing SDKs, services you could not reach.

## Self-check before you finish

- [ ] Every finding has all eleven fields, a real regression test, and runnable verification steps.
- [ ] Every claim is labelled executed or read.
- [ ] Severity is justified by a path, not by a category.
- [ ] Duplicates are merged by root cause, with every location listed.
- [ ] The clean categories say "no evidence within scope", not "secure".
- [ ] The patch is minimal, complete, and does not silently delete a feature.
- [ ] Blind spots and residual risks are written down.
