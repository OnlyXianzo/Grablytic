"""Regressions for the third-pass performance findings (#87, #88).

Both fixes are about not doing work, which is easy to get subtly wrong in
the other direction: a gate that drops a record a sink would have taken is
a data-loss bug, and a wake flag that is never set turns an event-driven
loop back into a slow poll.
"""

import logging
import queue
import threading
import time
from datetime import datetime, timedelta, timezone

import pytest


def _logger_mod():
    import grablytic_engine.logger as logger_mod

    return logger_mod


def _hooks():
    import grablytic_engine.hooks as hooks_mod

    return hooks_mod


@pytest.fixture(autouse=True)
def _restore_logger_globals(monkeypatch):
    lm = _logger_mod()
    prev_persistent = lm._persistent_bridge_level
    prev_global_cb = lm._global_event_callback
    yield
    lm._persistent_bridge_level = prev_persistent
    lm._global_event_callback = prev_global_cb


# ── #87: the daily sink path is a per-day constant ────────────────────────


def test_daily_sink_path_is_memoised_per_day(tmp_path, monkeypatch):
    lm = _logger_mod()
    lm._sink_path_cache.clear()
    calls = {"makedirs": 0}
    real_makedirs = lm.os.makedirs

    def counting_makedirs(*a, **k):
        calls["makedirs"] += 1
        return real_makedirs(*a, **k)

    monkeypatch.setattr(lm.os, "makedirs", counting_makedirs)
    day = datetime(2026, 10, 20, 12, 0, tzinfo=timezone.utc)
    log_dir = str(tmp_path / "logs")

    first = lm._daily_sink_path(log_dir, day)
    for _ in range(50):
        assert lm._daily_sink_path(log_dir, day) == first

    assert calls["makedirs"] == 1, "the day's directory is resolved once"
    assert first.endswith("engine_2026-10-20.txt")


def test_daily_sink_path_rolls_over_at_midnight(tmp_path):
    lm = _logger_mod()
    lm._sink_path_cache.clear()
    log_dir = str(tmp_path / "logs")

    today = datetime(2026, 10, 20, 23, 59, tzinfo=timezone.utc)
    tomorrow = today + timedelta(minutes=2)

    first = lm._daily_sink_path(log_dir, today)
    second = lm._daily_sink_path(log_dir, tomorrow)

    assert first != second
    assert second.endswith("engine_2026-10-21.txt")
    # The stale key is dropped, so the cache cannot grow one entry per day.
    assert all(day == "2026-10-21" for _, day in lm._sink_path_cache)


# ── #87: the early gate must not change what any sink receives ────────────


def test_gate_drops_nothing_a_sink_would_take(tmp_path):
    lm = _logger_mod()
    log = lm.get_logger("test.pass3.sinks")
    log.set_min_level(logging.DEBUG)
    log.set_stderr_enabled(False)
    log.set_log_dir(str(tmp_path / "logs"))
    lm._persistent_bridge_level = logging.DEBUG

    log.info("kept by the file sink")
    # INFO and above are write-through; the file name depends on today's
    # date, so read whatever the sink actually created.
    created = list((tmp_path / "logs").glob("engine_*.txt"))
    assert created, "the file sink must still receive the record"
    assert "kept by the file sink" in created[0].read_text()


def test_gate_skips_building_when_every_sink_is_off(monkeypatch, tmp_path):
    lm = _logger_mod()
    log = lm.get_logger("test.pass3.off")
    log.set_min_level(logging.WARNING)
    log.set_stderr_enabled(False)
    log.set_log_dir(None)
    log.set_queue(None)
    log.set_event_callback(None)
    monkeypatch.setattr(lm, "_global_event_callback", None)
    monkeypatch.setattr(lm, "_persistent_bridge_level", None)

    built = {"dumps": 0}
    real_dumps = lm.json.dumps

    def counting_dumps(*a, **k):
        built["dumps"] += 1
        return real_dumps(*a, **k)

    monkeypatch.setattr(lm.json, "dumps", counting_dumps)

    log.debug("refused everywhere")
    log.info("also refused")

    assert built["dumps"] == 0, "no payload where no sink wants one"

    log.warning("wanted by the re-enabled stderr sink")
    # stderr is off in this test, so still nothing; re-enable and prove the
    # gate opens rather than pinning a permanently closed path.
    log.set_stderr_enabled(True)
    log.warning("wanted")
    assert built["dumps"] == 1


def test_gate_respects_the_bridge_floor(monkeypatch):
    lm = _logger_mod()
    log = lm.get_logger("test.pass3.bridge")
    log.set_min_level(logging.ERROR)
    log.set_stderr_enabled(False)
    log.set_log_dir(None)
    log.set_queue(None)
    log.set_bridge_min_level(logging.WARNING)

    delivered = []

    class _Sink:
        def onEvent(self, payload):
            delivered.append(payload)

    log.set_event_callback(_Sink())
    monkeypatch.setattr(lm, "_persistent_bridge_level", None)

    log.info("below the bridge floor")
    log.warning("at the bridge floor")

    assert len(delivered) == 1
    assert "at the bridge floor" in delivered[0]


# ── #88: event-driven drain ──────────────────────────────────────────────


def test_put_bounded_wakes_the_drain():
    lm = _logger_mod()
    hooks = _hooks()
    lm.wait_for_poll(0.0)  # clear
    q = queue.Queue(maxsize=8)

    hooks._put_bounded(q, '{"type":"event"}')

    assert lm.wait_for_poll(0.0) is True


def test_put_result_wakes_the_drain():
    lm = _logger_mod()
    hooks = _hooks()
    lm.wait_for_poll(0.0)
    q = queue.Queue(maxsize=8)

    hooks._put_result(q, {"success": True})

    assert lm.wait_for_poll(0.0) is True


def test_wait_returns_immediately_when_signalled():
    lm = _logger_mod()
    lm.wait_for_poll(0.0)
    threading.Timer(0.05, lm.notify_poll).start()

    started = time.monotonic()
    assert lm.wait_for_poll(5.0) is True
    assert time.monotonic() - started < 1.0


def test_wait_times_out_when_nothing_happens():
    lm = _logger_mod()
    lm.wait_for_poll(0.0)

    started = time.monotonic()
    assert lm.wait_for_poll(0.05) is False
    assert time.monotonic() - started >= 0.04


# ── terminal filesize survives a second consumer ─────────────────────────


def test_last_known_bytes_survives_an_empty_queue():
    """The drain thread may have emptied the queue before finish.

    That is normal (it is what the thread is for), and it used to make
    `filesize_bytes` come back as 0 for a completed download.
    """
    import grablytic_engine.downloader as dl_mod

    hooks = _hooks()
    hooks.remember_last_sample("dl-pass3", 100, "f.mp4")

    empty = queue.Queue()
    assert dl_mod._last_known_bytes(empty, "dl-pass3") == 100
    bytes_val, filename = dl_mod._last_known_file_info(empty, "dl-pass3")
    assert bytes_val == 100
    assert filename == "f.mp4"

    hooks.forget_last_sample("dl-pass3")
    assert dl_mod._last_known_bytes(queue.Queue(), "dl-pass3") == 0
