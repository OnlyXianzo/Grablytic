#!/usr/bin/env python3
"""Ratchet on deliberately broad catch handlers.

The teardown review's finding #61 was that "swallowed error" counts were
growing while the audit record called the work complete. Neither language
has a way to say "this catch is intentional and that one is not", so the
normal fix — delete them — is wrong: most of these handlers exist for a
good reason (a logging path must never take a download down, a storage
primitive must not crash the settings screen).

What can be measured is the direction of travel. This script holds two
counts at their current values and fails the build when one goes up. A
reviewer can then ask "is this broad catch load-bearing?" instead of
discovering six months later that there are a thousand of them.

Usage:
    python3 tool/check_broad_catches.py            # check (CI gate)
    python3 tool/check_broad_catches.py --update   # rewrite the budget

The counts are deliberately literal, matching the audit's definition:
    * Dart: `catch (_)` in lib/ (an unnamed handler, so nothing can be
      inspected or logged).
    * Python: `except Exception` in engine/grablytic_engine/.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUDGET_PATH = os.path.join(ROOT, "tool", "broad_catch_budget.json")

DART_PATTERN = re.compile(r"catch\s*\(\s*_\s*\)")
PYTHON_PATTERN = re.compile(r"except\s+Exception\b")

TARGETS = {
    "dart_catch_underscore_in_lib": {
        "root": os.path.join(ROOT, "lib"),
        "suffix": ".dart",
        "pattern": DART_PATTERN,
        "hint": (
            "Give the exception a name and log it, or narrow the type. "
            "If the swallow is deliberate, say why in a comment and keep "
            "the count flat."
        ),
    },
    "python_except_exception_in_engine": {
        "root": os.path.join(ROOT, "engine", "grablytic_engine"),
        "suffix": ".py",
        "pattern": PYTHON_PATTERN,
        "hint": (
            "Catch the exception into a variable and log it, or catch the "
            "specific type. A handler that must swallow should be "
            "documented; the budget then stays flat instead of creeping."
        ),
    },
}


def _count_files(root: str, suffix: str, pattern: re.Pattern[str]) -> int:
    total = 0
    for dirpath, _dirnames, filenames in os.walk(root):
        if "__pycache__" in dirpath:
            continue
        for name in sorted(filenames):
            if not name.endswith(suffix):
                continue
            path = os.path.join(dirpath, name)
            try:
                with open(path, encoding="utf-8") as handle:
                    text = handle.read()
            except OSError:
                continue
            total += len(pattern.findall(text))
    return total


def _current_counts() -> dict[str, int]:
    return {
        key: _count_files(spec["root"], spec["suffix"], spec["pattern"])
        for key, spec in TARGETS.items()
    }


def _load_budget() -> dict[str, int]:
    try:
        with open(BUDGET_PATH, encoding="utf-8") as handle:
            data = json.load(handle)
        return {key: int(value) for key, value in data.items()}
    except (OSError, ValueError, TypeError):
        return {}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--update",
        action="store_true",
        help="rewrite the budget from the current counts (do this when you "
        "reduce them, never to make a failure go away)",
    )
    args = parser.parse_args()

    current = _current_counts()

    if args.update:
        with open(BUDGET_PATH, "w", encoding="utf-8") as handle:
            json.dump(current, handle, indent=2, sort_keys=True)
            handle.write("\n")
        print(f"budget updated: {json.dumps(current, sort_keys=True)}")
        return 0

    budget = _load_budget()
    failures: list[str] = []

    for key, count in sorted(current.items()):
        allowed = budget.get(key)
        if allowed is None:
            failures.append(
                f"{key}: no budget entry (current {count}). Run "
                "--update once to record it."
            )
            continue
        status = "ok" if count <= allowed else "OVER"
        print(f"{status:4} {key}: {count} / {allowed}")
        if count > allowed:
            failures.append(
                f"{key}: {count} broad catches, budget is {allowed} "
                f"(+{count - allowed}). {TARGETS[key]['hint']}"
            )

    if failures:
        print("\nBroad-catch ratchet failed:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print("\nBroad-catch ratchet holds.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
