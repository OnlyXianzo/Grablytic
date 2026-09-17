"""Item 3 HEAD-OF-LINE blocking regression (RED-first).

A single slow `formats/get` (or playlist extraction) must not hold
`download/cancel` / `download/queue_status` hostage until Dart's 30s
`_requestTimeout` fires. The engine stdin loop must dispatch requests
concurrently (per-request workers, stdout serialized by id) with a
cancel short-circuit, keeping the envelope contract byte-identical.
"""

import io
import json
import sys
import time


def _main_mod():
    import importlib
    return importlib.import_module("grablytic_engine.__main__")


def _by_id(responses, req_id):
    return next(r for r in responses if r.get("id") == req_id)


def test_slow_formats_does_not_head_of_line_block_cancel(monkeypatch, capsys):
    """RED: slow formats/get followed by cancel must answer cancel promptly.

    Feeds both lines up-front (OS pipe already holds both). Old code runs
    `for line in sys.stdin` with synchronous dispatch, so cancel waits the
    full ~2s extraction. Fixed code answers cancel in <1s while the slow
    request is still in flight, preserving both request ids.
    """
    import pytest
    pytest.importorskip("pytest")
    mod = _main_mod()

    def slow_get_formats(url, config=None):
        time.sleep(2.0)
        return {"success": True, "formats": []}

    def fast_cancel(download_id):
        return {"success": True, "download_id": download_id, "cancelled": True}

    monkeypatch.setattr(mod, "get_formats", slow_get_formats)
    monkeypatch.setattr(mod, "cancel_download", fast_cancel)

    orig_write = mod._write_stdout_line
    timings: dict = {}

    def timed_write(s):
        try:
            obj = json.loads(s if s.endswith("\n") else s + "\n")
            rid = obj.get("id")
            if isinstance(rid, str):
                timings.setdefault(rid, time.monotonic())
        except Exception:
            pass
        return orig_write(s)

    monkeypatch.setattr(mod, "_write_stdout_line", timed_write)

    monkeypatch.setattr(
        sys, "argv", ["grablytic_engine"],
    )
    monkeypatch.setattr(
        sys,
        "stdin",
        io.StringIO(
            "\n".join([
                json.dumps({"id": "slow1", "method": "formats/get",
                            "params": {"url": "https://x.test/v"}}),
                json.dumps({"id": "cancel1", "method": "download/cancel",
                            "params": {"download_id": "dl1"}}),
            ])
            + "\n"
        ),
    )
    start = time.monotonic()
    mod.main()
    out, _ = capsys.readouterr()
    resps = [json.loads(line) for line in out.splitlines() if line.strip()]

    # Envelope contract byte-identical: both ids answered.
    assert _by_id(resps, "slow1")["result"] == {"success": True, "formats": []}
    assert _by_id(resps, "cancel1")["result"]["success"] is True
    assert "slow1" in timings and "cancel1" in timings

    cancel_latency = timings["cancel1"] - start
    assert cancel_latency < 1.0, (
        f"HEAD-OF-LINE BLOCK: cancel answered after {cancel_latency:.2f}s "
        "behind slow formats/get (must be <1.0s)"
    )
    assert timings["cancel1"] < timings["slow1"], (
        "cancel must respond before the slow formats/get completes"
    )
