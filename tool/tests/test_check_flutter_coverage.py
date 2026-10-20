from pathlib import Path

import pytest

from tool.check_flutter_coverage import parse_lcov


def test_parse_lcov_counts_project_lines_and_ignores_external_sources(
    tmp_path: Path,
) -> None:
    report = tmp_path / "coverage.info"
    report.write_text(
        """TN:
SF:lib/core/a.dart
DA:1,1
DA:2,0
LF:2
LH:1
end_of_record
SF:package:grablytic/core/b.dart
DA:8,0
DA:8,2
LF:1
LH:1
end_of_record
SF:package:flutter/widgets.dart
DA:1,0
LF:1
LH:0
end_of_record
""",
        encoding="utf-8",
    )

    assert parse_lcov(report) == (2, 3, 2)


def test_parse_lcov_rejects_inconsistent_lf_summary(tmp_path: Path) -> None:
    report = tmp_path / "coverage.info"
    report.write_text(
        "SF:lib/a.dart\nDA:1,1\nLF:2\nLH:1\nend_of_record\n",
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="LF:2 disagrees with 1 DA lines"):
        parse_lcov(report)


def test_parse_lcov_rejects_truncated_record(tmp_path: Path) -> None:
    report = tmp_path / "coverage.info"
    report.write_text("SF:lib/a.dart\nDA:1,1\n", encoding="utf-8")

    with pytest.raises(ValueError, match="ends before end_of_record"):
        parse_lcov(report)


def test_parse_lcov_accepts_a_file_with_no_executable_lines(
    tmp_path: Path,
) -> None:
    """A barrel library has an SF record and nothing else.

    LCOV emits `SF:...` / `end_of_record` with no DA rows for a file whose
    content is only `export` directives. The gate used to call that
    corruption and exit 2, failing the build over a file that cannot be
    covered at all.
    """
    report = tmp_path / "coverage.info"
    report.write_text(
        """SF:lib/core/barrel.dart
end_of_record
SF:lib/core/a.dart
DA:1,1
DA:2,0
LF:2
LH:1
end_of_record
SF:lib/core/exported.dart
LF:0
LH:0
end_of_record
""",
        encoding="utf-8",
    )

    assert parse_lcov(report) == (1, 2, 1)


def test_parse_lcov_still_rejects_an_empty_record_claiming_lines(
    tmp_path: Path,
) -> None:
    report = tmp_path / "coverage.info"
    report.write_text(
        "SF:lib/a.dart\nLF:3\nLH:2\nend_of_record\n", encoding="utf-8"
    )

    with pytest.raises(ValueError, match="no DA line data but claims"):
        parse_lcov(report)
