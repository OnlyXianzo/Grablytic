#!/usr/bin/env python3
"""Enforce a line-coverage floor for this repository's Dart application code.

Flutter's `test --coverage` emits an LCOV tracefile. We count unique executable
lines from project `lib/` sources only; imported Flutter/Dart packages and tests
are outside this gate. LCOV's DA records carry per-line execution counts, while
LF/LH summaries are checked when present.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

DEFAULT_FLOOR = 30.0
REPO_ROOT = Path(__file__).resolve().parents[1]
LIB_ROOT = (REPO_ROOT / "lib").resolve()


def project_source(source: str) -> str | None:
    """Return a normalized project-relative Dart path, or None if external."""
    normalized = source.replace("\\", "/")
    package_prefix = "package:grablytic/"
    if normalized.startswith(package_prefix):
        package_path = normalized[len(package_prefix) :]
        candidate = (
            REPO_ROOT / package_path
            if package_path.startswith("lib/")
            else LIB_ROOT / package_path
        )
    else:
        candidate = Path(normalized)
        if not candidate.is_absolute():
            candidate = REPO_ROOT / candidate

    try:
        resolved = candidate.resolve(strict=False)
        relative = resolved.relative_to(LIB_ROOT)
    except (OSError, ValueError):
        return None

    if relative.suffix != ".dart":
        return None
    return relative.as_posix()


def _integer(value: str, field: str, line_number: int) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise ValueError(
            f"line {line_number}: invalid {field} value {value!r}"
        ) from exc
    if parsed < 0:
        raise ValueError(f"line {line_number}: negative {field} value")
    return parsed


def _merge_lcov_project_record(
    files: dict, state: dict, end_line: int, source: str
) -> None:
    """Merge a project's line hits into ``files``, OR-ing duplicate lines.

    Ignore external sources and records without DA rows whose LF/LH totals
    are absent or zero. Raise ValueError when present summaries disagree
    with line data; ``end_line`` identifies the record end in diagnostics.
    """
    project_path = project_source(source)
    if project_path is None:
        return
    line_hits = state["line_hits"]
    summary_found = state["summary_found"]
    summary_hit = state["summary_hit"]
    if not line_hits:
        # LCOV emits a bare SF/end_of_record pair for a file with no
        # executable lines — a barrel library of `export` directives, an
        # `abstract interface class` with only signatures, a `part` holder.
        # That is a valid record, and treating it as corruption made the
        # gate exit 2 (a hard error, not a coverage failure) for files that
        # simply cannot be covered.
        if summary_found not in (None, 0) or summary_hit not in (None, 0):
            raise ValueError(
                f"lines {state['record_start']}-{end_line}: {source!r} has no DA "
                f"line data but claims LF:{summary_found} LH:{summary_hit}"
            )
        return
    found = len(line_hits)
    hit = sum(line_hits.values())
    if summary_found is not None and summary_found != found:
        raise ValueError(
            f"line {end_line}: LF:{summary_found} disagrees with {found} DA lines in {source!r}"
        )
    if summary_hit is not None and summary_hit != hit:
        raise ValueError(
            f"line {end_line}: LH:{summary_hit} disagrees with {hit} hit DA lines in {source!r}"
        )
    merged = files.setdefault(project_path, {})
    for number, was_hit in line_hits.items():
        merged[number] = merged.get(number, False) or was_hit


def _finish_lcov_record(files: dict, state: dict, end_line: int) -> None:
    source = state["source"]
    if source is None:
        if (
            state["line_hits"]
            or state["summary_found"] is not None
            or state["summary_hit"] is not None
        ):
            raise ValueError(f"line {end_line}: LCOV data has no SF source record")
    else:
        _merge_lcov_project_record(files, state, end_line, source)
    state.update(
        source=None,
        line_hits={},
        summary_found=None,
        summary_hit=None,
        record_start=end_line + 1,
    )


def _handle_lcov_source(source: str, line_number: int, state: dict) -> None:
    if state["source"] is not None:
        raise ValueError(f"line {line_number}: new SF record before end_of_record")
    state["source"] = source
    state["line_hits"] = {}
    state["record_start"] = line_number


def _handle_lcov_line_data(data: str, line_number: int, state: dict) -> None:
    if state["source"] is None:
        raise ValueError(f"line {line_number}: DA record appears before SF")
    fields = data.split(",")
    if len(fields) < 2:
        raise ValueError(f"line {line_number}: malformed DA record")
    source_line = _integer(fields[0], "source line", line_number)
    if source_line == 0:
        raise ValueError(f"line {line_number}: source line numbers must be positive")
    hits = _integer(fields[1], "line hit count", line_number)
    line_hits = state["line_hits"]
    line_hits[source_line] = line_hits.get(source_line, False) or hits > 0


def _handle_lcov_summary(data: str, line_number: int, state: dict, field: str) -> None:
    value = _integer(data, field, line_number)
    key = "summary_found" if field == "LF" else "summary_hit"
    state[key] = value


def _handle_lcov_row(row: str, line_number: int, files: dict, state: dict) -> None:
    key, _, data = row.partition(":")
    if key == "SF":
        _handle_lcov_source(data, line_number, state)
    elif key == "DA":
        _handle_lcov_line_data(data, line_number, state)
    elif key == "LF":
        _handle_lcov_summary(data, line_number, state, "LF")
    elif key == "LH":
        _handle_lcov_summary(data, line_number, state, "LH")
    elif key == "end_of_record":
        _finish_lcov_record(files, state, line_number)


def _lcov_record_is_open(state: dict) -> bool:
    return (
        state["source"] is not None
        or state["line_hits"]
        or state["summary_found"] is not None
        or state["summary_hit"] is not None
    )


def _lcov_aggregate(files: dict) -> tuple[int, int]:
    found = sum(len(lines) for lines in files.values())
    hit = sum(sum(lines.values()) for lines in files.values())
    return found, hit


def parse_lcov(path: Path) -> tuple[int, int, int]:
    """Return (files, executable_lines, hit_lines) for unique project lines."""
    try:
        rows = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise ValueError(f"cannot read LCOV report {path}: {exc}") from exc

    files: dict[str, dict[int, bool]] = {}
    state = {
        "source": None,
        "line_hits": {},
        "summary_found": None,
        "summary_hit": None,
        "record_start": 0,
    }
    for line_number, row in enumerate(rows, start=1):
        _handle_lcov_row(row, line_number, files, state)
    if _lcov_record_is_open(state):
        raise ValueError("LCOV report ends before end_of_record")
    if not files:
        raise ValueError(
            f"no project Dart sources under {LIB_ROOT} were found in {path}"
        )
    found, hit = _lcov_aggregate(files)
    if found == 0 or hit > found:
        raise ValueError(
            f"invalid aggregate LCOV totals: {hit} hit lines out of {found}"
        )
    return len(files), found, hit


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "lcov_file",
        nargs="?",
        type=Path,
        default=Path("coverage/lcov.info"),
        help="Flutter LCOV report (default: coverage/lcov.info)",
    )
    parser.add_argument(
        "--fail-under",
        type=float,
        default=DEFAULT_FLOOR,
        metavar="PERCENT",
        help=f"minimum project-lib line coverage (default: {DEFAULT_FLOOR:g}%)",
    )
    args = parser.parse_args()
    if not 0 <= args.fail_under <= 100:
        parser.error("--fail-under must be between 0 and 100")

    try:
        file_count, found, hit = parse_lcov(args.lcov_file)
    except ValueError as exc:
        print(f"Flutter coverage check: ERROR: {exc}", file=sys.stderr)
        return 2

    percentage = 100.0 * hit / found
    print(
        f"Flutter line coverage: {percentage:.2f}% "
        f"({hit}/{found} executable lines across {file_count} lib/ files); "
        f"required: {args.fail_under:.2f}%"
    )
    if percentage + 1e-9 < args.fail_under:
        print("Flutter coverage check: FAIL", file=sys.stderr)
        return 1
    print("Flutter coverage check: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
