import shutil as _shutil

_paths = {
    "data_dir": None,
    "output_dir": None,
    "ffmpeg_path": None,
    "ffmpeg_ld_path": None,
    "cache_dir": None,
    "cookies_path": None,
    "aria2c_path": None,
    "deno_path": None,
    "nodejs_path": None,
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
    ffmpeg_ld_path: str | None = None,
    nodejs_path: str | None = None,
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

    # Resolve node: explicit → bundled → system → placeholder.
    # (Android primary JS runtime; links cleanly on Bionic.)
    if nodejs_path and os.path.isfile(nodejs_path):
        _paths["nodejs_path"] = nodejs_path
    else:
        bundled = os.path.join(bin_dir, f"node{ext}")
        if os.path.isfile(bundled):
            _paths["nodejs_path"] = bundled
        else:
            system = _shutil.which(f"node{ext}") or _shutil.which("node")
            _paths["nodejs_path"] = system or bundled

    _paths["cookies_path"] = cookies_path
    _paths["po_token"] = po_token

    # Bundled jniLibs .so files ship no RUNPATH: their shared-library tree
    # must be visible via LD_LIBRARY_PATH or every ffmpeg/deno child process
    # fails to start. Applied process-wide here (Chaquopy runs in-process,
    # so this covers the whole app); harmless on desktop when unset.
    # The value may carry SEVERAL dirs (ffmpeg tree + deno tree +
    # nativeLibraryDir, colon-joined by the caller) — every bundled binary
    # needs every tree (CANNOT LINK EXECUTABLE otherwise). Order preserved.
    _paths["ffmpeg_ld_path"] = None
    if ffmpeg_ld_path:
        valid = [p.strip() for p in str(ffmpeg_ld_path).split(os.pathsep)]
        valid = [d for d in valid if d and os.path.isdir(d)]
        if valid:
            _paths["ffmpeg_ld_path"] = valid[0]
            # Prepend in reverse so final PATH order matches input order.
            for d in reversed(valid):
                existing_ld = os.environ.get("LD_LIBRARY_PATH", "")
                parts = existing_ld.split(os.pathsep) if existing_ld else []
                if d not in parts:
                    os.environ["LD_LIBRARY_PATH"] = (
                        d + (os.pathsep + existing_ld if existing_ld else "")
                    )

    # Inject binary directories into PATH
    path_dirs = [bin_dir]
    for key in ("ffmpeg_path", "aria2c_path", "deno_path", "nodejs_path"):
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

    # Engine file logging must work on every platform — including Android,
    # where Chaquopy calls set_paths directly and __main__ never runs.
    # Both helpers are idempotent per directory and never raise, so a
    # logging failure can never break path configuration.
    try:
        from truestream_engine.logger import set_global_log_dir
        set_global_log_dir(os.path.join(data_dir, "logs"))
    except Exception:
        pass
    try:
        from truestream_engine.persistent import init_persistent_logging
        init_persistent_logging(os.path.join(data_dir, "logs"))
    except Exception:
        pass

    return {"success": True}


def set_update_channel(channel: str) -> dict:
    _paths["update_channel"] = channel
    return {"success": True}


def get_paths() -> dict:
    return dict(_paths)


def is_initialized() -> bool:
    return _paths["data_dir"] is not None
