"""Regression tests for the second-pass (2026-10-20) findings.

Each test here failed before its fix:

* N2/#63 — the stderr mirror printed every record before the level gate,
  so the desktop host (which wraps engine stderr in `AppLogger.warn`)
  promoted DEBUG to WARNING and `set_min_level` suppressed nothing.
* N7/#68 — `EngineLogger` exposed `warn` but not `warning`, the spelling
  used by stdlib logging and by the yt-dlp adapter in `downloader.py`, so
  a `log.warning(...)` inside an except block raised AttributeError.
* N10/#71 — the inline (reader-thread) lane claimed it could never
  block; a slow inline call now leaves a diagnosable warning instead of
  silently delaying every later request.
"""

import json
import time

import pytest


def _logger():
    from grablytic_engine.logger import get_logger

    return get_logger


# ── #63: the stderr mirror obeys the level gate ────────────────────────


@pytest.mark.unit
def test_stderr_mirror_is_gated_by_min_level(capsys):
    """A DEBUG record must not reach stderr when the floor is WARN."""
    get_logger = _logger()
    log = get_logger("grablytic_engine.test_gate")
    log.set_stderr_enabled(True)
    old_level = log._min_level
    try:
        log.set_min_level(30)  # WARN
        log.debug("debug-must-not-print")
        log.warn("warn-must-print")
    finally:
        log.set_min_level(old_level)

    err = capsys.readouterr().err
    assert "debug-must-not-print" not in err
    assert "warn-must-print" in err


@pytest.mark.unit
def test_stderr_mirror_can_be_disabled_entirely(capsys):
    """With the mirror off, nothing is written to stderr at any level."""
    get_logger = _logger()
    log = get_logger("grablytic_engine.test_gate_off")
    log.set_stderr_enabled(False)
    try:
        log.error("error-must-not-print")
    finally:
        log.set_stderr_enabled(bool(getattr(log, "_stderr_enabled", False)))

    assert "error-must-not-print" not in capsys.readouterr().err


@pytest.mark.unit
@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("1", True),
        ("true", True),
        ("0", False),
        ("off", False),
    ],
)
def test_stderr_mirror_default_honours_the_env_override(monkeypatch, value, expected):
    from grablytic_engine import logger as logger_mod

    monkeypatch.setenv("GRABLYTIC_LOG_STDERR", value)
    assert logger_mod._default_stderr_mirror() is expected


@pytest.mark.unit
def test_stderr_mirror_default_is_off_when_not_a_tty(monkeypatch):
    """A piped stderr is the desktop transport: off unless overridden."""
    import io

    from grablytic_engine import logger as logger_mod

    monkeypatch.delenv("GRABLYTIC_LOG_STDERR", raising=False)
    monkeypatch.setattr(logger_mod.sys, "stderr", io.StringIO())
    assert logger_mod._default_stderr_mirror() is False


@pytest.mark.unit
def test_one_serialization_feeds_file_queue_and_bridge(monkeypatch, tmp_path):
    """The file, the queue and the bridge carry byte-identical records."""
    get_logger = _logger()
    log = get_logger("grablytic_engine.test_one_payload")
    seen: list[str] = []

    class _Cb:
        def onEvent(self, payload):  # noqa: N802 - Chaquopy callback name
            seen.append(payload)

    import queue as queue_mod

    q: queue_mod.Queue = queue_mod.Queue()
    log.set_queue(q)
    log.set_event_callback(_Cb())
    log.set_bridge_min_level(10)
    log.set_log_dir(str(tmp_path))
    try:
        log.info("payload-shape")
    finally:
        log.set_queue(None)
        log.set_event_callback(None)
        log.set_log_dir("")  # type: ignore[arg-type]

    queued = q.get_nowait()
    assert seen, "the bridge callback never fired"
    assert json.loads(seen[0]) == queued

    from pathlib import Path

    files = sorted(Path(tmp_path).glob("engine_*.txt"))
    assert files, "no daily log file was written"
    last = files[-1].read_text(encoding="utf-8").strip().splitlines()[-1]
    assert json.loads(last) == queued


# ── #68: stdlib-compatible warning() alias ─────────────────────────────


@pytest.mark.unit
def test_engine_logger_exposes_warning_alias():
    """`warning` must exist, or an except block using it raises instead."""
    from grablytic_engine.logger import EngineLogger

    assert hasattr(EngineLogger, "warning")
    assert callable(getattr(EngineLogger, "warning"))


@pytest.mark.unit
def test_warning_alias_writes_a_warn_record():
    get_logger = _logger()
    log = get_logger("grablytic_engine.test_warning_alias")

    import queue as queue_mod

    q: queue_mod.Queue = queue_mod.Queue()
    log.set_queue(q)
    log.set_stderr_enabled(False)
    try:
        log.warning("alias-spelling")
    finally:
        log.set_queue(None)

    record = q.get_nowait()
    assert record["level"] == "WARN"
    assert record["message"] == "alias-spelling"


# ── #71: the inline lane reports over-budget calls ─────────────────────


@pytest.mark.unit
def test_inline_lane_logs_when_it_overruns_its_budget(monkeypatch):
    """A slow inline method leaves a trace instead of silently stalling."""
    import importlib

    mod = importlib.import_module("grablytic_engine.__main__")
    warnings: list[str] = []

    def slow_execute(req_id, method, params):
        time.sleep(0.30)

    monkeypatch.setattr(mod, "_execute_parsed_request", slow_execute)
    monkeypatch.setattr(mod.log, "warn", lambda msg, **kw: warnings.append(msg))

    mod._run_inline("req-1", "download/cancel", {})

    assert any("download/cancel" in w and "held the reader" in w for w in warnings)


@pytest.mark.unit
def test_inline_lane_is_quiet_under_budget(monkeypatch):
    import importlib

    mod = importlib.import_module("grablytic_engine.__main__")
    warnings: list[str] = []

    monkeypatch.setattr(mod, "_execute_parsed_request", lambda *a, **kw: None)
    monkeypatch.setattr(mod.log, "warn", lambda msg, **kw: warnings.append(msg))

    mod._run_inline("req-2", "download/queue_status", {})

    assert warnings == []
