from truestream_engine.paths import set_paths, get_paths, is_initialized


def test_set_paths_returns_success():
    result = set_paths(
        data_dir="/tmp/data",
        output_dir="/tmp/output",
        ffmpeg_path="/usr/bin/ffmpeg",
        cache_dir="/tmp/cache",
    )
    assert result == {"success": True}


def test_get_paths_returns_what_was_set():
    set_paths(
        data_dir="/tmp/data",
        output_dir="/tmp/output",
        ffmpeg_path="/usr/bin/ffmpeg",
        cache_dir="/tmp/cache",
    )
    paths = get_paths()
    assert paths["data_dir"] == "/tmp/data"
    assert paths["output_dir"] == "/tmp/output"
    assert paths["ffmpeg_path"] == "/usr/bin/ffmpeg"
    assert paths["cache_dir"] == "/tmp/cache"


def test_get_paths_optional_fields_default_none(monkeypatch):
    import shutil
    monkeypatch.setattr(shutil, "which", lambda *args, **kwargs: None)
    from truestream_engine.paths import _paths
    _paths["aria2c_path"] = None
    _paths["deno_path"] = None
    set_paths(
        data_dir="/tmp/data",
        output_dir="/tmp/output",
        ffmpeg_path="/usr/bin/ffmpeg",
        cache_dir="/tmp/cache",
    )
    paths = get_paths()
    import os
    ext = ".exe" if os.name == "nt" else ""
    assert paths["cookies_path"] is None
    assert paths["aria2c_path"] == f"/tmp/data/bin/aria2c{ext}"
    assert paths["deno_path"] == f"/tmp/data/bin/deno{ext}"
    assert paths["po_token"] is None


def test_set_paths_with_optional_fields():
    set_paths(
        data_dir="/tmp/data",
        output_dir="/tmp/output",
        ffmpeg_path="/usr/bin/ffmpeg",
        cache_dir="/tmp/cache",
        cookies_path="/tmp/cookies.txt",
        aria2c_path="/usr/bin/aria2c",
        po_token="abc123",
    )
    paths = get_paths()
    assert paths["cookies_path"] == "/tmp/cookies.txt"
    assert paths["aria2c_path"] == "/usr/bin/aria2c"
    assert paths["po_token"] == "abc123"


def test_is_initialized_false_before_set():
    from truestream_engine.paths import _paths
    _paths["data_dir"] = None
    assert is_initialized() is False


def test_is_initialized_true_after_set():
    set_paths(
        data_dir="/tmp/data",
        output_dir="/tmp/output",
        ffmpeg_path="/usr/bin/ffmpeg",
        cache_dir="/tmp/cache",
    )
    assert is_initialized() is True


def test_get_paths_does_not_return_internal_mutable():
    set_paths(
        data_dir="/tmp/data",
        output_dir="/tmp/output",
        ffmpeg_path="/usr/bin/ffmpeg",
        cache_dir="/tmp/cache",
    )
    paths = get_paths()
    paths["data_dir"] = "/hacked"
    fresh = get_paths()
    assert fresh["data_dir"] == "/tmp/data"
