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
from typing import Any

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
    """Count literal regex matches in matching files beneath ``root``.

    Skip paths containing ``__pycache__`` and files that raise OSError on
    read. Matches in comments and strings count too; UTF-8 decoding errors
    propagate.
    """
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
    """Return literal broad-handler counts for each configured target."""
    return {
        key: _count_files(spec["root"], spec["suffix"], spec["pattern"])
        for key, spec in TARGETS.items()
    }


def _parse_entry(value: Any) -> tuple[int | None, str | None]:
    """(limit, why) for one budget entry.

    An entry is either a bare integer or ``{"limit": n, "why": "..."}``. The
    second form exists because a number on its own is not a decision: this
    budget was raised once in the same commit as the catch that raised it,
    with nothing recording why, and the gate passed (#107).
    """
    if isinstance(value, bool):
        return None, None
    if isinstance(value, int):
        return value, None
    if isinstance(value, dict):
        limit = value.get("limit")
        why = value.get("why")
        return (
            limit if isinstance(limit, int) and not isinstance(limit, bool) else None,
            why.strip() if isinstance(why, str) and why.strip() else None,
        )
    return None, None


def _load_budget(path: str = BUDGET_PATH) -> dict[str, tuple[int | None, str | None]]:
    """Load budgets, or return {} on read, parse, or conversion errors."""
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
        if not isinstance(data, dict):
            return {}
        return {key: _parse_entry(value) for key, value in data.items()}
    except (OSError, ValueError, TypeError):
        return {}


def _serialise(
    counts: dict[str, int], budget: dict[str, tuple[int | None, str | None]]
) -> dict:
    """The budget as written to disk: keep every recorded reason."""
    out: dict[str, Any] = {}
    for key in sorted(counts):
        limit = counts[key]
        _old_limit, why = budget.get(key, (None, None))
        out[key] = {"limit": limit, "why": why} if why else limit
    return out


def _raised_without_reason(
    current: dict[str, int],
    budget: dict[str, tuple[int | None, str | None]],
) -> list[str]:
    """Keys whose count went up while the entry carries no justification."""
    failures: list[str] = []
    for key, count in sorted(current.items()):
        limit, why = budget.get(key, (None, None))
        if limit is None:
            failures.append(
                f"{key}: no budget entry (current {count}). Run --update once "
                "to record it."
            )
            continue
        if count > limit and not why:
            failures.append(
                f"{key}: raised {limit} -> {count} without a 'why' entry. Add "
                '{"limit": n, "why": "<what makes this catch necessary>"} to '
                "tool/broad_catch_budget.json in a separate commit."
            )
    return failures


def main() -> int:
    """Check counts against budgets, or overwrite the budget with --update.

    Print results and return 1 for missing or exceeded budgets, otherwise 0.
    Argument errors exit through argparse; budget-write errors propagate.
    """
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--update",
        action="store_true",
        help="rewrite the budget from the current counts (do this when you "
        "reduce them, never to make a failure go away)",
    )
    args = parser.parse_args()

    current = _current_counts()

    previous = _load_budget()

    if args.update:
        # Raising a number is a decision, so it needs a reason on record.
        blocked = _raised_without_reason(current, previous)
        if blocked:
            print("refusing to raise the budget without a recorded reason:")
            for line in blocked:
                print(f"  - {line}")
            return 1
        with open(BUDGET_PATH, "w", encoding="utf-8") as handle:
            json.dump(_serialise(current, previous), handle, indent=2, sort_keys=True)
            handle.write("\n")
        print(f"budget updated: {json.dumps(current, sort_keys=True)}")
        return 0

    failures: list[str] = []

    for key, count in sorted(current.items()):
        allowed, why = previous.get(key, (None, None))
        if allowed is None:
            failures.append(
                f"{key}: no budget entry (current {count}). Run "
                "--update once to record it."
            )
            continue
        status = "ok" if count <= allowed else "OVER"
        suffix = "" if why is None else "  (reason on file)"
        print(f"{status:4} {key}: {count} / {allowed}{suffix}")
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
