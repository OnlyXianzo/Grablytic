"""Overflow supporting engine behavior: overwrite/archive bypass + clear_archive."""

import os

import pytest

import grablytic_engine.downloader as dl_mod
from grablytic_engine.opts_builder import build_ydl_opts
from grablytic_engine.paths import set_paths, _paths


@pytest.fixture()
def _env(tmp_path):
    _paths["data_dir"] = None
    _paths["aria2c_path"] = None
    _paths["deno_path"] = None
    set_paths(
        data_dir=str(tmp_path),
        output_dir=str(tmp_path),
        ffmpeg_path=None,
        cache_dir=str(tmp_path),
    )
    dl_mod._active_downloads.clear()
    dl_mod._pending_queue.clear()
    yield tmp_path
    dl_mod._active_downloads.clear()
    dl_mod._pending_queue.clear()


def test_force_overwrite_sets_overwrites_and_disables_continue(_env):
    opts = build_ydl_opts(config={"force_overwrite": True})
    assert opts.get("overwrites") is True
    assert opts.get("continuedl") is False


def test_default_is_resume_capable(_env):
    opts = build_ydl_opts(config={})
    assert opts.get("continuedl") is True
    assert opts.get("overwrites") is not True


def test_ignore_archive_bypasses_download_archive(_env):
    opts = build_ydl_opts(
        config={"use_archive": True, "ignore_archive": True})
    assert "download_archive" not in opts
    opts2 = build_ydl_opts(config={"use_archive": True})
    assert "download_archive" in opts2


def test_clear_archive_removes_only_the_file(_env):
    tmp_path = _env
    target = tmp_path / "download_archive.txt"
    target.write_text("youtube abc123\n")
    subdir = tmp_path / "sub"
    subdir.mkdir()
    res = dl_mod.clear_download_archive()
    assert res["success"] is True
    assert res["removed"] is True
    assert not target.exists()
    assert subdir.is_dir()
    # Second call: nothing to remove, still success.
    res2 = dl_mod.clear_download_archive()
    assert res2["success"] is True
    assert res2["removed"] is False


def test_clear_archive_explicit_path(_env):
    tmp_path = _env
    custom = tmp_path / "custom.txt"
    custom.write_text("youtube xyz\n")
    res = dl_mod.clear_download_archive(str(custom))
    assert res == {"success": True, "removed": True, "path": str(custom)}
    assert not custom.exists()
    assert os.path.isdir(str(tmp_path))
