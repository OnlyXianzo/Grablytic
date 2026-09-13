#!/usr/bin/env python3
"""Fail-closed check for relative links in Markdown docs.

Usage: python3 tool/check_doc_links.py  (run from repo root)

Every relative `](...)` target in README.md and docs/**/*.md must resolve
to a file on disk. External URLs, anchors, and template placeholders are
ignored. KNOWN_MISSING lists acknowledged gaps with a reason instead of
silently passing (e.g. LICENSE, which needs a legal decision first).
Exit 0 when clean, 1 with the offender list otherwise (CI gate).
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Link target -> reason. Deliberate gaps only; shrink this, never grow it.
KNOWN_MISSING = {}

LINK_RE = re.compile(r"\]\(([^)#]+)(#[^)]*)?\)")


def main() -> int:
    offenders = []
    acknowledged = []
    md_files = ["README.md"]
    docs = os.path.join(ROOT, "docs")
    for dirpath, _, files in os.walk(docs):
        for fn in sorted(files):
            if fn.endswith(".md"):
                md_files.append(os.path.relpath(os.path.join(dirpath, fn), ROOT))

    for rel in md_files:
        src = open(os.path.join(ROOT, rel), encoding="utf-8").read()
        for match in LINK_RE.finditer(src):
            link = match.group(1).strip()
            if not link or link.startswith(("http://", "https://",
                                            "mailto:", "#")):
                continue
            if "{" in link or "<" in link:
                continue  # template placeholder, not a path
            target = os.path.normpath(
                os.path.join(os.path.dirname(rel) or ".", link))
            if os.path.exists(os.path.join(ROOT, target)):
                continue
            if link in KNOWN_MISSING or target in KNOWN_MISSING:
                acknowledged.append(f"{rel}: {link} "
                                    f"({KNOWN_MISSING.get(link, KNOWN_MISSING.get(target))})")
            else:
                offenders.append(f"{rel}: {link}")

    for line in acknowledged:
        print(f"ACKNOWLEDGED: {line}")
    if offenders:
        print("BROKEN LINKS:")
        for line in offenders:
            print(f"  {line}")
        return 1
    print(f"OK: {len(md_files)} files checked.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
