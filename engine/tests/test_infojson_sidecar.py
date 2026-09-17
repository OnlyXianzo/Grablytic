"""Iteration 1 (resume sidecar starvation): writeinfojson default-ON + success-path
sidecar cleanup.

Spec (gate doc `.agents/worklog/iteration1-resume-verified-approach.md`):
- `write_info_json` defaults True (opt-out preserved) so interrupted downloads
  leave a `<stem>.info.json` sidecar that `resume.py` can recover a URL from.
- The engine deletes those sidecars on terminal SUCCESS only (derived solely
  from the engine's own finished `file_path`); failure/cancel keeps them.
- FFmpegMetadata PP pins `add_infojson=False` so newly-written sidecars are
  not attached into mkv/mka output bytes (yt-dlp default is `'if_exists'`).
"""

import pytest

import grablytic_engine.downloader as dl_mod
from grablytic_engine.opts_builder import build_ydl_opts
from grablytic_engine.paths import _paths, set_paths


@pytest.fixture(autouse=True)
def _paths_env(tmp_path, monkeypatch):
    import os
    import shutil
    original_isfile = os.path.isfile
    original_access = os.access
    monkeypatch.setattr(
        os.path, "isfile",
        lambda path: True if path in ("/usr/bin/ffmpeg", "/usr/bin/aria2c")
        else original_isfile(path),
    )
    monkeypatch.setattr(
        os, "access",
        lambda path, mode: True if path in ("/usr/bin/ffmpeg", "/usr/bin/aria2c")
        else original_access(path, mode),
    )
    monkeypatch.setattr(shutil, "which", lambda *args, **kwargs: None)
    _paths["data_dir"] = None
    _paths["aria2c_path"] = None
    _paths["deno_path"] = None
    set_paths(
        data_dir="/tmp/data",
        output_dir="/tmp/output",
        ffmpeg_path="/usr/bin/ffmpeg",
        cache_dir="/tmp/cache",
    )
    yield


class TestWriteInfoJsonDefaultOn:
    @pytest.mark.unit
    def test_default_opts_include_writeinfojson(self):
        opts = build_ydl_opts()
        assert opts.get("writeinfojson") is True

    @pytest.mark.unit
    def test_opt_out_preserved(self):
        opts = build_ydl_opts(config={"write_info_json": False})
        assert "writeinfojson" not in opts

    @pytest.mark.unit
    def test_explicit_opt_in(self):
        opts = build_ydl_opts(config={"write_info_json": True})
        assert opts.get("writeinfojson") is True

    @pytest.mark.unit
    def test_metadata_pp_does_not_attach_infojson(self):
        # yt-dlp's FFmpegMetadataPP defaults add_infojson='if_exists' (truthy),
        # which would embed the new sidecars into mkv/mka outputs. The engine
        # must pin it off so output bytes stay stable.
        opts = build_ydl_opts()
        meta = [pp for pp in opts.get("postprocessors", [])
                if pp.get("key") == "FFmpegMetadata"]
        assert meta, "expected an FFmpegMetadata postprocessor"
        assert meta[0].get("add_infojson") is False


class TestSidecarCleanupHelper:
    @pytest.mark.unit
    def test_removes_stem_sibling(self, tmp_path):
        media = tmp_path / "Artist - Title.mkv"
        media.write_bytes(b"x" * 16)
        sidecar = tmp_path / "Artist - Title.info.json"
        sidecar.write_text('{"webpage_url": "https://x.test/v"}')
        removed = dl_mod._delete_infojson_sidecars(str(media))
        assert not sidecar.exists()
        assert media.exists()
        assert str(sidecar) in removed

    @pytest.mark.unit
    def test_removes_full_filename_variant(self, tmp_path):
        media = tmp_path / "Artist - Title.mkv"
        media.write_bytes(b"x" * 16)
        sidecar = tmp_path / "Artist - Title.mkv.info.json"
        sidecar.write_text('{"webpage_url": "https://x.test/v"}')
        removed = dl_mod._delete_infojson_sidecars(str(media))
        assert not sidecar.exists()
        assert str(sidecar) in removed

    @pytest.mark.unit
    def test_removes_both_variants(self, tmp_path):
        media = tmp_path / "vid.mp4"
        media.write_bytes(b"x" * 16)
        first = tmp_path / "vid.info.json"
        second = tmp_path / "vid.mp4.info.json"
        first.write_text("{}")
        second.write_text("{}")
        removed = dl_mod._delete_infojson_sidecars(str(media))
        assert not first.exists()
        assert not second.exists()
        assert len(removed) == 2

    @pytest.mark.unit
    def test_missing_files_never_raise(self, tmp_path):
        missing = tmp_path / "nope.mkv"
        assert dl_mod._delete_infojson_sidecars(str(missing)) == []
        assert dl_mod._delete_infojson_sidecars(None) == []
        assert dl_mod._delete_infojson_sidecars("") == []
        assert dl_mod._delete_infojson_sidecars(12345) == []

    @pytest.mark.unit
    def test_never_deletes_media_or_unrelated_files(self, tmp_path):
        media = tmp_path / "vid.info.json"
        media.write_bytes(b"media bytes")
        other = tmp_path / "other.info.json"
        other.write_text("{}")
        sub = tmp_path / "sub"
        sub.mkdir()
        nested = sub / "vid.info.json"
        nested.write_text("{}")
        dl_mod._delete_infojson_sidecars(str(media))
        # The finished file itself is never a deletion candidate, even when
        # it looks like a sidecar; unrelated and nested files are untouched.
        assert media.exists()
        assert other.exists()
        assert nested.exists()

    @pytest.mark.unit
    def test_directory_named_like_sidecar_is_kept(self, tmp_path):
        media = tmp_path / "vid.mkv"
        media.write_bytes(b"x" * 16)
        impostor = tmp_path / "vid.info.json"
        impostor.mkdir()
        removed = dl_mod._delete_infojson_sidecars(str(media))
        assert impostor.is_dir()
        assert removed == []
