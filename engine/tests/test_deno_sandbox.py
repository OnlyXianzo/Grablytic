"""The Deno PO-token solver must run default-deny.

`deno eval` runs with ALL permissions enabled by default
(docs.deno.com -> runtime/manual/tools/eval). The harness now mirrors
yt-dlp's own invocation: `deno run` with an explicit default-deny flag
set, and the script piped on stdin.
"""

import sys

import pytest


def _pt():
    import grablytic_engine.po_token as pt
    return pt


@pytest.mark.unit
def test_the_solver_never_uses_deno_eval(monkeypatch):
    """`deno eval` is fully permissive — it must not appear."""
    pt = _pt()
    seen = {}

    class _Result:
        returncode = 1
        stdout = ""
        stderr = "boom"

    def _fake_run(cmd, **kwargs):
        seen["cmd"] = cmd
        return _Result()

    monkeypatch.setattr(pt, "PO_TOKEN_SOLVER_ENABLED", True)
    # The harness resolves the runtime itself; point it at a real file.
    monkeypatch.setattr("grablytic_engine.paths.get_paths", lambda: {})
    monkeypatch.setenv("DENO_PATH", sys.executable)
    monkeypatch.setattr(pt.shutil, "which", lambda name: None)
    monkeypatch.setattr("subprocess.run", _fake_run)
    pt._generate_with_deno("https://youtu.be/x")
    cmd = seen.get("cmd") or []
    assert "eval" not in cmd, cmd
    assert "run" in cmd, cmd


@pytest.mark.unit
def test_the_solver_uses_the_default_deny_flag_set(monkeypatch):
    pt = _pt()
    seen = {}

    class _Result:
        returncode = 1
        stdout = ""
        stderr = "boom"

    def _fake_run(cmd, **kwargs):
        seen["cmd"] = cmd
        return _Result()

    monkeypatch.setattr(pt, "PO_TOKEN_SOLVER_ENABLED", True)
    # The harness resolves the runtime itself; point it at a real file.
    monkeypatch.setattr("grablytic_engine.paths.get_paths", lambda: {})
    monkeypatch.setenv("DENO_PATH", sys.executable)
    monkeypatch.setattr(pt.shutil, "which", lambda name: None)
    monkeypatch.setattr("subprocess.run", _fake_run)
    pt._generate_with_deno("https://youtu.be/x")
    cmd = seen.get("cmd") or []
    for flag in ("--no-remote", "--no-config", "--no-prompt"):
        assert flag in cmd, cmd
    # No permission is ever GRANTED.
    assert not any(str(a).startswith("--allow-") for a in cmd), cmd


@pytest.mark.unit
def test_the_script_is_piped_on_stdin(monkeypatch):
    """`deno run -` reads the script from stdin, never from a file path."""
    pt = _pt()
    seen = {}

    class _Result:
        returncode = 1
        stdout = ""
        stderr = "boom"

    def _fake_run(cmd, **kwargs):
        seen["cmd"] = cmd
        seen["input"] = kwargs.get("input")
        return _Result()

    monkeypatch.setattr(pt, "PO_TOKEN_SOLVER_ENABLED", True)
    # The harness resolves the runtime itself; point it at a real file.
    monkeypatch.setattr("grablytic_engine.paths.get_paths", lambda: {})
    monkeypatch.setenv("DENO_PATH", sys.executable)
    monkeypatch.setattr(pt.shutil, "which", lambda name: None)
    monkeypatch.setattr("subprocess.run", _fake_run)
    pt._generate_with_deno("https://youtu.be/x")
    assert "-" in (seen.get("cmd") or [])
    assert seen.get("input") == pt.DENO_STUB_SCRIPT


@pytest.mark.unit
def test_the_flag_set_matches_yt_dlp():
    """The flag set mirrors yt-dlp's own Deno invocation."""
    pt = _pt()
    assert "--no-remote" in pt._DENO_RUN_FLAGS
    assert "--no-config" in pt._DENO_RUN_FLAGS
    assert "--no-prompt" in pt._DENO_RUN_FLAGS
    assert "--no-lock" in pt._DENO_RUN_FLAGS
    assert "--node-modules-dir=none" in pt._DENO_RUN_FLAGS
    assert not any(f.startswith("--allow-") for f in pt._DENO_RUN_FLAGS)


@pytest.mark.unit
def test_the_solver_stays_gated_off_by_default():
    """The allowlisted stub is inert: the spawn stays behind the flag."""
    pt = _pt()
    assert pt.PO_TOKEN_SOLVER_ENABLED is False
    assert pt._generate_with_deno("https://youtu.be/x") is None
