"""The version gate has to catch the thing it was added for.

Finding #105: `0.0.5+5`, `0.0.1-beta` and `0.0.1-beta+1` all lived in `lib/`,
so a crash report and the About screen could describe a different build than
the one the user installed.

Finding #108: the first version of this gate only matched a string that was
nothing but a three-component version, so five of the six shapes that had
actually shipped passed it. The parametrized cases below are those shapes.
"""

import pytest

import importlib.util
import os

_MODULE_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "check_version_literals.py",
)
_spec = importlib.util.spec_from_file_location("check_version_literals", _MODULE_PATH)
cvl = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cvl)


def _write(root, name, body):
    path = os.path.join(root, name)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(body)
    return path


def test_finds_a_version_literal(tmp_path):
    _write(str(tmp_path), "a.dart", "const v = '0.0.5+5';\n")
    found = cvl.scan(str(tmp_path))
    assert found and found[0][2] == "'0.0.5+5'"


def test_finds_a_tag_shaped_literal(tmp_path):
    _write(str(tmp_path), "a.dart", 'final s = "v0.6.0";\n')
    assert cvl.scan(str(tmp_path))


def test_ignores_the_stamped_lookup(tmp_path):
    _write(
        str(tmp_path),
        "a.dart",
        "static const String _v = String.fromEnvironment('GRABLYTIC_APP_VERSION');\n",
    )
    assert cvl.scan(str(tmp_path)) == []


def test_ignores_non_version_numbers(tmp_path):
    _write(str(tmp_path), "a.dart", "const w = '1280x720';\nconst n = 1.5;\n")
    assert cvl.scan(str(tmp_path)) == []


def test_allowlisted_files_are_skipped(tmp_path):
    # The allowlist is path-based, so this checks the shape of the decision
    # rather than a specific yt-dlp pin.
    allowed = os.path.join("lib", "core", "engine", "engine_contract.dart")
    nested = tmp_path / "lib" / "core" / "engine"
    nested.mkdir(parents=True)
    _write(str(nested), "engine_contract.dart", "const v = '2026.8.19';\n")

    original_root, original_allowed = cvl.ROOT, cvl.ALLOWED
    try:
        cvl.ROOT = str(tmp_path)
        cvl.ALLOWED = {allowed}
        assert cvl.scan(str(tmp_path / "lib")) == []
    finally:
        cvl.ROOT, cvl.ALLOWED = original_root, original_allowed


@pytest.mark.parametrize(
    "source",
    [
        "const a = '0.0.6';",
        "const a = 'v1.0';",
        "const a = '0.6';",
        "const a = '1.2.3.4';",
        "const a = 'Version 0.0.1-beta (Build 1)';",
        "const a = 'v0.0.1-beta · The Only';",
    ],
)
def test_catches_the_shapes_that_shipped(tmp_path, source):
    _write(str(tmp_path), "x.dart", source + "\n")
    assert cvl.scan(str(tmp_path)), source


@pytest.mark.parametrize(
    "source",
    [
        # Python version in prose, not a build.
        "const a = 'Houses a sandboxed Python 3.11 environment';",
        # Milliseconds inside an ISO timestamp.
        "const t = '2026-10-19T21:30:00.000';",
        "const w = '1280x720';",
        "const n = 1.5;",
        "const u = 'https://example.com/watch?v=abc';",
    ],
)
def test_does_not_cry_wolf(tmp_path, source):
    _write(str(tmp_path), "x.dart", source + "\n")
    assert cvl.scan(str(tmp_path)) == [], source


def test_reports_every_offending_line(tmp_path):
    _write(str(tmp_path), "a.dart", "const a = '1.0.0';\nconst b = 'v2.5';\n")
    assert [entry[1] for entry in cvl.scan(str(tmp_path))] == [1, 2]


def test_a_version_only_counts_inside_a_string(tmp_path):
    # Dart numbers are not versions, however many dots they appear to have.
    _write(str(tmp_path), "a.dart", "final x = 1.0;\nfinal y = 3.14;\n")
    assert cvl.scan(str(tmp_path)) == []
