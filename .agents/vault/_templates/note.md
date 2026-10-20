---
title: Note Template
date: 2026-09-30
tags: [template, vault]
status: complete
---

# {{title}}

Use this template for every new vault note.

## Frontmatter rules (mandatory)

```yaml
---
title: <Note Title>
date: 2026-09-30
tags: [grablytic, <area>]
status: complete
---
```

- `date`: creation/last-substantive-update date (`YYYY-MM-DD`). Bulk creation date is `2026-09-30`.
- `status`: `complete` | `draft` | `needs-review`. New code-derived notes start as `draft`, graduate to `complete` after verification.
- `tags`: always include `grablytic` plus the area (`architecture`, `api`, `guides`, `inbox`).

## Link discipline (mandatory)

- Every module/component/file mention MUST be an Obsidian wiki-link, using the covering-note slug as target with the file as display text, e.g. `[[format-ladder|format_selector.py]]`.
- Every link target MUST exist in the [[index|link index]]. Never link a note you have not created.
- If no covering note exists: write the path in code font (no link) and add a row to [[open-questions|open-questions]] proposing the note.
- End every note with a `## Links` section listing the notes it connects to.

## Body structure

1. One-line scope statement + repo paths covered.
2. Facts only (file:line or commit hash where possible). No guessing — unclear items go to [[open-questions|open-questions]].
3. Tables for surfaces/schemas/contracts; sequences for flows.

## Links

- [[index|index]]
- [[open-questions|open-questions]]
- [[architecture-decision|architecture-decision template]]
