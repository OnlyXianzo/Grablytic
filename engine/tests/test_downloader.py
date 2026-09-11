"""Downloader thread timestamps (aware UTC) and error enrichment."""

import queue
import stat
from datetime import timezone

import pytest

import truestream_engine.downloader as dl_mod
from truestream_engine.paths import set_paths


def _fake_ffmpeg(tmp_path):
    exe = tmp_path / "ffmpeg"
    exe.write_text("#!/bin/sh\necho 'ffmpeg version test'\n")
    exe.chmod(exe.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return str(exe)


@pytest.fixture()
def _env(tmp_path, monkeypatch):
    import truestream_engine.paths as paths_mod
    monkeypatch.delenv("LD_LIBRARY_PATH", raising=False)
    set_paths(
        data_dir=str(tmp_path), output_dir=str(tmp_path),
        ffmpeg_path=_fake_ffmpeg(tmp_path), cache_dir=str(tmp_path),
    )
    yield
    dl_mod._active_downloads.clear()


def _boom(*args, **kwargs):
    raise RuntimeError("not available in your country")


class TestAwareTimestamps:
    @pytest.mark.unit
    def test_started_and_finished_are_aware_utc(self, _env, monkeypatch):
        monkeypatch.setattr(dl_mod, "YoutubeDL", _boom)
        res_q: queue.Queue = queue.Queue()
        dl_mod.download_thread(
            url="https://x.test/v", download_id="aware1",
            result_queue=res_q,
        )
        res = res_q.get(timeout=10)
        assert res["success"] is False
        info = dl_mod._active_downloads["aware1"]
        assert info["started_at"].tzinfo == timezone.utc
        assert info["finished_at"].tzinfo == timezone.utc
        # Aware ISO gains an explicit offset (never silently naive).
        assert info["started_at"].isoformat().endswith("+00:00")

    @pytest.mark.unit
    def test_error_carries_suggests_vpn(self, _env, monkeypatch):
        monkeypatch.setattr(dl_mod, "YoutubeDL", _boom)
        res_q: queue.Queue = queue.Queue()
        dl_mod.download_thread(
            url="https://x.test/v", download_id="vpn1",
            result_queue=res_q,
        )
        res = res_q.get(timeout=10)
        assert res["error_type"] == "ERROR_GEO_BLOCKED"
        assert res["suggests_vpn"] is True
