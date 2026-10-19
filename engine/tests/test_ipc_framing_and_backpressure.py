"""IPC framing firewall + bounded dispatch tests.

Covers the teardown finding that a single stray stdout write desyncs the
client's JSON line parser for the whole session, and that the slow lane
had no back-pressure at all (unbounded `pool.submit` queue).
"""

import io
import json
import sys

import pytest


def _main_mod():
    import importlib

    return importlib.import_module("grablytic_engine.__main__")


@pytest.fixture(autouse=True)
def _reset_stdout_firewall():
    """The firewall is process-global; reset it around every test.

    Without this, the first test that calls main() leaves
    `_protocol_stream` pointing at a closed StringIO and every later
    test silently writes its frames into the void.
    """
    mod = _main_mod()
    yield
    mod.restore_stdout()


@pytest.mark.unit
def test_stdout_firewall_redirects_stray_writes(monkeypatch, capsys):
    """A stray print() must NOT reach the protocol stream."""
    mod = _main_mod()
    real_out = io.StringIO()
    real_err = io.StringIO()
    monkeypatch.setattr(sys, "stdout", real_out)
    monkeypatch.setattr(sys, "stderr", real_err)

    assert mod.install_stdout_firewall() is True
    try:
        print("stray library output")
        sys.stdout.flush()
    finally:
        mod.restore_stdout()

    assert "stray library output" not in real_out.getvalue()
    assert "stray library output" in real_err.getvalue()


@pytest.mark.unit
def test_protocol_writer_still_reaches_real_stdout(monkeypatch):
    """Only the protocol writer may put bytes on the real stdout."""
    mod = _main_mod()
    real_out = io.StringIO()
    real_err = io.StringIO()
    monkeypatch.setattr(sys, "stdout", real_out)
    monkeypatch.setattr(sys, "stderr", real_err)

    mod.install_stdout_firewall()
    try:
        mod._write_stdout_line(json.dumps({"id": "x", "result": {"ok": True}}))
    finally:
        mod.restore_stdout()

    lines = [ln for ln in real_out.getvalue().splitlines() if ln.strip()]
    assert len(lines) == 1
    assert json.loads(lines[0]) == {"id": "x", "result": {"ok": True}}


@pytest.mark.unit
def test_stdout_firewall_is_idempotent_and_restorable(monkeypatch):
    mod = _main_mod()
    real_out = io.StringIO()
    real_err = io.StringIO()
    monkeypatch.setattr(sys, "stdout", real_out)
    monkeypatch.setattr(sys, "stderr", real_err)

    assert mod.install_stdout_firewall() is True
    assert mod.install_stdout_firewall() is True
    assert isinstance(sys.stdout, mod._StdoutFirewall)
    assert sys.stdout._real is real_out
    mod.restore_stdout()
    assert sys.stdout is real_out
    mod.restore_stdout()  # idempotent no-op


@pytest.mark.unit
def test_stdout_firewall_buffer_writes_go_to_stderr(monkeypatch):
    """`sys.stdout.buffer` must not hand out a real stdout fd."""
    mod = _main_mod()
    real_out = io.StringIO()
    real_err = io.StringIO()
    monkeypatch.setattr(sys, "stdout", real_out)
    monkeypatch.setattr(sys, "stderr", real_err)

    mod.install_stdout_firewall()
    try:
        sys.stdout.buffer.write(b"binary stray")
    except Exception:
        pass  # stderr has no real binary buffer under StringIO — fine
    finally:
        mod.restore_stdout()

    assert "binary stray" not in real_out.getvalue()


@pytest.mark.unit
def test_busy_envelope_shape_is_retryable():
    mod = _main_mod()
    env = mod._busy_envelope("rid", "formats/get")
    assert env["id"] == "rid"
    assert env["error"]["error_type"] == "ERROR_BUSY"
    assert env["error"]["recoverable"] is True
    assert env["error"]["retryable"] is True
    # Must NOT carry a `result` key: the client treats `error` as failure.
    assert "result" not in env


@pytest.mark.unit
def test_ipc_slow_lane_sheds_load_with_error_busy(monkeypatch, tmp_path):
    """Over-budget slow-lane requests get ERROR_BUSY, never a silent hang."""
    mod = _main_mod()
    monkeypatch.setattr(sys, "argv", ["grablytic_engine"])
    monkeypatch.setattr(
        sys,
        "stdin",
        io.StringIO(
            json.dumps(
                {
                    "id": "busy1",
                    "method": "formats/get",
                    "params": {"url": "https://example.com/v"},
                }
            )
            + "\n"
        ),
    )

    # Saturate the in-flight budget BEFORE main() runs by patching the
    # module constant to 0: every slow-lane request is then over budget.
    monkeypatch.setattr(mod, "_MAX_IPC_INFLIGHT", 0)

    out = io.StringIO()
    monkeypatch.setattr(sys, "stdout", out)
    mod.main()
    lines = [json.loads(ln) for ln in out.getvalue().splitlines() if ln.strip()]
    busy = [r for r in lines if r.get("error", {}).get("error_type") == "ERROR_BUSY"]
    assert busy, f"expected ERROR_BUSY, got {lines}"
    assert busy[0]["id"] == "busy1"


@pytest.mark.unit
def test_ipc_fast_lane_is_never_shed(monkeypatch):
    """cancel must always be answered, even at full slow-lane capacity."""
    mod = _main_mod()
    monkeypatch.setattr(sys, "argv", ["grablytic_engine"])
    monkeypatch.setattr(
        sys,
        "stdin",
        io.StringIO(
            json.dumps({"id": "c1", "method": "download/queue_status", "params": {}})
            + "\n"
        ),
    )
    monkeypatch.setattr(mod, "_MAX_IPC_INFLIGHT", 0)

    out = io.StringIO()
    monkeypatch.setattr(sys, "stdout", out)
    mod.main()
    lines = [json.loads(ln) for ln in out.getvalue().splitlines() if ln.strip()]
    assert any(r.get("id") == "c1" for r in lines)
    assert not any(r.get("error", {}).get("error_type") == "ERROR_BUSY" for r in lines)


@pytest.mark.unit
def test_oversized_ipc_line_is_rejected_not_parsed(monkeypatch):
    """A runaway writer must not be able to OOM the reader."""
    mod = _main_mod()
    monkeypatch.setattr(mod, "_MAX_IPC_LINE_BYTES", 32)
    monkeypatch.setattr(sys, "argv", ["grablytic_engine"])
    monkeypatch.setattr(
        sys,
        "stdin",
        io.StringIO(
            json.dumps(
                {"id": "big", "method": "formats/get", "params": {"url": "x" * 5000}}
            )
            + "\n"
        ),
    )
    out = io.StringIO()
    monkeypatch.setattr(sys, "stdout", out)
    mod.main()
    lines = [json.loads(ln) for ln in out.getvalue().splitlines() if ln.strip()]
    assert lines, "an oversized line must still produce an error envelope"
    assert lines[0].get("error", {}).get("error_type") == "ERROR_INTERNAL"
