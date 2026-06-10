import shutil as _shutil

_paths = {
    "data_dir": None,
    "output_dir": None,
    "ffmpeg_path": None,
    "cache_dir": None,
    "cookies_path": None,
    "aria2c_path": None,
    "deno_path": None,
    "po_token": None,
    "update_channel": "stable",
}


def set_paths(
    data_dir: str,
    output_dir: str,
    ffmpeg_path: str | None,
    cache_dir: str,
    cookies_path: str | None = None,
    aria2c_path: str | None = None,
    deno_path: str | None = None,
    po_token: str | None = None,
) -> dict:
    import os
    import sys
    _paths["data_dir"] = data_dir
    _paths["output_dir"] = output_dir
    _paths["cache_dir"] = cache_dir

    bin_dir = os.path.join(data_dir, "bin")
    is_windows = os.name == "nt" or (isinstance(os.environ.get("OS"), str) and "windows" in os.environ.get("OS").lower())
    ext = ".exe" if is_windows else ""

    # Resolve ffmpeg: explicit → bundled → system → placeholder
    if ffmpeg_path and os.path.isfile(ffmpeg_path):
        _paths["ffmpeg_path"] = ffmpeg_path
    else:
        bundled = os.path.join(bin_dir, f"ffmpeg{ext}")
        if os.path.isfile(bundled):
            _paths["ffmpeg_path"] = bundled
        else:
            system = _shutil.which(f"ffmpeg{ext}") or _shutil.which("ffmpeg")
            _paths["ffmpeg_path"] = system or bundled

    # Resolve aria2c: explicit → bundled → system → placeholder
    if aria2c_path and os.path.isfile(aria2c_path):
        _paths["aria2c_path"] = aria2c_path
    else:
        bundled = os.path.join(bin_dir, f"aria2c{ext}")
        if os.path.isfile(bundled):
            _paths["aria2c_path"] = bundled
        else:
            system = _shutil.which(f"aria2c{ext}") or _shutil.which("aria2c")
            _paths["aria2c_path"] = system or bundled

    # Resolve deno: explicit → bundled → system → placeholder
    if deno_path and os.path.isfile(deno_path):
        _paths["deno_path"] = deno_path
    else:
        bundled = os.path.join(bin_dir, f"deno{ext}")
        if os.path.isfile(bundled):
            _paths["deno_path"] = bundled
        else:
            system = _shutil.which(f"deno{ext}") or _shutil.which("deno")
            _paths["deno_path"] = system or bundled

    _paths["cookies_path"] = cookies_path
    _paths["po_token"] = po_token

    # Inject binary directories into PATH
    path_dirs = [bin_dir]
    for key in ("ffmpeg_path", "aria2c_path", "deno_path"):
        val = _paths.get(key)
        if val:
            path_dirs.append(os.path.dirname(val))

    existing_path = os.environ.get("PATH", "")
    for pd in path_dirs:
        if pd and pd not in existing_path:
            existing_path = pd + os.pathsep + existing_path
    os.environ["PATH"] = existing_path

    # Prepends site-packages to sys.path to load dynamically updated yt-dlp modules
    site_packages = os.path.join(data_dir, "site-packages")
    if os.path.isdir(site_packages) and site_packages not in sys.path:
        sys.path.insert(0, site_packages)

    return {"success": True}


def set_update_channel(channel: str) -> dict:
    _paths["update_channel"] = channel
    return {"success": True}


def get_paths() -> dict:
    return dict(_paths)


def is_initialized() -> bool:
    return _paths["data_dir"] is not None
