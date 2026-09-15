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


def test_clear_archive_explicit_path_inside_data_dir(_env):
    """Explicit path INSIDE data_dir still works."""
    tmp_path = _env
    custom = tmp_path / "custom.txt"
    custom.write_text("youtube xyz\n")
    res = dl_mod.clear_download_archive(str(custom))
    assert res == {"success": True, "removed": True, "path": str(custom)}
    assert not custom.exists()
    assert os.path.isdir(str(tmp_path))


# ── Exploit-proof tests (T0-1: arbitrary file delete) ─────────────────


def test_clear_archive_rejects_absolute_path_outside_data_dir(_env):
    """An absolute path outside data_dir must be rejected — not deleted."""
    tmp_path = _env
    # Create a victim file in a sibling directory (outside data_dir).
    sibling = tmp_path.parent / "sibling_victim"
    sibling.mkdir(exist_ok=True)
    victim = sibling / "important.txt"
    victim.write_text("do not delete me\n")
    try:
        res = dl_mod.clear_download_archive(str(victim))
        assert res["success"] is False
        assert res["removed"] is False
        assert "escapes" in res.get("error_message", "").lower()
        # Victim file must still exist.
        assert victim.exists(), "File outside data_dir was deleted!"
    finally:
        victim.unlink(missing_ok=True)
        sibling.rmdir()


def test_clear_archive_rejects_traversal_attack(_env):
    """Path traversal via ../../ must be rejected."""
    tmp_path = _env
    # Build a traversal path that resolves outside data_dir.
    traversal = os.path.join(str(tmp_path), "..", "..", "etc", "passwd")
    res = dl_mod.clear_download_archive(traversal)
    assert res["success"] is False
    assert res["removed"] is False
    assert "escapes" in res.get("error_message", "").lower()


def test_clear_archive_rejects_prefix_substring_trick(_env):
    """data_dir='/a/b' must not accept '/a/b_evil/file' (substring trick)."""
    tmp_path = _env
    # Create a directory whose name starts with data_dir's name + extra chars.
    evil_dir = tmp_path.parent / (tmp_path.name + "_evil")
    evil_dir.mkdir(exist_ok=True)
    victim = evil_dir / "steal.txt"
    victim.write_text("secrets\n")
    try:
        res = dl_mod.clear_download_archive(str(victim))
        assert res["success"] is False
        assert res["removed"] is False
        assert victim.exists(), "Substring-prefix trick bypassed containment!"
    finally:
        victim.unlink(missing_ok=True)
        evil_dir.rmdir()


def test_clear_archive_rejects_symlink_escape(_env):
    """A symlink inside data_dir pointing outside must be rejected."""
    tmp_path = _env
    # Create a target file outside data_dir.
    outside = tmp_path.parent / "outside_target.txt"
    outside.write_text("external secret\n")
    # Create a symlink inside data_dir pointing to it.
    link = tmp_path / "escape_link.txt"
    try:
        os.symlink(str(outside), str(link))
    except OSError:
        pytest.skip("OS does not support symlinks")
    try:
        res = dl_mod.clear_download_archive(str(link))
        assert res["success"] is False
        assert res["removed"] is False
        assert outside.exists(), "Symlink escape deleted the real file!"
    finally:
        link.unlink(missing_ok=True)
        outside.unlink(missing_ok=True)

