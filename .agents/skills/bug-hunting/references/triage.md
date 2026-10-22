# Triage

## Is it a bug at all?

Three questions, in order. If any answer is "no", it is not a defect — it may still be a valid feature request or documentation problem, and saying so is useful.

1. **Does it deviate from documented behaviour?** Documentation, then tests, then comments, then convention. If the docs say "may return an empty list" and it returns `[]`, that is not a bug — the caller is.
2. **Does a real user hit it?** A code path only reachable from a test fixture matters far less than one a user walks into daily.
3. **Would the maintainer accept the fix?** If the fix breaks a supported use case, the finding is probably a design disagreement. File it as a design discussion, not a bug.

Categories that are not bugs, and should be named as such:

- **Design:** works as designed, the design is the problem.
- **Docs:** the code is right, the documentation is wrong. Fix the docs; it is a real defect, just not a code one.
- **Environment:** the user's machine, a stale build, an unsupported version. Reproduce before you disagree.
- **Expectation:** the user assumed behaviour nobody promised.

## Severity

| Level | Test | Examples |
|---|---|---|
| **Critical** | Data loss, corruption, security impact, or the product is unusable for everyone | Silent truncation on save; auth bypass |
| **High** | A main workflow is broken, or wrong results with no warning | Every export fails; totals off by one |
| **Medium** | A secondary workflow is broken, or the symptom needs an uncommon input | Crash on a malformed file; OOM on a huge feed |
| **Low** | Cosmetic, awkward workaround exists, or the impact is annoyance | Wrong label; a spurious log line |
| **Nit** | Not a bug | Naming, formatting |

Multiply by **reachability** (default install? authenticated? needs a local attacker?) and **frequency** (every run? one in a thousand?). A crash that needs three preconditions and a hand-edited config is not High because it crashed.

## Reproducibility labels

State one in the report. It tells the maintainer how much of your conclusion they can trust.

- **Always** — reproduced N/N runs, command included.
- **Intermittent** — reproduced X of N; say which runs, and whether anything differed.
- **Not reproduced, mechanism confirmed by reading code** — a downgrade, and it must be labelled as one.
- **Could not attempt** — name the missing dependency. Never label this "reproduced".

## Stop conditions

Say so and hand back rather than guessing, when:

- Repro needs a device, credential, service, or data you do not have.
- Two attempted hypotheses were falsified and the third would need production data.
- Fixing it requires a product decision (change the API, change the schema, accept the incompatibility).
- The "bug" is a security issue — hand it to the security process, do not fix it silently in a feature branch.

## Writing the severity line

> **Severity:** High — every export of more than 1 000 rows silently truncates at 1 000 (reproduced 5/5). No workaround; the user does not know data is missing.

That sentence contains the level, the reach, the frequency, and the impact. Compare with "High — data loss", which tells the maintainer nothing they can argue with.
