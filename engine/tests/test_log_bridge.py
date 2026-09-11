"""Engine-log push bridge (Android/Chaquopy) + set_paths logging init."""

import json
import os
import queue

import pytest

import truestream_engine.logger as logger_mod
from truestream_engine.logger import (
    get_logger,
    set_global_event_callback,
)


class _Sink:
    def __init__(self, fail=False):
        self.events = []
        self.fail = fail

    def onEvent(self, payload):
        if self.fail:
            raise RuntimeError("sink gone")
        self.events.append(payload)


@pytest.fixture()
def _clean_bridge():
    prev_cb = logger_mod._global_event_callback
    prev_dir = logger_mod._global_log_dir
    set_global_event_callback(None)
    for lg in logger_mod._loggers.values():
        lg.set_event_callback(None)
        lg.set_queue(None)
        lg.set_log_dir(None)
    yield
    set_global_event_callback(None)
    for lg in logger_mod._loggers.values():
        lg.set_event_callback(None)
        lg.set_queue(None)
        lg.set_log_dir(None)
    logger_mod._global_event_callback = prev_cb
    logger_mod._global_log_dir = prev_dir
    for lg in logger_mod._loggers.values():
        if prev_dir is not None:
            lg.set_log_dir(prev_dir)


def test_log_forwarded_to_callback_as_json(_clean_bridge):
    sink = _Sink()
    set_global_event_callback(sink)
    log = get_logger("truestream_engine.test_bridge_new")
    log.info("hello bridge")
    assert len(sink.events) == 1
    ev = json.loads(sink.events[0])
    assert ev["type"] == "log"
    assert ev["level"] == "INFO"
    assert ev["message"] == "hello bridge"
    assert ev["logger"] == "truestream_engine.test_bridge_new"


def test_logger_created_after_setter_inherits_callback(_clean_bridge):
    sink = _Sink()
    set_global_event_callback(sink)
    log = get_logger("truestream_engine.test_bridge_late")
    log.warn("late hello")
    assert len(sink.events) == 1
    assert json.loads(sink.events[0])["level"] == "WARN"


def test_no_callback_no_crash(_clean_bridge):
    log = get_logger("truestream_engine.test_bridge_none")
    log.info("nowhere to go")  # must not raise
    log.error("still fine")


def test_raising_callback_is_swallowed(_clean_bridge):
    sink = _Sink(fail=True)
    set_global_event_callback(sink)
    log = get_logger("truestream_engine.test_bridge_boom")
    log.error("sink exploded")  # logging must never break the caller


def test_queue_path_still_works_alongside_callback(_clean_bridge):
    q: queue.Queue = queue.Queue()
    sink = _Sink()
    set_global_event_callback(sink)
    log = get_logger("truestream_engine.test_bridge_both")
    log.set_queue(q)
    log.info("both channels")
    assert len(sink.events) == 1
    assert q.get_nowait()["message"] == "both channels"


def test_set_paths_initializes_file_logging(tmp_path, monkeypatch, _clean_bridge):
    import truestream_engine.paths as paths_mod

    monkeypatch.delenv("LD_LIBRARY_PATH", raising=False)
    data_dir = str(tmp_path / "data")
    os.makedirs(data_dir, exist_ok=True)
    paths_mod.set_paths(
        data_dir=data_dir, output_dir=data_dir,
        ffmpeg_path=None, cache_dir=data_dir,
    )
    # Daily JSONL file logging is armed …
    log = get_logger("truestream_engine.test_bridge_paths")
    log.info("paths armed logging")
    day_files = [f for f in os.listdir(os.path.join(data_dir, "logs"))
                 if f.startswith("engine_")]
    assert day_files, "set_paths must configure the engine log dir"
    # … and so is the rotating server log.
    from truestream_engine.persistent import server_log_path
    assert server_log_path() is not None
    assert os.path.isfile(server_log_path())


def test_start_download_wires_callback(monkeypatch):
    import truestream_engine.downloader as dl_mod

    seen = {}

    def _fake_setter(cb):
        seen["cb"] = cb

    class _FakeThread:
        def __init__(self, *args, **kwargs):
            pass

        def start(self):
            pass

    monkeypatch.setattr(dl_mod, "set_global_event_callback", _fake_setter)
    monkeypatch.setattr(dl_mod.threading, "Thread", _FakeThread)
    cb = _Sink()
    try:
        dl_mod.start_download(
            url="https://x.test/v", download_id="wire1",
            event_callback=cb,
        )
    finally:
        dl_mod._active_downloads.pop("wire1", None)
    assert seen.get("cb") is cb


def test_start_download_without_callback_does_not_wire(monkeypatch):
    import truestream_engine.downloader as dl_mod

    calls = []

    def _fake_setter(cb):
        calls.append(cb)

    class _FakeThread:
        def __init__(self, *args, **kwargs):
            pass

        def start(self):
            pass

    monkeypatch.setattr(dl_mod, "set_global_event_callback", _fake_setter)
    monkeypatch.setattr(dl_mod.threading, "Thread", _FakeThread)
    try:
        dl_mod.start_download(url="https://x.test/v", download_id="wire2")
    finally:
        dl_mod._active_downloads.pop("wire2", None)
    assert calls == []
