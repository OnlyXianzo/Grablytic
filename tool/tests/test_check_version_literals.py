"""The version gate has to catch the thing it was added for.

Finding #105: `0.0.5+5`, `0.0.1-beta` and `0.0.1-beta+1` all lived in `lib/`,
so a crash report and the About screen could describe a different build than
the one the user installed.
"""

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
    _write(str(tmp_path), "a.dart", "final s = \"v0.6.0\";\n")
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
