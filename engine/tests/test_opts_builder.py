import pytest
from truestream_engine.paths import set_paths, _paths
from truestream_engine.opts_builder import build_ydl_opts


@pytest.fixture(autouse=True)
def reset_paths(monkeypatch):
    import shutil
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


def test_basic_opts_structure():
    opts = build_ydl_opts()
    assert "format" in opts
    assert "paths" in opts
    assert "outtmpl" in opts
    assert opts["ignoreerrors"] is True
    assert opts["continuedl"] is True


def test_audio_only_adds_postprocessor():
    opts = build_ydl_opts(config={"audio_only": True, "audio_format": "m4a"})
    pps = opts.get("postprocessors", [])
    assert any(pp.get("key") == "FFmpegExtractAudio" for pp in pps)


def test_ffmpeg_path_added():
    opts = build_ydl_opts()
    assert opts["ffmpeg_location"] == "/usr/bin/ffmpeg"


def test_aria2c_wired_when_enabled(tmp_path):
    dummy = tmp_path / "aria2c"
    dummy.touch()
    _paths["aria2c_path"] = str(dummy)
    opts = build_ydl_opts(config={"aria2c_enabled": True, "aria2c_chunks": 5})
    assert opts["external_downloader"] == "aria2c"
    assert "-x5" in opts["external_downloader_args"]


def test_aria2c_not_wired_when_disabled(tmp_path):
    dummy = tmp_path / "aria2c"
    dummy.touch()
    _paths["aria2c_path"] = str(dummy)
    opts = build_ydl_opts(config={"aria2c_enabled": False})
    assert "external_downloader" not in opts


def test_aria2c_without_path_not_enabled():
    opts = build_ydl_opts(config={"aria2c_enabled": True})
    assert "external_downloader" not in opts


def test_aria2c_max_speed_applied(tmp_path):
    dummy = tmp_path / "aria2c"
    dummy.touch()
    _paths["aria2c_path"] = str(dummy)
    opts = build_ydl_opts(config={
        "aria2c_enabled": True,
        "aria2c_chunks": 8,
        "aria2c_max_speed": "10M",
    })
    assert opts["external_downloader"] == "aria2c"
    assert "-x8" in opts["external_downloader_args"]
    assert "--max-download-limit=10M" in opts["external_downloader_args"]


def test_rate_limit_applied():
    opts = build_ydl_opts(config={"rate_limit": "500K"})
    assert opts["ratelimit"] == "500K"


def test_proxy_applied():
    opts = build_ydl_opts(config={"proxy": "http://proxy:8080"})
    assert opts["proxy"] == "http://proxy:8080"


def test_geo_bypass_default_on():
    opts = build_ydl_opts()
    assert opts["geo_bypass"] is True


def test_no_playlist_sets_items_to_1():
    opts = build_ydl_opts(config={"no_playlist": True})
    assert opts["playlist_items"] == "1"


def test_playlist_items_override():
    opts = build_ydl_opts(config={"playlist_items": "1-5"})
    assert opts["playlist_items"] == "1-5"


def test_playlist_reverse():
    opts = build_ydl_opts(config={"playlist_rev": True})
    assert opts["playlist_reverse"] is True


def test_playlist_random():
    opts = build_ydl_opts(config={"playlist_rand": True})
    assert opts["playlist_random"] is True


def test_live_from_start():
    opts = build_ydl_opts(config={"live_from_start": True})
    assert opts["live_from_start"] is True


def test_sponsorblock_added():
    opts = build_ydl_opts(config={"sponsorblock_cats": ["sponsor"]})
    pps = opts.get("postprocessors", [])
    assert any(pp.get("key") == "SponsorBlock" for pp in pps)


def test_po_token_added():
    _paths["po_token"] = "mypotoken"
    opts = build_ydl_opts()
    extractor = opts.get("extractor_args", {})
    assert extractor.get("youtube", {}).get("po_token") == ["mypotoken"]


def test_cookies_added_when_set():
    _paths["cookies_path"] = "/tmp/cookies.txt"
    opts = build_ydl_opts()
    assert opts["cookiefile"] == "/tmp/cookies.txt"


def test_verbose_enabled():
    opts = build_ydl_opts(config={"verbose": True})
    assert opts["verbose"] is True


def test_override_format_takes_precedence():
    opts = build_ydl_opts(override_format="best")
    assert opts["format"] == "best"


def test_override_audio_forces_audio():
    opts = build_ydl_opts(config={"audio_only": False}, override_audio=True)
    pps = opts.get("postprocessors", [])
    assert any(pp.get("key") == "FFmpegExtractAudio" for pp in pps)


def test_archive_enabled():
    opts = build_ydl_opts(config={
        "use_archive": True,
        "archive_path": "/tmp/archive.txt",
    })
    assert opts["download_archive"] == "/tmp/archive.txt"


def test_sleep_interval():
    opts = build_ydl_opts(config={"sleep_interval": "5"})
    assert opts["sleep_interval"] == 5


def test_embed_thumbnail_adds_postprocessors():
    opts = build_ydl_opts(config={"embedthumbnail": True, "addmetadata": False})
    pps = opts.get("postprocessors", [])
    keys = [pp.get("key") for pp in pps]
    assert "FFmpegThumbnailsConvertor" in keys
    assert "EmbedThumbnail" in keys


def test_subtitles_embedded():
    opts = build_ydl_opts(config={
        "writesubtitles": True,
        "writeautomaticsub": False,
        "subtitleslangs": ["en"],
        "embedsubtitles": True,
    })
    assert opts.get("embedsubs") is True
    assert opts.get("writesubtitles") is True


def test_merge_output_format_mp4():
    opts = build_ydl_opts(config={"container": "mp4"})
    assert opts["merge_output_format"] == "mp4"


def test_progress_queue_adds_hooks():
    import queue
    q = queue.Queue()
    opts = build_ydl_opts(progress_queue=q)
    assert "progress_hooks" in opts
    assert "postprocessor_hooks" in opts
