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


def parse_lcov(path: Path) -> tuple[int, int, int]:
    """Return (files, executable_lines, hit_lines) for unique project lines."""
    try:
        rows = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise ValueError(f"cannot read LCOV report {path}: {exc}") from exc

    files: dict[str, dict[int, bool]] = {}
    source: str | None = None
    line_hits: dict[int, bool] = {}
    summary_found: int | None = None
    summary_hit: int | None = None
    record_start = 0

    def finish_record(end_line: int) -> None:
        nonlocal source, line_hits, summary_found, summary_hit, record_start
        if source is None:
            if line_hits or summary_found is not None or summary_hit is not None:
                raise ValueError(f"line {end_line}: LCOV data has no SF source record")
        else:
            project_path = project_source(source)
            if project_path is not None:
                if not line_hits:
                    raise ValueError(
                        f"lines {record_start}-{end_line}: {source!r} has no DA line data"
                    )
                files.setdefault(project_path, {}).update(line_hits)
        source = None
        line_hits.clear()
        summary_found = None
        summary_hit = None

    def handle_sf(data: str, lineno: int) -> None:
        nonlocal source, line_hits, record_start
        if source is not None:
            finish_record(lineno - 1)
        source = data
        line_hits = {}
        record_start = lineno

    def handle_da(data: str, lineno: int) -> None:
        nonlocal line_hits
        parts = data.split(",", 1)
        if len(parts) != 2:
            raise ValueError(f"line {lineno}: invalid DA record {data!r}")
        loc_str, count_str = parts
        loc = _integer(loc_str, "line", lineno)
        count = _integer(count_str, "hit", lineno)
        line_hits[loc] = count > 0

    def handle_lf(data: str, lineno: int) -> None:
        nonlocal summary_found
        summary_found = _integer(data, "lines found", lineno)

    def handle_lh(data: str, lineno: int) -> None:
        nonlocal summary_hit
        summary_hit = _integer(data, "lines hit", lineno)

    handlers = {
        "SF": handle_sf,
        "DA": handle_da,
        "LF": handle_lf,
        "LH": handle_lh,
        "end_of_record": lambda _data, lineno: finish_record(lineno),
    }

    for lineno, row in enumerate(rows, start=1):
        key, _, rest = row.partition(":")
        handler = handlers.get(key)
        if handler:
            handler(rest, lineno)

    if source is not None:
        finish_record(len(rows))

    if summary_found is None or summary_hit is None:
        raise ValueError("LCOV summary missing LF or LH records")

    total_files = len(files)
    total_lines = sum(len(hits) for hits in files.values())
    total_hits = sum(
        sum(1 for hit in hits.values() if hit) for hits in files.values()
    )
    return total_files, total_lines, total_hits
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

        source = None
        line_hits = {}
        summary_found = None
        summary_hit = None
        record_start = end_line + 1

    for number, row in enumerate(rows, start=1):
        if row == "end_of_record":
            finish_record(number)
        elif row.startswith("SF:"):
            if source is not None:
                raise ValueError(f"line {number}: new SF record before end_of_record")
            source = row[3:]
            record_start = number
        elif row.startswith("DA:"):
            if source is None:
                raise ValueError(f"line {number}: DA record appears before SF")
            fields = row[3:].split(",")
            if len(fields) < 2:
                raise ValueError(f"line {number}: malformed DA record")
            source_line = _integer(fields[0], "source line", number)
            if source_line == 0:
                raise ValueError(f"line {number}: source line numbers must be positive")
            hits = _integer(fields[1], "line hit count", number)
            line_hits[source_line] = line_hits.get(source_line, False) or hits > 0
        elif row.startswith("LF:"):
            summary_found = _integer(row[3:], "LF", number)
        elif row.startswith("LH:"):
            summary_hit = _integer(row[3:], "LH", number)

    if (
        source is not None
        or line_hits
        or summary_found is not None
        or summary_hit is not None
    ):
        raise ValueError("LCOV report ends before end_of_record")
    if not files:
        raise ValueError(
            f"no project Dart sources under {LIB_ROOT} were found in {path}"
        )

    found = sum(len(lines) for lines in files.values())
    hit = sum(sum(lines.values()) for lines in files.values())
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
