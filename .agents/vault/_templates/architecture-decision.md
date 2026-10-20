---
title: Architecture Decision Template
date: 2026-09-30
tags: [template, vault, adr]
status: complete
---

# ADR: {{decision title}}

Use for architecture decision records (e.g. why the [[format-ladder|portrait ladder]] uses `width<=cap` instead of `height<=1920`).

## Frontmatter rules (mandatory)

```yaml
---
title: 'ADR: <decision>'
date: 2026-09-30
tags: [grablytic, adr, <area>]
status: complete
---
```

## Body

- **Status:** proposed | accepted | superseded (link superseding ADR).
- **Context:** what forced the decision (field report, constraint, failure).
- **Options considered:** min 2, with trade-offs. Cite sources (upstream issue, measured data).
- **Decision:** what was chosen + exact code location (e.g. `[[format-ladder|format_selector.py]]`, function).
- **Consequences:** what improves, what is deliberately NOT done and why.
- **Verification:** tests/commands that prove it (e.g. `pytest engine/tests/ -v`).

## Link discipline

- Same as [[note|note template]]: every module/component/file mention is a covering-note link (e.g. `[[format-ladder|format_selector.py]]`); every target must be in the [[index|link index]]; unknowns go to [[open-questions|open-questions]].

## Links

- [[index|index]]
- [[note|note template]]
- [[open-questions|open-questions]]
