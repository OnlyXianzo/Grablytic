"""The version gate has to catch the thing it was added for, and only that.

Finding #105: `0.0.5+5`, `0.0.1-beta` and `0.0.1-beta+1` all lived in `lib/`,
so a crash report and the About screen could describe a different build than
the one the user installed.

Finding #108: the first version of this gate only matched a string that was
nothing but a three-component version, so five of the six shapes that had
actually shipped passed it.

Findings #110-#113 are the follow-ups: the widened matcher must not fire on
addresses, dates or hyphenated prose, comments are not code, a version folded
across adjacent literals is still a version, and an exemption names one
literal rather than a whole file.
"""

import importlib.util
import os

import pytest

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


def test_reports_every_offending_line(tmp_path):
    _write(str(tmp_path), "a.dart", "const a = '1.0.0';\nconst b = 'v2.5';\n")
    assert [entry[1] for entry in cvl.scan(str(tmp_path))] == [1, 2]


def test_a_version_only_counts_inside_a_string(tmp_path):
    # Dart numbers are not versions, however many dots they appear to have.
    _write(str(tmp_path), "a.dart", "final x = 1.0;\nfinal y = 3.14;\n")
    assert cvl.scan(str(tmp_path)) == []


@pytest.mark.parametrize(
    "source",
    [
        "const a = '0.0.6';",
        "const a = 'v1.0';",
        "const a = '0.6';",
        "const a = '0.0.1-beta';",
        "const a = '0.0.1-beta+1';",
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
        # #110: a dotted quad is an address. `'1.2.3.4'` used to be in the
        # must-catch list; it is a valid IPv4 and never one of the six sites,
        # and keeping it there is what made the gate cry wolf on loopback.
        "final host = '10.0.2.2';",
        "final url = 'http://127.0.0.1:8080/health';",
        # #110: a hyphen is not a prerelease marker.
        "const note = '3.5-inch screen';",
        # #110: yt-dlp's tags are dates; so is a release date.
        "const day = '2026.10.21';",
    ],
)
def test_does_not_cry_wolf(tmp_path, source):
    _write(str(tmp_path), "x.dart", source + "\n")
    assert cvl.scan(str(tmp_path)) == [], source


# --- #112: comments are not code -------------------------------------------


def test_a_version_in_a_doc_comment_is_not_a_finding(tmp_path):
    _write(str(tmp_path), "a.dart", '  /// Human-readable form ("1.0").\n')
    assert cvl.scan(str(tmp_path)) == []


def test_a_version_in_a_line_comment_is_not_a_finding(tmp_path):
    _write(str(tmp_path), "a.dart", "// bumped 0.0.5+5 -> 0.0.6+6\n")
    assert cvl.scan(str(tmp_path)) == []


def test_a_comment_does_not_hide_code_before_it(tmp_path):
    _write(str(tmp_path), "a.dart", "final ok = '0.0.6'; // bump later\n")
    assert cvl.scan(str(tmp_path)), "the literal is in the code, not the comment"


def test_a_url_with_slashes_is_not_read_as_a_comment(tmp_path):
    _write(str(tmp_path), "a.dart", "final u = 'https://x.example/y'; // note\n")
    assert cvl.scan(str(tmp_path)) == []


def test_code_part_strips_only_the_comment(tmp_path):
    assert cvl.code_part("final a = 1; // 0.0.6") == "final a = 1; "
    assert cvl.code_part("final a = '//';") == "final a = '//';"


# --- #113: a version folded across adjacent literals ------------------------


@pytest.mark.parametrize(
    "source",
    [
        "const v = '0.0.' '6';",
        "const v = '0.0.' + '6';",
        "const v = 'Version ' '0.0.5+5';",
    ],
)
def test_a_version_split_across_literals_is_caught(tmp_path, source):
    _write(str(tmp_path), "x.dart", source + "\n")
    assert cvl.scan(str(tmp_path)), source


def test_unrelated_neighbours_are_not_glued_together(tmp_path):
    _write(str(tmp_path), "a.dart", "Text('a') + Text('b'),\n")
    assert cvl.scan(str(tmp_path)) == []


# --- #111: an exemption names one literal, not a file ----------------------


def _with_allowlist(allow, root, source="const v = '1.2.3';\n"):
    _write(str(root), "x.dart", source)
    original_root, original_allowed = cvl.ROOT, dict(cvl.ALLOWED)
    try:
        cvl.ROOT = str(root)
        cvl.ALLOWED = dict(allow)
        return cvl.scan(str(root))
    finally:
        cvl.ROOT, cvl.ALLOWED = original_root, original_allowed


def test_an_exempted_literal_is_skipped(tmp_path):
    relative = os.path.join("x.dart")
    assert _with_allowlist({(relative, "'1.2.3'"): "fixture"}, tmp_path) == []


def test_an_exemption_does_not_hide_the_next_literal_in_the_file(tmp_path):
    relative = os.path.join("x.dart")
    found = _with_allowlist(
        {(relative, "'1.2.3'"): "fixture"},
        tmp_path,
        source="const a = '1.2.3';\nconst b = '9.9.9';\n",
    )
    assert [entry[2] for entry in found] == ["'9.9.9'"]


def test_a_stale_exemption_is_reported(tmp_path):
    relative = os.path.join("x.dart")
    original_root, original_allowed = cvl.ROOT, dict(cvl.ALLOWED)
    try:
        cvl.ROOT = str(tmp_path)
        cvl.ALLOWED = {(relative, "'7.7.7'"): "gone"}
        _write(str(tmp_path), "x.dart", "const a = '1.2.3';\n")
        problems = cvl.stale_exemptions()
        assert problems and "not in the file any more" in problems[0]
    finally:
        cvl.ROOT, cvl.ALLOWED = original_root, original_allowed


def test_an_exemption_for_a_missing_file_is_reported(tmp_path):
    original_root, original_allowed = cvl.ROOT, dict(cvl.ALLOWED)
    try:
        cvl.ROOT = str(tmp_path)
        cvl.ALLOWED = {("nope.dart", "'1.2.3'"): "why"}
        problems = cvl.stale_exemptions()
        assert problems and "does not exist" in problems[0]
    finally:
        cvl.ROOT, cvl.ALLOWED = original_root, original_allowed


def test_a_directory_where_a_file_is_expected_is_reported_not_raised(tmp_path):
    original_root, original_allowed = cvl.ROOT, dict(cvl.ALLOWED)
    try:
        cvl.ROOT = str(tmp_path)
        cvl.ALLOWED = {("dir", "'1.2.3'"): "why"}
        (tmp_path / "dir").mkdir()
        problems = cvl.stale_exemptions()
        assert problems and "cannot be read" in problems[0]
    finally:
        cvl.ROOT, cvl.ALLOWED = original_root, original_allowed


def test_an_exemption_without_a_reason_is_reported(tmp_path):
    original_root, original_allowed = cvl.ROOT, dict(cvl.ALLOWED)
    try:
        cvl.ROOT = str(tmp_path)
        cvl.ALLOWED = {("x.dart", "'1.2.3'"): "   "}
        problems = cvl.stale_exemptions()
        assert problems and "has no reason" in problems[0]
    finally:
        cvl.ROOT, cvl.ALLOWED = original_root, original_allowed


def test_the_repository_has_no_stale_exemptions():
    assert cvl.stale_exemptions() == []
