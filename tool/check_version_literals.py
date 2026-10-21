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

# A string literal that is nothing but a version, optionally prefixed with
# "v" and carrying a build number: '0.0.5+5', "v0.6.0", '2026.8.19'.
LITERAL = re.compile(r"""['"]v?\d+\.\d+\.\d+(?:\+[0-9A-Za-z.-]+)?['"]""")

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
                match = LITERAL.search(line)
                if match:
                    found.append((relative, number, match.group(0)))
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
