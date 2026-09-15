import shutil as _shutil


def _is_abs(path) -> bool:
    """Non-empty absolute-path string (never trust cwd-relative IPC values)."""
    import os as _os
    return isinstance(path, str) and bool(path) and _os.path.isabs(path)


def _is_executable_file(path) -> bool:
    """Real executability gate: regular file AND the X_OK bit.

    `os.path.isfile` alone proves existence only (follows symlinks, says
    nothing about permissions) — and `shutil.which` already X_OK-gates, so
    only the explicit/bundled legs need this spelled out. Note the check is
    read at admission time; the use sites in `opts_builder` re-check before
    every exec (TOCTOU between check and spawn remains a documented residual
    — only fd-pinning/O_NOFOLLOW would close it, out of scope here).
    """
    import os as _os
    return bool(path) and _os.path.isfile(path) and _os.access(path, _os.X_OK)


def _is_contained(child, parent) -> bool:
    """True iff resolved `child` is strictly inside resolved `parent`.

    `realpath` on BOTH sides (symlink-safe) + `commonpath` equality — never
    a `startswith` substring test (`/data/bin_evil` shares the string prefix
    of `/data/bin` but not the path). Strict: equal-to-parent is False.
    """
    import os as _os
    try:
        real_child = _os.path.realpath(child)
        real_parent = _os.path.realpath(parent)
    except Exception:
        return False
    if real_child == real_parent:
        return False
    try:
        return _os.path.commonpath([real_parent, real_child]) == real_parent
    except ValueError:
        # Mixed absolute/relative or different drives — fail closed.
        return False


def _accept_explicit_binary(explicit) -> str | None:
    """Validate an IPC-supplied binary path. Returns resolved path or None.

    Admission rule (T0-2): absolute + resolved + regular file + X_OK.
    Deliberately NO location allowlist: custom toolchains (/opt, nix store,
    side-loaded test tmp dirs) are legitimate and common on desktop — an
    allowlist would break them while adding nothing once the PATH-prepend
    primitive below is removed (a validated path can only ever exec ITSELF
    via its absolute path; it can no longer promote its directory into the
    search order of every other binary).
    """
    import os as _os
    if not _is_abs(explicit):
        return None
    resolved = _os.path.realpath(explicit)
    if not _is_executable_file(resolved):
        return None
    return resolved


