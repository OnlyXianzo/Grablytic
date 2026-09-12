import json
import threading
import os
import queue as _queue
from datetime import datetime, timezone

from yt_dlp import YoutubeDL

from truestream_engine.opts_builder import build_ydl_opts
from truestream_engine.errors import classify_error, TrueStreamError
from truestream_engine.paths import get_paths
from truestream_engine.playlist import detect_playlist
from truestream_engine.config import coerce_config
from truestream_engine.logger import get_logger, set_global_event_callback


log = get_logger("truestream_engine.downloader")

_active_downloads: dict[str, dict] = {}
_downloads_lock = threading.Lock()


def _cleanup_loop():
    import time
    while True:
        try:
            now = datetime.now(timezone.utc)
            to_remove = []
            with _downloads_lock:
                for did, info in list(_active_downloads.items()):
                    fin_at = info.get("finished_at")
                    if fin_at:
                        res_q = info.get("result_queue")
                        # Clean up immediately if the result has been read by client
                        if res_q and res_q.empty():
                            to_remove.append(did)
                        # Failsafe: clean up after 30 seconds regardless of read status
                        elif (now - fin_at).total_seconds() > 30:
                            to_remove.append(did)
                
                for did in to_remove:
                    _active_downloads.pop(did, None)
        except Exception:
            pass
        time.sleep(1.0)


threading.Thread(target=_cleanup_loop, daemon=True).start()



class YDLogger:
    """yt-dlp logger bridge. Collects error lines so single-video downloads
    can refuse a false 'finished' when post-processing failed but
    ignoreerrors swallowed it (playlists keep the old lenient behavior —
    per-item errors there are normal)."""

    def __init__(self):
        self.errors: list[str] = []

    def debug(self, msg):
        log.debug(msg)

    def info(self, msg):
        log.info(msg)

    def warning(self, msg):
        log.warn(msg)

    def error(self, msg):
        self.errors.append(str(msg)[:500])
        log.error(msg)


def _last_known_bytes(prog_q) -> int:
    """Best-effort final size from buffered progress-hook events.

    The progress hook already reported `total_bytes`/`filesize_bytes` during
    the transfer; the terminal event re-attaches the largest seen value so
    consumers of the `filesize_bytes` contract never see 0 after a good
    download. Never raises — returns 0 when nothing was observed.
    """
    last = 0
    try:
        with prog_q.mutex:
            items = list(prog_q.queue)
    except Exception:
        return 0
    for raw in items:
        try:
            ev = json.loads(raw) if isinstance(raw, str) else raw
        except Exception:
            continue
        if not isinstance(ev, dict):
            continue
        for key in ("filesize_bytes", "total_bytes"):
            try:
                val = ev.get(key)
            except Exception:
                continue
            if isinstance(val, int) and val > last:
                last = val
    return last


