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


class _FakeYDL:
    """Minimal YoutubeDL stand-in driving hooks + logger like the real one."""

    def __init__(self, opts):
        self.opts = opts
        self.hooks = []

    def add_progress_hook(self, h):
        self.hooks.append(h)

    def download(self, urls):
        self.opts["logger"].info("fake extractor chatter")
        for ph in self.opts.get("postprocessor_hooks", []):
            ph({"status": "started", "postprocessor": "Merger"})
        hooks = list(self.hooks) + list(self.opts.get("progress_hooks", []))
        for h in hooks:
            h({
                "status": "downloading",
                "downloaded_bytes": 50,
                "total_bytes": 100,
                "speed": 10,
                "eta": 5,
                "filename": "f.mp4",
                "info_dict": {},
            })
            h({"status": "finished", "total_bytes": 100,
               "filename": "f.mp4"})


def _fake_ffmpeg(tmp_path):
    import stat
    exe = tmp_path / "ffmpeg"
    exe.write_text("#!/bin/sh\necho hi\n")
    exe.chmod(exe.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return str(exe)


class TestCallbackEndToEnd:
    """Full download_thread run with a recording callback (Android path)."""

    def test_events_logs_and_filesize_reach_callback(
        self, tmp_path, monkeypatch, _clean_bridge
    ):
        import truestream_engine.downloader as dl_mod
        import truestream_engine.paths as paths_mod

        monkeypatch.delenv("LD_LIBRARY_PATH", raising=False)
        paths_mod.set_paths(
            data_dir=str(tmp_path), output_dir=str(tmp_path),
            ffmpeg_path=_fake_ffmpeg(tmp_path), cache_dir=str(tmp_path),
        )
        monkeypatch.setattr(dl_mod, "YoutubeDL", _FakeYDL)
        sink = _Sink()
        set_global_event_callback(sink)
        prog_q: queue.Queue = queue.Queue()
        res_q: queue.Queue = queue.Queue()
        try:
            dl_mod.download_thread(
                url="https://x.test/v", download_id="e2e1",
                progress_queue=prog_q, result_queue=res_q,
                event_callback=sink,
            )
        finally:
            dl_mod._active_downloads.pop("e2e1", None)

        by_type = {}
        for raw in sink.events:
            ev = json.loads(raw)
            by_type.setdefault((ev.get("type"), ev.get("event")), []).append(ev)

        # Live progress + per-stream completion arrived via callback …
        assert ("event", "downloading") in by_type
        assert ("event", "stream_finished") in by_type
        assert ("event", "postprocessing") in by_type
        # … engine logger chatter (YDLogger) rode the same callback …
        log_evs = [json.loads(r) for r in sink.events
                   if json.loads(r).get("type") == "log"]
        assert any("fake extractor chatter" in e["message"] for e in log_evs)
        # … and the terminal finished honors the filesize contract
        # (dual-write keeps _last_known_bytes fed on the callback path).
        finished = by_type[("event", "finished")]
        assert len(finished) == 1
        assert finished[0]["filesize_bytes"] == 100
        # Callback path leaves the result queue for desktop flows.
        assert res_q.empty()


class TestBridgeSanitization:
    """SEC-02 (engine side): signed URL params never hit server_logs.log."""

    def test_bridge_event_masks_sig_before_disk(self, tmp_path):
        from truestream_engine import persistent as persist_mod
        from truestream_engine.persistent import (
            init_persistent_logging,
            bridge_event,
            server_log_path,
            flush_now,
        )
        import logging

        prev_dir = persist_mod._configured_dir
        try:
            init_persistent_logging(str(tmp_path))
            bridge_event(
                logging.INFO,
                "fetch https://x.test/watch?v=abc&sig=SECRET123&lsig=HUNTER2",
            )
            flush_now()
            content = open(server_log_path()).read()
            assert "SECRET123" not in content
            assert "HUNTER2" not in content
            assert "***REDACTED***" in content
            assert "v=abc" in content
        finally:
            persist_mod._configured_dir = prev_dir

    def test_bridge_event_uninitialized_is_silent(self):
        from truestream_engine import persistent as persist_mod
        from truestream_engine.persistent import bridge_event
        import logging

        prev = (persist_mod._configured_dir, persist_mod._std_logger,
                persist_mod._handler)
        persist_mod._configured_dir = None
        persist_mod._std_logger = None
        persist_mod._handler = None
        try:
            bridge_event(logging.ERROR, "no handler configured")
        finally:
            (persist_mod._configured_dir, persist_mod._std_logger,
             persist_mod._handler) = prev


class _SystemExitYDL(_FakeYDL):
    def download(self, urls):
        raise SystemExit(3)


class TestDownloaderCrashGuard:
    """BaseException (SystemExit/GeneratorExit) must still emit terminal."""

    def _run(self, tmp_path, monkeypatch, ydl_cls, did):
        import truestream_engine.downloader as dl_mod
        import truestream_engine.paths as paths_mod

        monkeypatch.delenv("LD_LIBRARY_PATH", raising=False)
        paths_mod.set_paths(
            data_dir=str(tmp_path), output_dir=str(tmp_path),
            ffmpeg_path=_fake_ffmpeg(tmp_path), cache_dir=str(tmp_path),
        )
        monkeypatch.setattr(dl_mod, "YoutubeDL", ydl_cls)
        sink = _Sink()
        set_global_event_callback(sink)
        prog_q: queue.Queue = queue.Queue()
        res_q: queue.Queue = queue.Queue()
        try:
            dl_mod.download_thread(
                url="https://x.test/watch?v=abc&sig=SECRET999",
                download_id=did,
                progress_queue=prog_q, result_queue=res_q,
                event_callback=sink,
            )
        finally:
            dl_mod._active_downloads.pop(did, None)
        return sink

    def test_system_exit_becomes_error_event(
        self, tmp_path, monkeypatch, _clean_bridge
    ):
        sink = self._run(tmp_path, monkeypatch, _SystemExitYDL, "crasher1")
        errs = [json.loads(r) for r in sink.events
                if json.loads(r).get("event") == "error"]
        assert len(errs) == 1
        assert errs[0]["error_type"] == "ERROR_DOWNLOADER_CRASH"
        assert errs[0]["recoverable"] is True

    def test_started_and_config_lines_hide_query(
        self, tmp_path, monkeypatch, _clean_bridge
    ):
        sink = self._run(tmp_path, monkeypatch, _FakeYDL, "leakcheck1")
        logs = [json.loads(r)["message"] for r in sink.events
                if json.loads(r).get("type") == "log"]
        assert any("Download started: https://x.test/watch" in m for m in logs)
        assert not any("SECRET999" in m for m in logs)
        assert not any("sig=" in m for m in logs)
        assert any(m.startswith("Download config: format=") for m in logs)
