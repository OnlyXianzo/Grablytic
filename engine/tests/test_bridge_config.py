"""Config coercion across the Kotlin/Python bridge (HashMap crash)."""

import json

import pytest

from grablytic_engine.config import coerce_config, DEFAULT_CFG


class FakeHashMapProxy:
    """Mimics a Chaquopy java.util.HashMap proxy: .get() works (Java
    method dispatch) but it is NOT a mapping — ``{**proxy}`` raises the
    exact TypeError seen on-device."""

    def __init__(self, data):
        self._data = dict(data)

    def get(self, key, default=None):
        return self._data.get(key, default)

    def __or__(self, other):
        raise TypeError("'HashMap' object is not a mapping")


class TestCoerceConfig:
    @pytest.mark.unit
    def test_none_and_dict(self):
        assert coerce_config(None) == {}
        d = {"a": 1}
        assert coerce_config(d) is d

    @pytest.mark.unit
    def test_json_string(self):
        cfg = {"container": "mp4", "sponsorblock_cats": ["sponsor"]}
        assert coerce_config(json.dumps(cfg)) == cfg

    @pytest.mark.unit
    def test_garbage_string_fails_closed(self):
        assert coerce_config("{nope") == {}
        assert coerce_config("[1,2]") == {}

    @pytest.mark.unit
    def test_proxy_fails_closed(self):
        assert coerce_config(FakeHashMapProxy({"a": 1})) == {}

    @pytest.mark.unit
    def test_proxy_reproduces_on_device_crash(self):
        # Without coercion this is the exact on-device TypeError.
        with pytest.raises(TypeError):
            {**DEFAULT_CFG, **(FakeHashMapProxy({"a": 1}) or {})}

    @pytest.mark.unit
    def test_opts_builder_accepts_string_config(self, tmp_path, monkeypatch):
        import os
        import shutil
        from grablytic_engine import paths as paths_mod
        from grablytic_engine.opts_builder import build_ydl_opts

        monkeypatch.delenv("LD_LIBRARY_PATH", raising=False)
        monkeypatch.setattr(
            os.path, "isfile", lambda p: True if p == "/usr/bin/ffmpeg" else False)
        monkeypatch.setattr(shutil, "which", lambda *a, **k: None)
        paths_mod._paths.update({
            "data_dir": str(tmp_path), "output_dir": str(tmp_path),
            "ffmpeg_path": "/usr/bin/ffmpeg", "cache_dir": str(tmp_path),
            "deno_path": None, "aria2c_path": None,
        })
        try:
            opts = build_ydl_opts(
                config=json.dumps({"audio_only": True}))
            pps = opts.get("postprocessors", [])
            assert any(pp.get("key") == "FFmpegExtractAudio"
                       and pp.get("preferredcodec") == "opus" for pp in pps)
        finally:
            paths_mod._paths.update({
                "data_dir": None, "output_dir": None, "ffmpeg_path": None,
                "cache_dir": None, "deno_path": None, "aria2c_path": None,
            })


class TestStringConfigEndToEnd:
    """Full download_thread run with a JSON-string config (Android path)."""

    @pytest.mark.unit
    def test_string_config_download_succeeds(
        self, tmp_path, monkeypatch
    ):
        import queue
        import stat
        import grablytic_engine.downloader as dl_mod
        import grablytic_engine.paths as paths_mod
        from grablytic_engine.logger import set_global_event_callback

        class _Sink:
            def __init__(self):
                self.events = []

            def onEvent(self, payload):
                self.events.append(payload)

        class _FakeYDL:
            def __init__(self, opts):
                self.opts = opts
                self.hooks = []

            def add_progress_hook(self, h):
                self.hooks.append(h)

            def download(self, urls):
                for h in list(self.hooks) + list(
                        self.opts.get("progress_hooks", [])):
                    h({"status": "downloading", "downloaded_bytes": 10,
                       "total_bytes": 10, "filename": "f.mp4",
                       "info_dict": {}})

        monkeypatch.delenv("LD_LIBRARY_PATH", raising=False)
        exe = tmp_path / "ffmpeg"
        exe.write_text("#!/bin/sh\necho hi\n")
        exe.chmod(exe.stat().st_mode | stat.S_IXUSR)
        paths_mod.set_paths(
            data_dir=str(tmp_path), output_dir=str(tmp_path),
            ffmpeg_path=str(exe), cache_dir=str(tmp_path),
        )
        monkeypatch.setattr(dl_mod, "YoutubeDL", _FakeYDL)
        sink = _Sink()
        set_global_event_callback(sink)
        prog_q: queue.Queue = queue.Queue()
        res_q: queue.Queue = queue.Queue()
        try:
            dl_mod.download_thread(
                url="https://x.test/v", download_id="jsoncfg1",
                config=json.dumps({"container": "mp4"}),
                progress_queue=prog_q, result_queue=res_q,
                event_callback=sink,
            )
        finally:
            dl_mod._active_downloads.pop("jsoncfg1", None)
            set_global_event_callback(None)
        finished = [json.loads(r) for r in sink.events
                    if json.loads(r).get("event") == "finished"]
        assert len(finished) == 1
