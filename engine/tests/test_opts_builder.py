import pytest
from grablytic_engine.paths import set_paths, _paths
from grablytic_engine.opts_builder import build_ydl_opts


@pytest.fixture(autouse=True)
def reset_paths(monkeypatch):
    import shutil
    import os
    # T0-2: admission now gates on isfile AND X_OK — simulate both bits for
    # the fake system binaries (mirrors test_paths.py mock_isfile).
    original_isfile = os.path.isfile
    original_access = os.access
    monkeypatch.setattr(
        os.path,
        "isfile",
        lambda path: True if path in ("/usr/bin/ffmpeg", "/usr/bin/aria2c") else original_isfile(path)
    )
    monkeypatch.setattr(
        os,
        "access",
        lambda path, mode: True if path in ("/usr/bin/ffmpeg", "/usr/bin/aria2c") else original_access(path, mode)
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
    dummy.chmod(0o755)
    _paths["aria2c_path"] = str(dummy)
    opts = build_ydl_opts(config={"aria2c_enabled": True, "aria2c_chunks": 5})
    assert isinstance(opts["external_downloader"], dict)
    assert opts["external_downloader"]["default"] == str(dummy)
    assert opts["external_downloader"]["dash"] == "native"
    assert "-x5" in opts["external_downloader_args"]


def test_aria2c_not_wired_when_disabled(tmp_path):
    dummy = tmp_path / "aria2c"
    dummy.touch()
    dummy.chmod(0o755)
    _paths["aria2c_path"] = str(dummy)
    opts = build_ydl_opts(config={"aria2c_enabled": False})
    assert "external_downloader" not in opts


def test_aria2c_without_path_not_enabled():
    opts = build_ydl_opts(config={"aria2c_enabled": True})
    assert "external_downloader" not in opts


def test_aria2c_max_speed_applied(tmp_path):
    dummy = tmp_path / "aria2c"
    dummy.touch()
    dummy.chmod(0o755)
    _paths["aria2c_path"] = str(dummy)
    opts = build_ydl_opts(config={
        "aria2c_enabled": True,
        "aria2c_chunks": 8,
        "aria2c_max_speed": "10M",
    })
    assert isinstance(opts["external_downloader"], dict)
    assert opts["external_downloader"]["default"] == str(dummy)
    assert opts["external_downloader"]["dash"] == "native"
    assert "-x8" in opts["external_downloader_args"]
    assert "--max-download-limit=10M" in opts["external_downloader_args"]


def _aria2c_args(tmp_path, **cfg):
    dummy = tmp_path / "aria2c"
    dummy.touch()
    dummy.chmod(0o755)
    _paths["aria2c_path"] = str(dummy)
    opts = build_ydl_opts(config={"aria2c_enabled": True, **cfg})
    return opts["external_downloader_args"]


def test_aria2c_chunks_clamped(tmp_path):
    assert "-x16" in _aria2c_args(tmp_path, aria2c_chunks=99)
    assert "-x1" in _aria2c_args(tmp_path, aria2c_chunks=-3)
    assert "-x1" in _aria2c_args(tmp_path, aria2c_chunks=0)


def test_aria2c_chunks_invalid_falls_back(tmp_path):
    assert "-x5" in _aria2c_args(tmp_path, aria2c_chunks="abc")
    assert "-x5" in _aria2c_args(tmp_path, aria2c_chunks=None)


def test_aria2c_max_speed_validated(tmp_path):
    assert "--max-download-limit=500k" in _aria2c_args(
        tmp_path, aria2c_max_speed="500k")
    for bad in ("10M; rm -rf", "-x9", "--dir=/", "abc", "10 MB"):
        args = _aria2c_args(tmp_path, aria2c_max_speed=bad)
        assert not any(a.startswith("--max-download-limit") for a in args), bad


def test_rate_limit_applied():
    opts = build_ydl_opts(config={"rate_limit": "500K"})
    assert opts["ratelimit"] == "500K"


def test_proxy_applied():
    opts = build_ydl_opts(config={"proxy": "http://proxy:8080"})
    assert opts["proxy"] == "http://proxy:8080"


def test_geo_bypass_default_on():
    opts = build_ydl_opts()
    assert opts["geo_bypass"] is True


def test_no_playlist_sets_noplaylist():
    opts = build_ydl_opts(config={"no_playlist": True})
    assert opts["noplaylist"] is True


def test_playlist_items_override():
    opts = build_ydl_opts(config={"playlist_items": "1-5"})
    assert opts["playlist_items"] == "1-5"


def test_playlist_reverse():
    opts = build_ydl_opts(config={"playlist_rev": True})
    assert opts["playlistreverse"] is True


def test_playlist_random():
    opts = build_ydl_opts(config={"playlist_rand": True})
    assert opts["playlistrandom"] is True


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


def test_sleep_interval_garbage_is_ignored_not_fatal():
    # Regression [TEARDOWN-4]: bare int() turned a settings typo into a
    # ValueError out of build_ydl_opts, killing the download start path.
    opts = build_ydl_opts(config={"sleep_interval": "abc"})
    assert "sleep_interval" not in opts


def test_sleep_interval_out_of_range_is_ignored():
    assert "sleep_interval" not in build_ydl_opts(config={"sleep_interval": "-5"})
    assert "sleep_interval" not in build_ydl_opts(config={"sleep_interval": "99999"})
    assert "sleep_interval" not in build_ydl_opts(config={"sleep_interval": "1.5"})


def test_embed_thumbnail_adds_postprocessors():
    opts = build_ydl_opts(config={"embedthumbnail": True, "addmetadata": False})
    pps = opts.get("postprocessors", [])
    keys = [pp.get("key") for pp in pps]
    assert "FFmpegThumbnailsConvertor" in keys
    assert "EmbedThumbnail" in keys
    assert opts.get("writethumbnail") is True


def test_embed_thumbnail_postprocessor_ordering():
    opts = build_ydl_opts(config={
        "embedthumbnail": True,
        "addmetadata": True,
        "writesubtitles": True,
        "embedsubtitles": True,
    })
    pps = opts.get("postprocessors", [])
    keys = [pp.get("key") for pp in pps]
    # Canonical yt-dlp PP order: ThumbnailsConvertor -> EmbedSubtitle -> Metadata -> EmbedThumbnail
    assert keys.index("FFmpegThumbnailsConvertor") < keys.index("FFmpegEmbedSubtitle")
    assert keys.index("FFmpegEmbedSubtitle") < keys.index("FFmpegMetadata")
    assert keys.index("FFmpegMetadata") < keys.index("EmbedThumbnail")


def test_embed_thumbnail_webm_coerced_to_mkv():
    # WebM cannot embed cover art; opts_builder coerces container to mkv
    opts = build_ydl_opts(config={"embedthumbnail": True, "container": "webm"})
    assert opts.get("merge_output_format") == "mkv"


def test_embed_thumbnail_keeps_sidecar_for_offline_ui():
    # Regression (task 03): already_have_thumbnail must be True so yt-dlp
    # keeps the writethumbnail sidecar after embedding. The flag only
    # controls post-embed deletion (EmbedThumbnailPP.run), never the embed
    # itself — with False (the old `cfg.get("writethumbnail")` lookup, a key
    # that exists nowhere in DEFAULT_CFG/Dart) every sidecar was deleted and
    # Library could never render thumbnails offline.
    opts = build_ydl_opts(config={"embedthumbnail": True, "addmetadata": False})
    pps = opts.get("postprocessors", [])
    embed = next(pp for pp in pps if pp.get("key") == "EmbedThumbnail")
    assert embed.get("already_have_thumbnail") is True


def test_subtitles_embedded():
    opts = build_ydl_opts(config={
        "writesubtitles": True,
        "writeautomaticsub": False,
        "subtitleslangs": ["en"],
        "embedsubtitles": True,
    })
    # `embedsubs` is not a real YoutubeDL param — embedding is driven by the
    # FFmpegEmbedSubtitle postprocessor (mirrors --embed-subs mapping).
    assert "embedsubs" not in opts
    assert opts.get("writesubtitles") is True
    keys = [pp.get("key") for pp in opts.get("postprocessors", [])]
    assert "FFmpegEmbedSubtitle" in keys


def test_subtitles_sidecar_without_embed():
    # Sidecar-only (write but don't embed) must still download .srt files:
    # writesubtitles/subtitleslangs set, no FFmpegEmbedSubtitle PP.
    opts = build_ydl_opts(config={
        "writesubtitles": True,
        "writeautomaticsub": False,
        "subtitleslangs": ["en", "hi"],
        "embedsubtitles": False,
    })
    assert opts.get("writesubtitles") is True
    assert opts.get("subtitleslangs") == ["en", "hi"]
    keys = [pp.get("key") for pp in opts.get("postprocessors", [])]
    assert "FFmpegEmbedSubtitle" not in keys


def test_organize_by_folder_splits_audio_video():
    v = build_ydl_opts(config={"organize_by_folder": True, "audio_only": False})
    assert v["outtmpl"]["default"].startswith("Video/")
    a = build_ydl_opts(config={"organize_by_folder": True, "audio_only": True})
    assert a["outtmpl"]["default"].startswith("Audio/")
    plain = build_ydl_opts(config={"organize_by_folder": False})
    assert "/" not in plain["outtmpl"]["default"].split("%")[0]


def test_use_archive_defaults_to_data_dir():
    opts = build_ydl_opts(config={"use_archive": True})
    assert opts.get("download_archive") == "/tmp/data/download_archive.txt"
    opts2 = build_ydl_opts(config={"use_archive": True, "archive_path": "/tmp/x.txt"})
    assert opts2.get("download_archive") == "/tmp/x.txt"
    opts3 = build_ydl_opts(config={"use_archive": False})
    assert "download_archive" not in opts3


def test_thumbnail_format_png_option():
    opts = build_ydl_opts(config={"thumbnail_format": "png"})
    conv = [pp for pp in opts.get("postprocessors", []) if pp.get("key") == "FFmpegThumbnailsConvertor"]
    assert conv and conv[0]["format"] == "png"
    opts2 = build_ydl_opts(config={})
    conv2 = [pp for pp in opts2.get("postprocessors", []) if pp.get("key") == "FFmpegThumbnailsConvertor"]
    assert conv2 and conv2[0]["format"] == "jpg"


def test_merge_output_format_mp4():
    opts = build_ydl_opts(config={"container": "mp4"})
    assert opts["merge_output_format"] == "mp4"


def test_progress_queue_adds_hooks():
    import queue
    q = queue.Queue()
    opts = build_ydl_opts(progress_queue=q)
    assert "progress_hooks" in opts
    assert "postprocessor_hooks" in opts


def test_embed_subtitles_uses_real_pp_key():
    # Regression: `embedsubs` is not a YoutubeDL param (silently ignored).
    # The CLI maps --embed-subs to the FFmpegEmbedSubtitle postprocessor.
    opts = build_ydl_opts(config={
        "writesubtitles": True,
        "writeautomaticsub": False,
        "subtitleslangs": ["en"],
        "embedsubtitles": True,
    })
    assert "embedsubs" not in opts
    pps = opts.get("postprocessors", [])
    emb = [pp for pp in pps if pp.get("key") == "FFmpegEmbedSubtitle"]
    assert len(emb) == 1
    assert emb[0]["already_have_subtitle"] is True


def test_canonical_pp_order_embed_modify_metadata():
    opts = build_ydl_opts(config={
        "writesubtitles": True,
        "embedsubtitles": True,
        "sponsorblock_cats": ["sponsor"],
        "addmetadata": True,
        "embedthumbnail": False,
    })
    keys = [pp.get("key") for pp in opts.get("postprocessors", [])]
    assert keys.index("FFmpegEmbedSubtitle") < keys.index("ModifyChapters")
    assert keys.index("ModifyChapters") < keys.index("FFmpegMetadata")


def test_download_sections_build_ranges():
    opts = build_ydl_opts(config={"download_sections": ["*10:15-20:00", "0-60"]})
    cb = opts.get("download_ranges")
    assert cb is not None
    ranges = list(cb({"id": "x"}, None))
    assert ranges[0]["start_time"] == 615
    assert ranges[0]["end_time"] == 1200
    assert ranges[1]["start_time"] == 0
    assert ranges[1]["end_time"] == 60


def test_download_sections_open_end_and_keyframes_flag():
    opts = build_ydl_opts(config={
        "download_sections": ["90-inf"],
        "force_keyframes_at_cuts": True,
    })
    ranges = list(opts["download_ranges"]({"id": "x"}, None))
    assert ranges[0]["start_time"] == 90
    assert ranges[0]["end_time"] == float("inf")
    assert opts["force_keyframes_at_cuts"] is True


def test_download_sections_invalid_specs_ignored():
    opts = build_ydl_opts(config={"download_sections": ["garbage", "60-10", ""]})
    assert "download_ranges" not in opts


def test_download_sections_defaults_off():
    opts = build_ydl_opts()
    assert "download_ranges" not in opts
    assert "force_keyframes_at_cuts" not in opts


def test_storage_sanitization_options():
    opts = build_ydl_opts()
    assert opts.get("windowsfilenames") is True
    assert opts.get("trim_file_name") == 160


def test_js_runtime_configured_with_deno(tmp_path):
    deno_file = tmp_path / "deno"
    deno_file.touch()
    deno_file.chmod(0o755)
    _paths["deno_path"] = str(deno_file)
    opts = build_ydl_opts()
    assert "js_runtimes" in opts
    assert opts["js_runtimes"]["deno"]["path"] == str(deno_file)
    assert "remote_components" in opts
    assert "ejs:github" in opts["remote_components"]


def test_fragment_and_socket_defaults_applied():
    opts = build_ydl_opts()
    assert opts["concurrent_fragment_downloads"] == 4
    assert opts["socket_timeout"] == 30


def test_fragment_and_socket_custom_values():
    opts = build_ydl_opts(
        config={"concurrent_fragments": 8, "socket_timeout": 60})
    assert opts["concurrent_fragment_downloads"] == 8
    assert opts["socket_timeout"] == 60


def test_fragment_clamped_to_sane_range():
    assert build_ydl_opts(
        config={"concurrent_fragments": 99})["concurrent_fragment_downloads"] == 16
    assert build_ydl_opts(
        config={"concurrent_fragments": 0})["concurrent_fragment_downloads"] == 1


def test_fragment_and_socket_invalid_fall_back():
    opts = build_ydl_opts(
        config={"concurrent_fragments": "lots", "socket_timeout": "soon"})
    assert opts["concurrent_fragment_downloads"] == 4
    assert "socket_timeout" not in opts


def test_socket_non_positive_ignored():
    opts = build_ydl_opts(config={"socket_timeout": -5})
    assert "socket_timeout" not in opts


def test_write_flags_default_off():
    opts = build_ydl_opts()
    assert "writedescription" not in opts
    assert "writeinfojson" not in opts


def test_write_flags_enabled():
    opts = build_ydl_opts(
        config={"write_description": True, "write_info_json": True})
    assert opts["writedescription"] is True
    assert opts["writeinfojson"] is True


def test_legacy_use_aria2_alias(tmp_path):
    dummy = tmp_path / "aria2c"
    dummy.touch()
    dummy.chmod(0o755)
    _paths["aria2c_path"] = str(dummy)
    opts = build_ydl_opts(config={"use_aria2": True})
    assert opts["external_downloader"]["default"] == str(dummy)


def test_android_prefers_node_over_deno(tmp_path, monkeypatch):
    import sys
    import types
    import grablytic_engine.opts_builder as opts_mod
    deno_file = tmp_path / "deno"
    deno_file.touch()
    deno_file.chmod(0o755)
    node_file = tmp_path / "node"
    node_file.touch()
    node_file.chmod(0o755)
    _paths["deno_path"] = str(deno_file)
    _paths["nodejs_path"] = str(node_file)
    fake_java = types.ModuleType("java.android")
    fake_java.context = object()
    monkeypatch.setitem(sys.modules, "java.android", fake_java)
    opts = build_ydl_opts()
    assert opts["js_runtimes"] == {"node": {"path": str(node_file)}}


def test_desktop_keeps_deno_first(tmp_path):
    import sys
    sys.modules.pop("java.android", None)
    deno_file = tmp_path / "deno"
    deno_file.touch()
    deno_file.chmod(0o755)
    node_file = tmp_path / "node"
    node_file.touch()
    node_file.chmod(0o755)
    _paths["deno_path"] = str(deno_file)
    _paths["nodejs_path"] = str(node_file)
    opts = build_ydl_opts()
    assert opts["js_runtimes"] == {"deno": {"path": str(deno_file)}}


def test_explicit_audio_format_id_sets_format():
    opts = build_ydl_opts(config={"explicit_audio_format_id": "140"})
    assert opts["format"] == "140"


def test_audio_only_adds_ffmpeg_extract_audio(tmp_path):
    ffmpeg_file = tmp_path / "ffmpeg"
    ffmpeg_file.touch()
    _paths["ffmpeg_path"] = str(ffmpeg_file)
    opts = build_ydl_opts(config={"audio_only": True, "container": "mp3"})
    assert "merge_output_format" not in opts
    pps = opts.get("postprocessors", [])
    extract_pps = [p for p in pps if p.get("key") == "FFmpegExtractAudio"]
    assert len(extract_pps) == 1
    assert extract_pps[0]["preferredcodec"] == "mp3"


def test_audio_only_maps_video_container_to_audio(tmp_path):
    ffmpeg_file = tmp_path / "ffmpeg"
    ffmpeg_file.touch()
    _paths["ffmpeg_path"] = str(ffmpeg_file)
    opts = build_ydl_opts(config={"audio_only": True, "container": "mkv", "audio_format": "none"})
    pps = opts.get("postprocessors", [])
    extract_pps = [p for p in pps if p.get("key") == "FFmpegExtractAudio"]
    assert len(extract_pps) == 1
    assert extract_pps[0]["preferredcodec"] == "m4a"


def test_explicit_audio_without_video_treated_as_audio(tmp_path):
    ffmpeg_file = tmp_path / "ffmpeg"
    ffmpeg_file.touch()
    _paths["ffmpeg_path"] = str(ffmpeg_file)
    opts = build_ydl_opts(config={"explicit_audio_format_id": "hls_aac_160k", "container": "opus"})
    assert opts["format"] == "hls_aac_160k"
    assert "merge_output_format" not in opts
    pps = opts.get("postprocessors", [])
    extract_pps = [p for p in pps if p.get("key") == "FFmpegExtractAudio"]
    assert len(extract_pps) == 1
    assert extract_pps[0]["preferredcodec"] == "opus"


def test_thumbnails_opt_out_writes_no_thumbnail():
    # User-facing "Save thumbnails" toggle OFF (embedthumbnail False via
    # settingsDownloadConfig) must produce zero thumbnail fetching,
    # converting, or embedding — e.g. Instagram reels today always write
    # sidecars because the engine default is True and nothing overrides it.
    opts = build_ydl_opts(config={"embedthumbnail": False, "addmetadata": True})
    assert "writethumbnail" not in opts
    keys = [pp.get("key") for pp in opts.get("postprocessors", [])]
    assert "FFmpegThumbnailsConvertor" not in keys
    assert "EmbedThumbnail" not in keys
    # Metadata PP must still exist (independent feature).
    assert "FFmpegMetadata" in keys


class TestNumericGuards:
    """T3-10: unguarded int() on IPC params killed threads (UNKNOWN) or hung
    forever; 0-speed throttled downloads to zero (DoS)."""

    def test_garbage_retries_fall_back(self):
        opts = build_ydl_opts(config={"retries": "abc", "fragment_retries": "xyz"})
        assert opts["retries"] == 10
        assert opts["fragment_retries"] == 10

    def test_absurd_retries_clamped(self):
        opts = build_ydl_opts(config={"retries": 10 ** 9, "fragment_retries": 10 ** 9})
        assert 0 <= opts["retries"] <= 30
        assert 0 <= opts["fragment_retries"] <= 100

    def test_absurd_socket_timeout_omitted(self):
        # Out-of-range falls back to omission (yt-dlp default applies),
        # matching the established invalid-value contract above.
        opts = build_ydl_opts(config={"socket_timeout": 10 ** 9})
        assert "socket_timeout" not in opts

    def test_zero_speed_rejected(self, tmp_path):
        args = _aria2c_args(tmp_path, aria2c_max_speed="0")
        assert not any(a.startswith("--max-download-limit") for a in args)
        args = _aria2c_args(tmp_path, aria2c_max_speed="0K")
        assert not any(a.startswith("--max-download-limit") for a in args)


def _thumb_convertor_format(opts):
    for pp in opts.get("postprocessors", []):
        if pp.get("key") == "FFmpegThumbnailsConvertor":
            return pp.get("format")
    return None


def test_m4a_audio_forces_png_cover_art():
    # Field failure (ri1Ar5nEq4s): mjpeg cannot mux into m4a/ipod, so every
    # m4a download with JPG thumbnails died at EmbedThumbnail. PNG muxes
    # cleanly — forced regardless of the toggle.
    opts = build_ydl_opts(
        config={"audio_only": True, "audio_format": "m4a",
                "thumbnail_format": "jpg"})
    assert _thumb_convertor_format(opts) == "png"


def test_m4a_audio_explicit_png_stays_png():
    opts = build_ydl_opts(
        config={"audio_only": True, "audio_format": "m4a",
                "thumbnail_format": "png"})
    assert _thumb_convertor_format(opts) == "png"


def test_mp3_audio_keeps_jpg_cover_art():
    # MP3 (ID3) embeds mjpeg fine — no override, toggle respected.
    opts = build_ydl_opts(
        config={"audio_only": True, "audio_format": "mp3",
                "thumbnail_format": "jpg"})
    assert _thumb_convertor_format(opts) == "jpg"


def test_video_keeps_jpg_cover_art():
    opts = build_ydl_opts(config={"thumbnail_format": "jpg"})
    assert _thumb_convertor_format(opts) == "jpg"
