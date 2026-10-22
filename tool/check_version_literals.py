#!/usr/bin/env python3
"""Fail when a build version is hardcoded in `lib/`.

The app's version is written once, in `pubspec.yaml`, and stamped into the
build as `--dart-define=GRABLYTIC_APP_VERSION`. Before that it was a literal
in six files that disagreed with each other (`0.0.5+5`, `0.0.1-beta`,
`0.0.1-beta+1`), so a crash issue and the About screen described different
builds than the installed package (#105).

A version bump is exactly when nobody remembers the literals, so this is a
gate rather than a convention. Files that legitimately contain a
version-shaped literal — third-party component versions — are allowlisted
below, one line each.

Usage:
    python3 tool/check_version_literals.py
"""

from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "lib")

# A quoted string, escapes included. Versions are searched for inside these
# and never in bare code: `1.0` and `1280` are ordinary Dart numbers, and
# matching them would bury the signal (#108).
STRING_LITERAL = re.compile(r"""(?:'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*")""")

# Version-shaped, two components or more: '0.0.5+5', "v1.0", '0.0.1-beta',
# '1.2.3.4', '2026.8.19'. The lookbehind keeps a partial match out of a longer
# dotted run. Two components matter because the literals #105 removed were not
# bare versions: one was 'Version 0.0.1-beta (Build 1)'.
VERSION = re.compile(
    r"(?<![0-9A-Za-z_.:])v?[0-9]+\.[0-9]+(?:\.[0-9]+)*(?:[+-][0-9A-Za-z.-]+)?"
)


def is_version_shaped(token: str, whole_string: bool) -> bool:
    """Whether a dotted number is worth failing a build over.

    A bare '3.11' inside a sentence is prose, not a build. Anything carrying a
    'v' prefix, two or more dots, or a +build / -prerelease suffix is a version
    by shape. A string that is only a number qualifies too, which is how
    '0.6' and '1.0' stay covered (#108).
    """
    return (
        whole_string
        or token.startswith("v")
        or token.count(".") >= 2
        or "+" in token
        or "-" in token
    )


def version_literal_in(line: str) -> str | None:
    """The first quoted string on this line that holds a version, if any."""
    for literal in STRING_LITERAL.finditer(line):
        content = literal.group(0)[1:-1]
        for match in VERSION.finditer(content):
            if is_version_shaped(
                match.group(0), whole_string=content.strip() == match.group(0)
            ):
                return literal.group(0)
    return None


# Component versions, not the app's. Add a line, and say what it is.
ALLOWED = {
    os.path.join("lib", "core", "engine", "engine_contract.dart"),  # yt-dlp pin
    os.path.join("lib", "core", "engine", "mock_engine_service.dart"),  # fixtures
}


def scan(root: str = LIB) -> list[tuple[str, int, str]]:
    """Every version-shaped literal in a file that is not allowlisted."""
    found: list[tuple[str, int, str]] = []
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in sorted(filenames):
            if not name.endswith(".dart"):
                continue
            path = os.path.join(dirpath, name)
            relative = os.path.relpath(path, ROOT)
            if relative in ALLOWED:
                continue
            try:
                with open(path, encoding="utf-8") as handle:
                    lines = handle.readlines()
            except OSError:
                continue
            for number, line in enumerate(lines, start=1):
                literal = version_literal_in(line)
                if literal is not None:
                    found.append((relative, number, literal))
    return found


def main() -> int:
    found = scan()
    if not found:
        print("ok   no hardcoded app versions in lib/")
        return 0
    print("Hardcoded version literal(s) found — use AppVersion.value instead:")
    for path, number, literal in found:
        print(f"  {path}:{number}  {literal}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
