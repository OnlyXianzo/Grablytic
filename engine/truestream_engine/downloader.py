import json
import threading
import os
import queue as _queue
from datetime import datetime

from yt_dlp import YoutubeDL

from truestream_engine.opts_builder import build_ydl_opts
from truestream_engine.errors import classify_error, TrueStreamError
from truestream_engine.paths import get_paths
from truestream_engine.logger import get_logger


log = get_logger("truestream_engine.downloader")

_active_downloads: dict[str, dict] = {}
_downloads_lock = threading.Lock()


def _cleanup_loop():
    import time
    while True:
        try:
            now = datetime.utcnow()
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
    def debug(self, msg):
        log.debug(msg)

    def info(self, msg):
        log.info(msg)

    def warning(self, msg):
        log.warn(msg)

    def error(self, msg):
        log.error(msg)


def download_thread(
    url: str,
    download_id: str,
    config: dict | None = None,
    network_type: str = "wifi",
    progress_queue: _queue.Queue | None = None,
    result_queue: _queue.Queue | None = None,
    cancel_event: threading.Event | None = None,
):
    cancel = cancel_event or threading.Event()
    prog_q = progress_queue or _queue.Queue()
    res_q = result_queue or _queue.Queue()

    with _downloads_lock:
        _active_downloads[download_id] = {
            "cancel_event": cancel,
            "progress_queue": prog_q,
            "result_queue": res_q,
            "url": url,
            "started_at": datetime.utcnow(),
        }

    log.set_context(download_id=download_id)
    try:
        log.info(f"Download started: {url}", extra={"download_id": download_id})

        paths = get_paths()
        ffmpeg_path = paths.get("ffmpeg_path")
        if not ffmpeg_path or not os.path.isfile(ffmpeg_path) or not os.access(ffmpeg_path, os.X_OK):
            import shutil
            if not shutil.which("ffmpeg"):
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
        )

        if get_paths().get("cache_dir"):
            opts["paths"] = opts.get("paths", {})
            opts["paths"]["temp"] = get_paths()["cache_dir"]

        opts["logger"] = YDLogger()
        opts["verbose"] = True

        ydl = YoutubeDL(opts)

        def ydl_hook(d):
            if cancel.is_set():
                raise KeyboardInterrupt("Download cancelled by user")
            return d

        ydl.add_progress_hook(ydl_hook)

        ydl.download([url])

        if cancel.is_set():
            log.warn(f"Download cancelled: {download_id}")
            res_q.put({
                "success": False,
                "download_id": download_id,
                "error_type": "ERROR_CANCELLED",
                "error_message": "Download cancelled by user",
            })
        else:
            log.info("Download completed")
            res_q.put({
                "success": True,
                "download_id": download_id,
            })

    except KeyboardInterrupt:
        log.warn(f"Download cancelled: {download_id}")
        res_q.put({
            "success": False,
            "download_id": download_id,
            "error_type": "ERROR_CANCELLED",
            "error_message": "Download cancelled by user",
        })
    except Exception as exc:
        log.log_exception(exc, f"Download failed: {url}")
        err = classify_error(exc)
        res_q.put({
            "success": False,
            "download_id": download_id,
            "error_type": err.error_type,
            "error_message": err.message,
            "recoverable": err.recoverable,
        })
    finally:
        log.clear_context()
        with _downloads_lock:
            if download_id in _active_downloads:
                _active_downloads[download_id]["finished_at"] = datetime.utcnow()


def start_download(
    url: str,
    download_id: str,
    config: dict | None = None,
    network_type: str = "wifi",
) -> dict:
    progress_queue: _queue.Queue = _queue.Queue()
    result_queue: _queue.Queue = _queue.Queue()
    cancel_event: threading.Event = threading.Event()

    t = threading.Thread(
        target=download_thread,
        args=(url, download_id, config, network_type, progress_queue, result_queue, cancel_event),
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
            "started_at": datetime.utcnow(),
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
