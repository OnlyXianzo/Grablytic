"""Finding #71: filesystem mutators must not run on the stdin reader.

`paths/set` and `download/clear_archive` touch the filesystem. Running them
inline meant a stall (FUSE mount, adopted storage, a sleeping SD card) also
stopped the reader from reading the next line — including a cancel. They now
run on a single-threaded maintenance lane, while the ordering invariant they
were inline for ("no download is admitted against unmapped paths") is kept by
making later slow-lane requests wait for the maintenance work that preceded
them.
"""

import threading
import time
from concurrent.futures import ThreadPoolExecutor

from grablytic_engine import __main__ as engine_main


def _dispatch(line, pool, maintenance, inflight, futures):
    engine_main._process_ipc_line(line, pool, inflight, futures, maintenance)


class _Recorded:
    def __init__(self):
        self.order = []
        self.threads = {}
        self.lock = threading.Lock()

    def handler(self, req_id, method, params):
        with self.lock:
            self.order.append(("start", method))
            self.threads[method] = threading.current_thread().name
        if method == "paths/set":
            time.sleep(0.2)
        with self.lock:
            self.order.append(("end", method))


def test_filesystem_mutators_are_off_the_inline_lane():
    assert "paths/set" not in engine_main._FAST_IPC_METHODS
    assert "download/clear_archive" not in engine_main._FAST_IPC_METHODS
    assert engine_main._MAINTENANCE_METHODS == {
        "paths/set",
        "download/clear_archive",
    }
    # The in-memory, order-critical trio stays inline.
    assert engine_main._FAST_IPC_METHODS == {
        "download/cancel",
        "download/queue_status",
        "download/set_concurrency",
    }


def test_paths_set_runs_on_the_maintenance_thread(monkeypatch):
    recorder = _Recorded()
    monkeypatch.setattr(engine_main, "_execute_parsed_request", recorder.handler)
    monkeypatch.setattr(engine_main, "_maintenance_tail", None)

    inflight = threading.BoundedSemaphore(4)
    futures = set()
    with (
        ThreadPoolExecutor(max_workers=2, thread_name_prefix="ipc") as pool,
        ThreadPoolExecutor(max_workers=1, thread_name_prefix="engine-maintenance") as maintenance,
    ):
        _dispatch('{"id":"1","method":"paths/set","params":{}}', pool, maintenance, inflight, futures)
        engine_main._maintenance_tail.result(timeout=5)

    assert recorder.threads["paths/set"].startswith("engine-maintenance")


def test_reader_thread_still_runs_the_fast_lane(monkeypatch):
    recorder = _Recorded()
    monkeypatch.setattr(engine_main, "_execute_parsed_request", recorder.handler)

    inflight = threading.BoundedSemaphore(4)
    with (
        ThreadPoolExecutor(max_workers=2, thread_name_prefix="ipc") as pool,
        ThreadPoolExecutor(max_workers=1, thread_name_prefix="engine-maintenance") as maintenance,
    ):
        _dispatch('{"id":"1","method":"download/cancel","params":{}}', pool, maintenance, inflight, set())

    assert recorder.threads["download/cancel"] == threading.current_thread().name


def test_slow_lane_waits_for_preceding_maintenance_work(monkeypatch):
    recorder = _Recorded()
    monkeypatch.setattr(engine_main, "_execute_parsed_request", recorder.handler)
    monkeypatch.setattr(engine_main, "_maintenance_tail", None)

    inflight = threading.BoundedSemaphore(8)
    futures = set()
    with (
        ThreadPoolExecutor(max_workers=2, thread_name_prefix="ipc") as pool,
        ThreadPoolExecutor(max_workers=1, thread_name_prefix="engine-maintenance") as maintenance,
    ):
        # paths/set sleeps 200 ms; the download submitted right after it
        # must not be admitted until it has finished.
        _dispatch('{"id":"1","method":"paths/set","params":{}}', pool, maintenance, inflight, futures)
        _dispatch(
            '{"id":"2","method":"download/start","params":{}}',
            pool,
            maintenance,
            inflight,
            futures,
        )
        for fut in list(futures):
            fut.result(timeout=10)

    order = [entry for entry in recorder.order]
    assert order.index(("end", "paths/set")) < order.index(("start", "download/start"))


def test_maintenance_lane_is_fifo(monkeypatch):
    recorder = _Recorded()
    monkeypatch.setattr(engine_main, "_execute_parsed_request", recorder.handler)
    monkeypatch.setattr(engine_main, "_maintenance_tail", None)

    inflight = threading.BoundedSemaphore(8)
    futures = set()
    with (
        ThreadPoolExecutor(max_workers=2, thread_name_prefix="ipc") as pool,
        ThreadPoolExecutor(max_workers=1, thread_name_prefix="engine-maintenance") as maintenance,
    ):
        _dispatch('{"id":"1","method":"paths/set","params":{}}', pool, maintenance, inflight, futures)
        _dispatch(
            '{"id":"2","method":"download/clear_archive","params":{}}',
            pool,
            maintenance,
            inflight,
            futures,
        )
        for fut in list(futures):
            fut.result(timeout=10)

    assert recorder.order == [
        ("start", "paths/set"),
        ("end", "paths/set"),
        ("start", "download/clear_archive"),
        ("end", "download/clear_archive"),
    ]
