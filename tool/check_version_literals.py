#!/usr/bin/env python3
"""Fail when a build version is hardcoded in `lib/`.

The app's version is written once, in `pubspec.yaml`, and stamped into the
build as `--dart-define=GRABLYTIC_APP_VERSION`. Before that it was a literal
in six files that disagreed with each other (`0.0.5+5`, `0.0.1-beta`,
`0.0.1-beta+1`), so a crash issue and the About screen described different
builds than the installed package (#105).

A version bump is exactly when nobody remembers the literals, so this is a
gate rather than a convention.

What counts as a version here, learned from the literals that actually
shipped (#108): a quoted string holding a dotted number that carries a `v`
prefix, two or more dots, or a real `-beta` / `+5` style marker, or a string
that is nothing but that number. Numbers in code, dates, dotted-quad
addresses and hyphenated prose are not versions (#110). Comments are not
code (#112), and Dart folds adjacent literals, so `'0.0.' '6'` is the
string `0.0.6` (#113).

The scanner works a line at a time. A raw string (`r'\d+'`) or an
interpolated one is tokenized approximately, and a literal split across two
lines is not folded, so a version can hide in either. No formatter splits a
version literal today; this is the known edge, not a claim of completeness.

Usage:
    python3 tool/check_version_literals.py
"""

from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "lib")

# One quoted string, escapes included.
STRING_LITERAL = re.compile(r"""(?:'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*")""")

# A version-shaped token: two components or more, optional `v`, optional
# suffix. The lookbehind keeps a partial match out of a longer dotted run.
VERSION = re.compile(
    r"(?<![0-9A-Za-z_.:])v?[0-9]+\.[0-9]+(?:\.[0-9]+)*(?:[+-][0-9A-Za-z.-]+)?"
)

# A calendar date used as a component version: yt-dlp's own tags are dates
# (`2026.8.19`, `2025.06.06`). Four-digit year, month 1-12, day 1-31.
DATE = re.compile(r"(?:19|20)\d{2}\.(?:0?[1-9]|1[0-2])\.(?:0?[1-9]|[12]\d|3[01])")

# A dotted quad, e.g. 127.0.0.1 or 10.0.2.2. No app version has four numeric
# components; `pubspec.yaml` is `x.y.z+ n`.
IPV4 = re.compile(r"(?<![0-9.])(?:\d{1,3}\.){3}\d{1,3}(?![0-9.])")

# A real prerelease or build marker, as opposed to the hyphen in '3.5-inch'.
MARKED = re.compile(r"[+-](?:\d+|alpha|beta|rc|pre|dev)", re.IGNORECASE)

# Between two literals Dart will concatenate: whitespace, optional `+`.
CONCATENATED = re.compile(r"\s*\+?\s*")

# (path, literal) -> why. One literal, named, with a reason. A file-wide pass
# hid every literal in the file, including the next hardcoded app version
# (#111). Empty today: dates and comments are excluded by shape, so the two
# entries this used to carry are gone.
ALLOWED: dict[tuple[str, str], str] = {}


def code_part(line: str) -> str:
    """The line with any trailing `//` comment removed, string-aware.

    A version in a comment is documentation, not something the build can
    print. Quote tracking keeps the `//` in `'https://…'` from reading as the
    start of a comment (#112).
    """
    quote: str | None = None
    escaped = False
    for index, char in enumerate(line):
        if quote is not None:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
        elif char in "'\"":
            quote = char
        elif char == "/" and line[index : index + 2] == "//":
            return line[:index]
    return line


def literals_in(code: str) -> list[tuple[str, str]]:
    """(whole-match text, content) for each literal, adjacent ones folded.

    Dart joins adjacent string literals at compile time, so `'0.0.' '6'` and
    `'0.0.' + '6'` are both the string `0.0.6`. Judging each on its own is
    what let a wrapped version through (#113).
    """
    matches = list(STRING_LITERAL.finditer(code))
    out: list[tuple[str, str]] = []
    index = 0
    while index < len(matches):
        first = current = matches[index]
        content = current.group(0)[1:-1]
        while index + 1 < len(matches):
            gap = code[current.end() : matches[index + 1].start()]
            if not CONCATENATED.fullmatch(gap):
                break
            index += 1
            current = matches[index]
            content += current.group(0)[1:-1]
        out.append((code[first.start() : current.end()], content))
        index += 1
    return out


def is_version_shaped(token: str, whole_string: bool) -> bool:
    """Whether a dotted number is worth failing a build over."""
    if DATE.fullmatch(token) or IPV4.fullmatch(token):
        return False
    return (
        whole_string
        or token.startswith("v")
        or token.count(".") >= 2
        or MARKED.search(token) is not None
    )


def version_literal_in(line: str) -> str | None:
    """The first quoted string in this line's code that holds a version."""
    for literal, content in literals_in(code_part(line)):
        for match in VERSION.finditer(content):
            if is_version_shaped(
                match.group(0), whole_string=content.strip() == match.group(0)
            ):
                return literal
    return None


def stale_exemptions() -> list[str]:
    """Exemptions that no longer name a reason, a file, or a literal."""
    problems: list[str] = []
    for (relative, literal), why in sorted(ALLOWED.items()):
        if not why.strip():
            problems.append(f"{relative}: {literal} has no reason")
            continue
        path = os.path.join(ROOT, relative)
        if not os.path.isfile(path):
            problems.append(f"{relative}: exempted file does not exist")
            continue
        with open(path, encoding="utf-8") as handle:
            if literal not in handle.read():
                problems.append(f"{relative}: {literal} is not in the file any more")
    return problems


def scan(root: str = LIB) -> list[tuple[str, int, str]]:
    """Every version-shaped literal in a file that is not exempted."""
    found: list[tuple[str, int, str]] = []
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in sorted(filenames):
            if not name.endswith(".dart"):
                continue
            path = os.path.join(dirpath, name)
            relative = os.path.relpath(path, ROOT)
            try:
                with open(path, encoding="utf-8") as handle:
                    lines = handle.readlines()
            except OSError:
                continue
            for number, line in enumerate(lines, start=1):
                literal = version_literal_in(line)
                if literal is not None and (relative, literal) not in ALLOWED:
                    found.append((relative, number, literal))
    return found


def main() -> int:
    problems = stale_exemptions()
    found = scan()
    if not problems and not found:
        print("ok   no hardcoded app versions in lib/")
        return 0
    if found:
        print("Hardcoded version literal(s) found, use AppVersion.value instead:")
        for path, number, literal in found:
            print(f"  {path}:{number}  {literal}")
    if problems:
        print("Exemptions that no longer hold:")
        for line in problems:
            print(f"  {line}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
