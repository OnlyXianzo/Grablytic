"""Item-2 effect proof: lowering the limit via set_max_concurrent makes
excess downloads queue rather than run (the Settings slider effect on
Android rides this same engine backstop through the new Chaquopy
handlers, which call these exact functions).
"""

import grablytic_engine.downloader as dl_mod


def _reset():
    dl_mod._active_downloads.clear()
    dl_mod._pending_queue.clear()
    dl_mod.set_max_concurrent(2)


class _NoopThread:
    def __init__(self, *args, **kwargs):
        pass

    def start(self):
        pass


def test_set_limit_1_second_download_queues(monkeypatch):
    _reset()
    monkeypatch.setattr(dl_mod.threading, "Thread", _NoopThread)
    try:
        res = dl_mod.set_max_concurrent(1)
        assert res == {"success": True, "max_concurrent": 1}
        r1 = dl_mod.start_download(url="https://x.test/1", download_id="c-eff-1")
        assert r1["success"] is True and r1.get("queued") is not True
        r2 = dl_mod.start_download(url="https://x.test/2", download_id="c-eff-2")
        assert r2["success"] is True
        assert r2.get("queued") is True
        assert r2.get("position") == 1
        status = dl_mod.get_queue_status()
        assert status["max_concurrent"] == 1
        assert status["active"] == ["c-eff-1"]
        assert status["queued"] == ["c-eff-2"]
    finally:
        for did in ("c-eff-1", "c-eff-2"):
            dl_mod._active_downloads.pop(did, None)
        dl_mod._pending_queue.clear()
        dl_mod.set_max_concurrent(2)


def test_queue_status_shape_matches_dart_contract(monkeypatch):
    """get_queue_status keys must match what EngineService.queueStatus
    documents: {success, active, queued, max_concurrent}."""
    _reset()
    monkeypatch.setattr(dl_mod.threading, "Thread", _NoopThread)
    try:
        dl_mod.start_download(url="https://x.test/1", download_id="c-shape-1")
        status = dl_mod.get_queue_status()
        assert set(status.keys()) == {"success", "active", "queued", "max_concurrent"}
        assert status["success"] is True
        assert status["active"] == ["c-shape-1"]
    finally:
        dl_mod._active_downloads.pop("c-shape-1", None)
        dl_mod.set_max_concurrent(2)
