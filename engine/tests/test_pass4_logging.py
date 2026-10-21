"""Pass 4: the logging findings (#92, #93, #94).

* #92 — one redaction pass, applied before any sink exists: the daily
  ``engine_*.txt`` and the UI bridge used to get the raw line while only
  ``server_logs.log`` was scrubbed.
* #93 — ``server_logs.log`` stopped being a second copy of every record.
* #94 — the early gate is reachable: the file floor is INFO unless the host
  asks for DEBUG, so `_wants()` finally saves work instead of describing it.
"""

import json
import logging
import os
import queue

import pytest

from grablytic_engine import logger as logger_mod
from grablytic_engine.logger import get_logger, set_global_min_level


@pytest.fixture
def clean_logger(monkeypatch):
    """A logger pointed at a temp dir, with the module floors restored."""
    import tempfile

    previous_dir = logger_mod._global_log_dir
    previous_level = logger_mod._global_min_level
    directory = tempfile.mkdtemp()
    logger_mod.set_global_log_dir(directory)
    logger = get_logger("grablytic_engine.test_pass4")
    logger.set_queue(None)
    logger.set_event_callback(None)
    try:
        yield logger, directory
    finally:
        logger_mod.close_log_sinks()
        logger_mod.set_global_log_dir(previous_dir)
        logger_mod.set_global_min_level(previous_level)
        logger.set_queue(None)
        logger.set_event_callback(None)
        logger.set_log_dir(None)


def _files(directory, prefix="engine_"):
    return [
        os.path.join(directory, name)
        for name in os.listdir(directory)
        if name.startswith(prefix)
    ]


class _Sink:
    def __init__(self):
        self.events = []

    def onEvent(self, payload):
        self.events.append(payload)


# ── #92: redaction before the record exists ───────────────────────────────


def test_daily_file_is_redacted(clean_logger):
    logger, directory = clean_logger
    logger.warn("fetch https://x.test/w?v=1&sig=SECRET123&lsig=HUNTER2")
    logger_mod.flush_log_sinks()

    content = "".join(open(p).read() for p in _files(directory))
    assert "SECRET123" not in content
    assert "HUNTER2" not in content
    assert "***REDACTED***" in content
    assert "v=1" in content


def test_bridge_callback_is_redacted(clean_logger):
    logger, _ = clean_logger
    sink = _Sink()
    logger.set_event_callback(sink)

    logger.warn("auth token: abc123 for https://x.test/w?sig=SIGVALUE")

    payload = json.loads(sink.events[0])
    assert "abc123" not in payload["message"]
    assert "SIGVALUE" not in payload["message"]
    assert "***REDACTED***" in payload["message"]


def test_queued_event_is_redacted(clean_logger):
    logger, _ = clean_logger
    q: queue.Queue = queue.Queue()
    logger.set_queue(q)

    logger.info("proxy http://user:hunter2@proxy.test:8080 is up")

    event = q.get_nowait()
    assert "hunter2" not in event["message"]
    assert "user:***REDACTED***@" in event["message"]


def test_sensitive_context_keys_are_redacted(clean_logger):
    logger, _ = clean_logger
    q: queue.Queue = queue.Queue()
    logger.set_queue(q)

    logger.info(
        "config read",
        extra={"po_token": "abc", "nested": {"cookies": "sid=1", "ok": 2}},
    )

    event = q.get_nowait()
    assert event["extra"]["po_token"] == "***REDACTED***"
    assert event["extra"]["nested"]["cookies"] == "***REDACTED***"
    assert event["extra"]["nested"]["ok"] == 2


def test_plain_messages_are_not_rewritten(clean_logger):
    """The hint gate: text with no secret shape comes back untouched."""
    from grablytic_engine.persistent import scrub_text

    text = "downloading 42% of a very ordinary line"
    assert scrub_text(text) is text or scrub_text(text) == text


# ── #93: the second copy only takes what matters ─────────────────────────


