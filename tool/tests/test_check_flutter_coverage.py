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