def download_thread(
    url: str,
    download_id: str,
    config: dict | None = None,
    network_type: str = "wifi",
    progress_queue: _queue.Queue | None = None,
    result_queue: _queue.Queue | None = None,
    cancel_event: threading.Event | None = None,
    event_callback=None,
):
    # Android bridge delivers config as a JSON string (Chaquopy Maps are
    # live HashMap proxies, not mappings). Coerce before any use.
    config = coerce_config(config)
    cancel = cancel_event or threading.Event()
    prog_q = progress_queue or _queue.Queue()
    res_q = result_queue or _queue.Queue()

    with _downloads_lock:
        # Update in place — start_download() already registered this id with
        # its thread handle; a full reassignment would drop "thread" and any
        # fields added by concurrent callers (re-audit #10).
        existing = _active_downloads.get(download_id, {})
        existing.update({
            "cancel_event": cancel,
            "progress_queue": prog_q,
            "result_queue": res_q,
            "url": url,
            "started_at": datetime.now(timezone.utc),
        })
        _active_downloads[download_id] = existing

    log.set_context(download_id=download_id)
    try:
        # Never log raw URLs: share/clipboard links routinely carry
        # signed query params (sig/lsig). Host + path is enough to
        # identify the item in diagnostics.
        safe_url = url.split("?", 1)[0] if isinstance(url, str) else "<url>"
        log.info(f"Download started: {safe_url}", extra={"download_id": download_id})
        try:
            out_dir = (get_paths().get("output_dir")
                       or get_paths().get("data_dir") or ".")
            import shutil as _shutil
            free_mb = _shutil.disk_usage(out_dir).free // (1024 * 1024)
            log.info(f"Disk output ({out_dir}): {free_mb}MB free",
                     extra={"download_id": download_id})
        except Exception:
            pass

        paths = get_paths()
        ffmpeg_path = paths.get("ffmpeg_path")
        if not ffmpeg_path or not os.path.isfile(ffmpeg_path) or not os.access(ffmpeg_path, os.X_OK):
            import shutil
            if not shutil.which("ffmpeg"):
                err_event = json.dumps({
                    "type": "event",
                    "event": "error",
                    "download_id": download_id,
                    "error_type": "ERROR_FFMPEG_MISSING",
                    "error_message": "FFmpeg binary is missing or not executable. Please run bootstrap first.",
                    "recoverable": True,
                })
                if event_callback is not None:
                    try:
                        event_callback.onEvent(err_event)
                    except Exception:
                        pass
                else:
                    res_q.put({
                        "success": False,
                        "download_id": download_id,
                        "error_type": "ERROR_FFMPEG_MISSING",
                        "error_message": "FFmpeg binary is missing or not executable. Please run bootstrap first.",
                    })
                return

        opts = build_ydl_opts(
            config=config,
            network_type=network_type,
            progress_queue=prog_q,
            download_id=download_id,
            url=url,
            event_callback=event_callback,
        )

        if get_paths().get("cache_dir"):
            opts["paths"] = opts.get("paths", {})
            opts["paths"]["temp"] = get_paths()["cache_dir"]

        ydl_logger = YDLogger()
        opts["logger"] = ydl_logger
        opts["verbose"] = True
        # One-line effective config: future "it just sat there" reports can
        # be triaged from this alone (wrong format? no aria2c? no JS?).
        try:
            js_map = opts.get("js_runtimes")
            js_name = next(iter(js_map), None) if isinstance(js_map, dict) else None
            log.info(
                f"Download config: format={opts.get('format')} "
                f"container={opts.get('merge_output_format')} "
                f"aria2c={'yes' if 'external_downloader' in opts else 'no'} "
                f"js={js_name or 'none'}",
                extra={"download_id": download_id},
            )
            # Full effective opts (sanitized) at DEBUG, only when the user
            # enabled verbose: the complete triage picture without spamming
            # default installs.
            if config.get("verbose"):
                from truestream_engine.persistent import sanitize
                log.debug(f"Effective opts: {sanitize(opts)}",
                          extra={"download_id": download_id})
        except Exception:
            pass

        ydl = YoutubeDL(opts)

        def ydl_hook(d):
            if cancel.is_set():
                raise KeyboardInterrupt("Download cancelled by user")
            return d

        ydl.add_progress_hook(ydl_hook)

        ydl.download([url])

        if cancel.is_set():
            log.warn(f"Download cancelled: {download_id}")
            terminal_event = json.dumps({
                "type": "event",
                "event": "cancelled",
                "download_id": download_id,
                "error_type": "ERROR_CANCELLED",
                "error_message": "Download cancelled by user",
            })
            if event_callback is not None:
                try:
                    event_callback.onEvent(terminal_event)
                except Exception:
                    pass
            else:
                res_q.put({
                    "success": False,
                    "download_id": download_id,
                    "error_type": "ERROR_CANCELLED",
                    "error_message": "Download cancelled by user",
                })
        else:
            # ignoreerrors=True lets post-processing failures return
            # normally — but for a SINGLE video any logger.error means the
            # output is broken (missing merge, failed embed), while the UI
            # would otherwise celebrate a 'finished' with no file.
            # Playlists keep lenient behavior: per-item errors there are
            # normal (deleted/private entries) and must not fail the batch.
            # Single = URL is not a playlist AND caller didn't request a
            # multi-item pull (playlist_items other than "1").
            try:
                is_playlist_url = detect_playlist(url) if isinstance(url, str) else False
            except Exception:
                is_playlist_url = False
            if opts.get("noplaylist") or config.get("no_playlist") or opts.get("playlist_items") == "1":
                single = True
            elif is_playlist_url:
                single = False
            else:
                single = opts.get("playlist_items") in (None, "1")
            if single and ydl_logger.errors:
                last = ydl_logger.errors[-1]
                log.error(f"Post-processing failed, failing item: {last[:200]}")
                terminal_event = json.dumps({
                    "type": "event",
                    "event": "error",
                    "download_id": download_id,
                    "error_type": "ERROR_POSTPROCESS_FAILED",
                    "error_message": f"Processing failed: {last[:200]}",
                    "recoverable": True,
                    "suggests_vpn": False,
                })
                if event_callback is not None:
                    try:
                        event_callback.onEvent(terminal_event)
                    except Exception:
                        pass
                else:
                    res_q.put({
                        "success": False,
                        "download_id": download_id,
                        "error_type": "ERROR_POSTPROCESS_FAILED",
                        "error_message": f"Processing failed: {last[:200]}",
                        "recoverable": True,
                        "suggests_vpn": False,
                    })
                return
            log.info("Download completed")
            # Terminal finished event carries the last known byte count so the
            # UI never zeroes out sizes delivered by the progress-hook
            # "finished" event (re-audit #4: filesize_bytes contract).
            final_bytes = _last_known_bytes(prog_q)
            terminal_event = json.dumps({
                "type": "event",
                "event": "finished",
                "download_id": download_id,
                "filesize_bytes": final_bytes,
                "total_bytes": final_bytes,
            })
            if event_callback is not None:
                try:
                    event_callback.onEvent(terminal_event)
                except Exception:
                    pass
            else:
                res_q.put({
                    "success": True,
                    "download_id": download_id,
                    "filesize_bytes": final_bytes,
                })

    except KeyboardInterrupt:
        log.warn(f"Download cancelled: {download_id}")
        terminal_event = json.dumps({
            "type": "event",
            "event": "cancelled",
            "download_id": download_id,
            "error_type": "ERROR_CANCELLED",
            "error_message": "Download cancelled by user",
        })
        if event_callback is not None:
            try:
                event_callback.onEvent(terminal_event)
            except Exception:
                pass
        else:
            res_q.put({
                "success": False,
                "download_id": download_id,
                "error_type": "ERROR_CANCELLED",
                "error_message": "Download cancelled by user",
            })
    except Exception as exc:
        log.log_exception(exc, f"Download failed: {safe_url}")
        err = classify_error(exc)
        terminal_event = json.dumps({
            "type": "event",
            "event": "error",
            "download_id": download_id,
            "error_type": err.error_type,
            "error_message": err.message,
            "recoverable": err.recoverable,
            # Drives ErrorRecoveryCard VPN recommendations (re-audit #5).
            "suggests_vpn": err.suggests_vpn,
        })
        if event_callback is not None:
            try:
                event_callback.onEvent(terminal_event)
            except Exception:
                pass
        else:
            res_q.put({
                "success": False,
                "download_id": download_id,
                "error_type": err.error_type,
                "error_message": err.message,
                "recoverable": err.recoverable,
                "suggests_vpn": err.suggests_vpn,
            })
    except BaseException as exc:
        # SystemExit / GeneratorExit / KeyboardInterrupt-outside-cancel and
        # friends bypass `except Exception`. Without this the item rotted as
        # "downloading" forever with zero diagnostics (ghost downloads).
        kind = type(exc).__name__
        try:
            log.error(f"Download aborted ({kind}): {download_id}")
        except Exception:
            pass
        terminal_event = json.dumps({
            "type": "event",
            "event": "error",
            "download_id": download_id,
            "error_type": "ERROR_DOWNLOADER_CRASH",
            "error_message": f"Downloader stopped unexpectedly ({kind})",
            "recoverable": True,
            "suggests_vpn": False,
        })
        if event_callback is not None:
            try:
                event_callback.onEvent(terminal_event)
            except Exception:
                pass
        else:
            res_q.put({
                "success": False,
                "download_id": download_id,
                "error_type": "ERROR_DOWNLOADER_CRASH",
                "error_message": f"Downloader stopped unexpectedly ({kind})",
                "recoverable": True,
                "suggests_vpn": False,
            })
    finally:
        log.clear_context()
        with _downloads_lock:
            if download_id in _active_downloads:
                _active_downloads[download_id]["finished_at"] = datetime.now(timezone.utc)


