"""T06: source URL persists in media tags (comment/purl) and stays in the DB.

 yt-dlp's FFmpegMetadataPP maps ``webpage_url`` to both ``purl`` and
 ``comment`` for every container through one ``-metadata`` path — no
 per-container branch, no FFmpeg fallback needed. These tests lock:
 1. the PP mapping against the installed yt-dlp (no network), and
 2. the builder default that keeps the Metadata PP enabled.
 DB exact-URL persistence is structural (``url TEXT NOT NULL`` round-trip
 in download_history_db.dart) and needs no migration.
"""

import os
import shutil
from types import SimpleNamespace

import pytest
from yt_dlp.postprocessor.ffmpeg import FFmpegMetadataPP

from grablytic_engine.paths import set_paths, _paths
from grablytic_engine.opts_builder import build_ydl_opts


def _pp():
    # No network: instance only feeds get_param('compat_opts', []) lookups.
    return FFmpegMetadataPP(SimpleNamespace(params={}))


@pytest.fixture(autouse=True)
def reset_paths(monkeypatch):
    original_isfile = os.path.isfile
    original_access = os.access
    monkeypatch.setattr(
        os.path,
        "isfile",
        lambda path: True
        if path in ("/usr/bin/ffmpeg", "/usr/bin/aria2c")
        else original_isfile(path),
    )
    monkeypatch.setattr(
        os,
        "access",
        lambda path, mode: True
        if path in ("/usr/bin/ffmpeg", "/usr/bin/aria2c")
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


def test_webpage_url_maps_to_purl_and_comment():
    url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    opts = list(_pp()._get_metadata_opts({"webpage_url": url, "ext": "mp4"}))
    pairs = [(k, v) for k, v in opts if k == "-metadata"]
    assert f"purl={url}" in [v for _, v in pairs]
    assert f"comment={url}" in [v for _, v in pairs]


def test_mapping_is_container_agnostic():
    url = "https://example.com/video/123"
    for ext in ("mp4", "m4a", "mkv", "webm", "mp3", "opus"):
        opts = list(_pp()._get_metadata_opts({"webpage_url": url, "ext": ext}))
        values = [v for k, v in opts if k == "-metadata"]
        assert f"purl={url}" in values, ext
        assert f"comment={url}" in values, ext


def test_builder_keeps_metadata_pp_enabled_by_default():
    opts = build_ydl_opts()
    pps = opts.get("postprocessors", [])
    meta = [pp for pp in pps if pp.get("key") == "FFmpegMetadata"]
    assert meta, "expected an FFmpegMetadata postprocessor"
    assert meta[0].get("add_metadata")