def test_info_does_not_reach_server_logs(tmp_path):
    from grablytic_engine import persistent as persist_mod
    from grablytic_engine.persistent import (
        flush_now,
        init_persistent_logging,
        server_log_path,
    )

    previous = persist_mod._configured_dir
    try:
        init_persistent_logging(str(tmp_path))
        logger = get_logger("grablytic_engine.test_pass4_bridge")
        logger.info("routine milestone, nothing wrong")
        flush_now()
        content = (
            open(server_log_path()).read() if os.path.exists(server_log_path()) else ""
        )
        assert "routine milestone" not in content
    finally:
        persist_mod._configured_dir = previous


def test_warning_still_reaches_server_logs(tmp_path):
    from grablytic_engine import persistent as persist_mod
    from grablytic_engine.persistent import (
        flush_now,
        init_persistent_logging,
        server_log_path,
    )

    previous = (persist_mod._configured_dir, persist_mod._handler)
    try:
        init_persistent_logging(str(tmp_path))
        logger = get_logger("grablytic_engine.test_pass4_bridge2")
        logger.warn("stream fell over")
        flush_now()
        assert "stream fell over" in open(server_log_path()).read()
    finally:
        persist_mod._configured_dir = previous[0]


# ── #94: the gate can fire ───────────────────────────────────────────────


def test_debug_is_dropped_by_default(clean_logger):
    logger, directory = clean_logger
    q: queue.Queue = queue.Queue()
    logger.set_queue(q)

    logger.debug("per-block chatter")
    logger_mod.flush_log_sinks()

    assert q.empty()
    assert _files(directory) == []


def test_gate_is_cheap_when_it_fires(clean_logger):
    """The point of #94: a dropped record costs a comparison, not a build."""
    import time

    logger, _ = clean_logger
    iterations = 5000
    started = time.perf_counter()
    for _ in range(iterations):
        logger.debug("per-block chatter")
    per_record = (time.perf_counter() - started) / iterations * 1e6
    # Was 39.26 us/record when every DEBUG line was built and written.
    assert per_record < 5.0, f"{per_record:.2f} us/record"


def test_verbose_restores_debug(clean_logger):
    logger, directory = clean_logger
    set_global_min_level(logger_mod.DEBUG)
    try:
        logger.debug("chatter that was asked for")
        logger_mod.flush_log_sinks()
        content = "".join(open(p).read() for p in _files(directory))
        assert "chatter that was asked for" in content
    finally:
        set_global_min_level(logger_mod.INFO)


def test_unknown_level_leaves_the_floor_alone(clean_logger):
    from grablytic_engine.paths import _log_level_value

    assert _log_level_value("debug") == 10
    assert _log_level_value("VERBOSE") == 10
    assert _log_level_value("info") == 20
    assert _log_level_value(30) == 30
    assert _log_level_value("loud") is None
    assert _log_level_value(True) is None
    assert _log_level_value(None) is None


def test_paths_set_applies_the_host_level(tmp_path, monkeypatch):
    """`paths/set` carries the toggle: it is the one call every platform makes."""
    import grablytic_engine.paths as paths_mod

    monkeypatch.delenv("LD_LIBRARY_PATH", raising=False)
    previous = logger_mod._global_min_level
    try:
        paths_mod.set_paths(
            data_dir=str(tmp_path),
            output_dir=str(tmp_path),
            ffmpeg_path=None,
            cache_dir=str(tmp_path),
            log_level="debug",
        )
        assert logger_mod._global_min_level == logger_mod.DEBUG

        paths_mod.set_paths(
            data_dir=str(tmp_path),
            output_dir=str(tmp_path),
            ffmpeg_path=None,
            cache_dir=str(tmp_path),
            log_level="info",
        )
        assert logger_mod._global_min_level == logger_mod.INFO
    finally:
        logger_mod.set_global_min_level(previous)


def test_bridge_floor_matches_the_handler():
    """`_wants()` must know the rotating file's floor, not guess it."""
    from grablytic_engine import persistent as persist_mod

    assert persist_mod.init_persistent_logging.__defaults__[-1] == logging.WARNING