def start_download(
    url: str,
    download_id: str,
    config: dict | None = None,
    network_type: str = "wifi",
    event_callback=None,
) -> dict:
    progress_queue: _queue.Queue = _queue.Queue()
    result_queue: _queue.Queue = _queue.Queue()
    cancel_event: threading.Event = threading.Event()

    # Live engine-log delivery on Android/Chaquopy: push type:log events
    # through the same Kotlin callback the progress hooks use. The desktop
    # queue path is untouched (event_callback is None there).
    if event_callback is not None:
        try:
            set_global_event_callback(event_callback)
        except Exception:
            pass

    t = threading.Thread(
        target=download_thread,
        args=(url, download_id, config, network_type, progress_queue, result_queue, cancel_event, event_callback),
        daemon=True,
    )
    t.start()

    with _downloads_lock:
        _active_downloads[download_id] = {
            "cancel_event": cancel_event,
            "progress_queue": progress_queue,
            "result_queue": result_queue,
            "url": url,
            "thread": t,
            "started_at": datetime.now(timezone.utc),
        }

    return {
        "success": True,
        "download_id": download_id,
        "thread_started": True,
    }


def cancel_download(download_id: str) -> dict:
    with _downloads_lock:
        info = _active_downloads.get(download_id)
        if not info:
            return {
                "success": False,
                "error_type": "ERROR_DOWNLOAD_NOT_FOUND",
                "error_message": f"No active download with ID: {download_id}",
            }
        info["cancel_event"].set()

    return {
        "success": True,
        "download_id": download_id,
        "cancelled": True,
    }


def get_active_downloads() -> dict:
    with _downloads_lock:
        return {
            "downloads": [
                {
                    "download_id": did,
                    "url": info["url"],
                    "started_at": info["started_at"].isoformat(),
                }
                for did, info in _active_downloads.items()
            ]
        }
