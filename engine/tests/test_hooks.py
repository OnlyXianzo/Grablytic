"""Progress/postprocessor hook event contracts.

The progress hook's status="finished" is PER-FILE (one DASH stream), never
terminal: it must surface as `stream_finished`. Only the downloader's
terminal event (`finished`, via result queue / event callback) completes.
"""

import json
import queue

import pytest

from grablytic_engine.hooks import (
    build_postprocessor_hook,
    build_progress_hook,
)


def _drain(q):
    items = []
    while not q.empty():
        items.append(json.loads(q.get_nowait()))
    return items


class TestProgressHook:
    @pytest.mark.unit
    def test_finished_is_stream_finished(self):
        q: queue.Queue = queue.Queue()
        hook = build_progress_hook(q, "d1")
        hook({"status": "finished", "filename": "v.f137.mp4",
              "total_bytes": 1000})
        (ev,) = _drain(q)
        assert ev["event"] == "stream_finished"
        assert ev["download_id"] == "d1"
        assert ev["filesize_bytes"] == 1000
        assert ev["total_bytes"] == 1000
        assert ev["filename"] == "v.f137.mp4"

    @pytest.mark.unit
    def test_finished_falls_back_to_estimate(self):
        q: queue.Queue = queue.Queue()
        hook = build_progress_hook(q, "d1")
        hook({"status": "finished", "filename": "v.mp4",
              "total_bytes": None, "total_bytes_estimate": 250})
        (ev,) = _drain(q)
        assert ev["event"] == "stream_finished"
        assert ev["filesize_bytes"] == 250

    @pytest.mark.unit
    def test_downloading_passthrough(self):
        q: queue.Queue = queue.Queue()
        hook = build_progress_hook(q, "d1")
        hook({"status": "downloading", "downloaded_bytes": 5,
              "total_bytes": 10, "speed": 1, "eta": 5, "filename": "v.mp4"})
        (ev,) = _drain(q)
        assert ev["event"] == "downloading"
        assert ev["downloaded_bytes"] == 5
        assert ev["total_bytes"] == 10

    @pytest.mark.unit
    def test_unknown_status_ignored(self):
        q: queue.Queue = queue.Queue()
        hook = build_progress_hook(q, "d1")
        hook({"status": "idle"})
        assert q.empty()

    @pytest.mark.unit
    def test_event_callback_path(self):
        seen = []
        hook = build_progress_hook(
            queue.Queue(), "d1",
            event_callback=type("CB", (), {
                "onEvent": staticmethod(seen.append)})(),
        )
        hook({"status": "finished", "filename": "v.mp4", "total_bytes": 7})
        assert json.loads(seen[0])["event"] == "stream_finished"


class TestPostprocessorHook:
    @pytest.mark.unit
    def test_merger_stage_resolved(self):
        q: queue.Queue = queue.Queue()
        hook = build_postprocessor_hook(q, "d1")
        hook({"status": "started", "postprocessor": "Merger"})
        (ev,) = _drain(q)
        assert ev["event"] == "postprocessing"
        assert ev["stage"] == "merging"

    @pytest.mark.unit
    def test_unknown_pp_falls_back_to_key(self):
        q: queue.Queue = queue.Queue()
        hook = build_postprocessor_hook(q, "d1")
        hook({"status": "started", "postprocessor": "SomethingNew"})
        (ev,) = _drain(q)
        assert ev["stage"] == "SomethingNew"

    @pytest.mark.unit
    def test_non_started_ignored(self):
        q: queue.Queue = queue.Queue()
        hook = build_postprocessor_hook(q, "d1")
        hook({"status": "finished", "postprocessor": "Merger"})
        assert q.empty()


class TestProgressSampler:
    @pytest.mark.unit
    def test_rapid_same_pct_ticks_coalesced_to_one(self):
        q: queue.Queue = queue.Queue()
        hook = build_progress_hook(q, "d1")
        for b in (500, 501, 502, 503):
            hook({"status": "downloading", "downloaded_bytes": b,
                  "total_bytes": 1000, "info_dict": {}})
        assert len(_drain(q)) == 1

    @pytest.mark.unit
    def test_pct_jump_emits_despite_time_gate(self):
        q: queue.Queue = queue.Queue()
        hook = build_progress_hook(q, "d1")
        hook({"status": "downloading", "downloaded_bytes": 100,
              "total_bytes": 1000, "info_dict": {}})
        hook({"status": "downloading", "downloaded_bytes": 300,
              "total_bytes": 1000, "info_dict": {}})
        evs = _drain(q)
        assert len(evs) == 2
        assert evs[-1]["downloaded_bytes"] == 300

    @pytest.mark.unit
    def test_terminal_events_always_pass_through(self):
        q: queue.Queue = queue.Queue()
        hook = build_progress_hook(q, "d1")
        hook({"status": "finished", "filename": "a.mp4", "total_bytes": 9})
        hook({"status": "finished", "filename": "b.mp4", "total_bytes": 9})
        assert len(_drain(q)) == 2

    @pytest.mark.unit
    def test_put_bounded_evicts_oldest_never_blocks(self):
        from grablytic_engine.hooks import _put_bounded
        q: queue.Queue = queue.Queue(maxsize=2)
        _put_bounded(q, "e1")
        _put_bounded(q, "e2")
        _put_bounded(q, "e3")  # must not block or raise
        assert q.get_nowait() == "e2"
        assert q.get_nowait() == "e3"
        assert q.empty()