def _resolve_bin(explicit, bin_dir: str, name: str, log=None) -> str:
    """explicit → bundled → system → placeholder (all legs X_OK-gated).

    `shutil.which` executability-gates by construction (mode F_OK|X_OK), so
    the system leg needs no extra check. The placeholder is a fetch marker
    for bootstrap, never executed directly (use sites re-check X_OK).
    """
    import os as _os
    accepted = _accept_explicit_binary(explicit)
    if accepted:
        return accepted
    if explicit and log is not None:
        log.warn(f"Ignoring untrusted binary path for {name}: {explicit!r:.80}")
    bundled = _os.path.join(bin_dir, name)
    if _is_executable_file(bundled):
        return _os.path.realpath(bundled)
    system = _shutil.which(name)
    if not system and name.lower().endswith(".exe"):
        system = _shutil.which(name[:-4])
    if system:
        return system
    return bundled

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
    try:
        from grablytic_engine.logger import get_logger as _get_logger
        _log = _get_logger("grablytic_engine.paths")
    except Exception:
        _log = None

    def _warn(msg):
        try:
            if _log is not None:
                _log.warn(msg)
        except Exception:
            pass

    # T0-2: directory roots are the trust anchor for everything below
    # (bin_dir construction, site-packages containment). A non-absolute
    # root makes every derived path cwd-relative — NLTK #3642 shape — so
    # fail closed BEFORE mutating any process-global state.
    for _label, _root in (("data_dir", data_dir), ("output_dir", output_dir),
                          ("cache_dir", cache_dir)):
        if not _is_abs(_root):
            _warn(f"Rejecting paths/set: {_label} is not absolute: {_root!r:.80}")
            return {"success": False, "error": f"{_label} must be an absolute path"}

    _paths["data_dir"] = data_dir
    _paths["output_dir"] = output_dir
    _paths["cache_dir"] = cache_dir

    bin_dir = os.path.join(data_dir, "bin")
    is_windows = os.name == "nt" or (isinstance(os.environ.get("OS"), str) and "windows" in os.environ.get("OS").lower())
    ext = ".exe" if is_windows else ""

    # Resolve ffmpeg/aria2c/deno/node: explicit → bundled → system →
    # placeholder. Every leg is X_OK-gated (explicit + bundled via
    # _resolve_bin; system via shutil.which's own F_OK|X_OK gate).
    _paths["ffmpeg_path"] = _resolve_bin(ffmpeg_path, bin_dir, f"ffmpeg{ext}", _log)
    _paths["aria2c_path"] = _resolve_bin(aria2c_path, bin_dir, f"aria2c{ext}", _log)
    _paths["deno_path"] = _resolve_bin(deno_path, bin_dir, f"deno{ext}", _log)
    # (Android primary JS runtime; links cleanly on Bionic.)
    _paths["nodejs_path"] = _resolve_bin(nodejs_path, bin_dir, f"node{ext}", _log)

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
        # T0-2: absolute-only. A cwd-relative entry would resolve against an
        # unpredictable working directory into the loader search path.
        valid = [d for d in valid if d and os.path.isabs(d) and os.path.isdir(d)]
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

    # T0-2: PATH carries ONLY our own constructed bin_dir — never the
    # dirname of an explicitly-supplied binary. The old code prepended every
    # `dirname(explicit)` (so `aria2c_path=/evil/dir/x` injected `/evil/dir`
    # into the search order of all later `which()` fallbacks) and tested
    # membership as a SUBSTRING of the joined string (so a pre-existing
    # `<bin>_evil` entry silently suppressed the legit prepend). Every
    # consumer uses absolute paths now (ffmpeg_location, js_runtimes path,
    # absolute aria2c downloader value — verified against yt-dlp
    # downloader/__init__.py + external.py: basename→class lookup, full path
    # exec'd directly), so nothing legitimate needs explicit dirs on PATH.
    # Membership is per-component (split on pathsep, normalized) — never a
    # substring search on the joined string (CWE-426).
    if bin_dir not in [os.path.normcase(os.path.normpath(p)) for p in
                       os.environ.get("PATH", "").split(os.pathsep) if p]:
        os.environ["PATH"] = bin_dir + os.pathsep + os.environ.get("PATH", "")

    # Prepends site-packages to sys.path to load dynamically updated yt-dlp
    # modules. T0-2: the dir is IPC-derived, so gate it — realpath
    # containment strictly inside data_dir (kills symlink escape: a
    # site-packages symlink pointing outside resolves outside and is
    # rejected), isdir, and list membership (already correct — `in sys.path`
    # is per-element, unlike the old PATH substring test). Position 0 keeps
    # update precedence; shadowing stdlib from here requires write access to
    # app-private data_dir, which is the platform sandbox's job to prevent.
    site_packages = os.path.join(data_dir, "site-packages")
    if (_is_contained(site_packages, data_dir)
            and os.path.isdir(os.path.realpath(site_packages))
            and os.path.realpath(site_packages) not in
            [os.path.realpath(p) for p in sys.path if p and os.path.isdir(p)]
            and site_packages not in sys.path):
        sys.path.insert(0, site_packages)

    # Engine file logging must work on every platform — including Android,
    # where Chaquopy calls set_paths directly and __main__ never runs.
    # Both helpers are idempotent per directory and never raise, so a
    # logging failure can never break path configuration.
    try:
        from grablytic_engine.logger import set_global_log_dir
        set_global_log_dir(os.path.join(data_dir, "logs"))
    except Exception:
        pass
    try:
        from grablytic_engine.persistent import init_persistent_logging
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
