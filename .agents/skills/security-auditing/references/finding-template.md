# Finding template

Every finding carries all eleven fields, in this order. A reviewer who can fill the gaps in your finding for you is doing your job.

```markdown
### SEC-00N — Short title in a sentence, no jargon

**Finding ID:** SEC-00N
**Title:** What the attacker does, in one line.
**Severity:** CRITICAL/BLOCKER | HIGH | MEDIUM | LOW | NITPICK
**Confidence:** Confirmed from execution / Confirmed from code / Strongly indicated / Requires verification / Hypothesis — plus one sentence on *why* that label.
**Location:**
- path/to/file.ext:LINE-LINE — the smallest snippet that shows the defect (quote it)
- every other affected location, one line each

**Technical Evidence:**
The mechanism. What the code does, what the input is, what the result is.
Quote real output when it was executed:

    $ <command>
    <output>

If it was read rather than executed, say so here.

**Threat Model:**
- Attacker: who they are, what they must already have
- Entry point: how the input arrives
- Trust boundary: what is crossed
- Asset: what they get

**Standards Mapping:** OWASP Top 10:2021 A0X · OWASP API Top 10 · CWE-XXX · ASVS 5.x.x · language or platform rule

**Impact:** Confidentiality / Integrity / Availability, each with the realistic ceiling. Say "none" where none.

**Remediation (production code):** The complete patch, in the target language.
State the trade-off if the fix changes behaviour a user can see.

**Regression Test:** A test that fails before the patch and passes after, with the
assertion that makes it specific. Name the file it belongs in.

**Verification Steps:** Commands a reviewer runs to reproduce your conclusion.
```

## Rules that keep findings honest

**Severity follows the path, not the category.** A `eval()` on a constant string is not RCE. State the path or drop the severity.

**One root cause, one finding.** If three call sites miss the same check, that is one finding with three locations. The fix is one abstraction, not three patches.

**The remediation must not delete the feature.** Before proposing it, list the legitimate inputs the new guard rejects. If the list is non-empty, the patch is wrong.

**Quote, don't paraphrase.** If you are calling a line vulnerable, reproduce the line exactly with its number.

**The regression test must fail for the right reason.** Run it against the pre-fix code. A test that passes both before and after proves nothing, and a test that fails on a missing import is noise.

**Say what the fix does not close.** Partial mitigations are fine when labelled. "The redirect hop is still followed" is a sentence a maintainer needs; omitting it is how a second CVE gets filed against the fix.

## Worked example (compressed)

> ### SEC-004 — The file-sharing check trusts a path string
> **Severity:** Low **Confidence:** Confirmed from execution
> **Location:** `android/.../MainActivity.kt:742` — `FileProvider.getUriForFile(this, "$packageName.fileprovider", file)`
> **Technical Evidence:** The provider is rooted at external storage because the download folder is a runtime choice, so any path under shared storage is mintable. Executed against the shipped policy (`DownloadPathGuard` ported 1:1 to Java, JDK 11): `/root/dl-evil/x.mp3` is refused, but `root=""`, `root="."`, and a NUL-bearing path were all accepted before the canonicalisation change.
> **Remediation:** Canonicalise both sides and compare with a trailing separator, failing closed on an unresolvable root.
> **Regression Test:** `a_sibling_folder_sharing_the_name_prefix_is_refused` — fails against the pre-fix string compare.
> **What it does not close:** A symlink swapped between the check and `getUriForFile` is resolved by the provider's own canonicalisation; narrow window, listed as residual risk.
