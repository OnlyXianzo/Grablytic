#!/usr/bin/env python3
"""Fail-closed check for relative links and anchors in Markdown docs.

Usage: python3 tool/check_doc_links.py  (run from repo root)

Every relative `](...)` target in README.md and docs/**/*.md must resolve to a
file on disk, and every `#fragment` must match a heading in the target file.
That second half matters because a renamed heading leaves a link that still
"works" as a path and silently jumps nowhere.

External URLs and template placeholders are ignored. KNOWN_MISSING lists
acknowledged gaps with a reason instead of silently passing. Exit 0 when
clean, 1 with the offender list otherwise (CI gate).
"""

import os
import re
import sys
import unicodedata

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Link target -> reason. Deliberate gaps only; shrink this, never grow it.
KNOWN_MISSING = {}
# Anchors that point at generated or external content by design.
KNOWN_ANCHORS = set()

LINK_RE = re.compile(r"\]\(([^)\s]*?)(#[^)]*)?\)")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.+?)\s*#*\s*$")
FENCE_RE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
INLINE_CODE_RE = re.compile(r"(`+)(.+?)\1")


def slugify(text: str) -> str:
    """Approximate GitHub's heading anchor.

    Lowercase, drop inline markup, keep letters/digits/spaces/hyphens/underscore,
    then turn spaces into hyphens. Good enough for our own headings, which are
    plain prose plus the odd backtick.
    """
    text = re.sub(r"`([^`]*)`", r"\1", text)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = text.strip().lower()
    out = []
    for ch in text:
        if ch.isalnum() or ch in " -_":
            out.append(ch)
        elif unicodedata.category(ch).startswith("N"):
            out.append(ch)
    return "".join(out).replace(" ", "-")


def prose_lines(src: str):
    """Yield the lines that are actually rendered, skipping fenced code.

    A fence closes only on the same character, at least as long as the opener,
    with nothing but whitespace after it. Anything else stays inside the block,
    which is what CommonMark does and what keeps a nested ``` in an example
    from ending the block early.
    """
    fence = None
    for line in src.splitlines():
        match = FENCE_RE.match(line)
        if fence is None:
            if match:
                fence = (match.group(1)[0], len(match.group(1)))
                continue
            yield line
            continue
        if match:
            char, length = fence
            if (match.group(1)[0] == char and len(match.group(1)) >= length
                    and not match.group(2).strip()):
                fence = None
        # Fence lines and everything between them are not rendered prose.


def without_inline_code(line: str) -> str:
    """Blank out `code spans` so a link-shaped example inside one is ignored."""
    return INLINE_CODE_RE.sub(lambda m: " " * len(m.group(0)), line)


def readable_text(src: str) -> str:
    return "\n".join(without_inline_code(line) for line in prose_lines(src))


def anchors_of(path: str) -> set:
    try:
        src = open(path, encoding="utf-8").read()
    except OSError:
        return set()
    slugs, seen = set(), {}
    for line in prose_lines(src):
        match = HEADING_RE.match(line)
        if not match:
            continue
        base = slugify(match.group(2))
        # GitHub de-duplicates repeated headings: foo, foo-1, foo-2.
        if base in seen:
            seen[base] += 1
            slugs.add(f"{base}-{seen[base]}")
        else:
            seen[base] = 0
            slugs.add(base)
    return slugs


def main() -> int:
    offenders = []
    acknowledged = []
    md_files = ["README.md"]
    docs = os.path.join(ROOT, "docs")
    for dirpath, _, files in os.walk(docs):
        for fn in sorted(files):
            if fn.endswith(".md"):
                md_files.append(os.path.relpath(os.path.join(dirpath, fn), ROOT))

    anchor_cache = {}

    def anchors(rel: str) -> set:
        if rel not in anchor_cache:
            anchor_cache[rel] = anchors_of(os.path.join(ROOT, rel))
        return anchor_cache[rel]

    for rel in md_files:
        src = readable_text(open(os.path.join(ROOT, rel), encoding="utf-8").read())
        for match in LINK_RE.finditer(src):
            link = (match.group(1) or "").strip()
            fragment = (match.group(2) or "")[1:]
            if link.startswith(("http://", "https://", "mailto:")):
                continue
            if "{" in link or "<" in link:
                continue  # template placeholder, not a path

            if link == "":
                target_rel = rel  # same-page anchor
            else:
                if link.startswith("#"):
                    continue
                target = os.path.normpath(
                    os.path.join(os.path.dirname(rel) or ".", link)
                )
                if not os.path.exists(os.path.join(ROOT, target)):
                    if link in KNOWN_MISSING or target in KNOWN_MISSING:
                        reason = KNOWN_MISSING.get(link, KNOWN_MISSING.get(target))
                        acknowledged.append(f"{rel}: {link} ({reason})")
                    else:
                        offenders.append(f"{rel}: {link}")
                    continue
                target_rel = (
                    target if os.path.isfile(os.path.join(ROOT, target)) else None
                )

            if not fragment or target_rel is None:
                continue
            if not target_rel.endswith(".md"):
                continue
            key = f"{rel}#{fragment}"
            if key in KNOWN_ANCHORS or fragment in KNOWN_ANCHORS:
                acknowledged.append(f"{key} (acknowledged)")
                continue
            if fragment not in anchors(target_rel):
                offenders.append(
                    f"{rel}: #{fragment} (no such heading in {target_rel})"
                )

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
