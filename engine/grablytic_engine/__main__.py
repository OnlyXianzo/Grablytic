import sys
import json
import threading
import time
import queue as _queue_module
from grablytic_engine import (
    set_paths,
    bootstrap,
    get_formats,
    get_playlist_info,
    search,
    scan_resume_candidates,
    start_download,
    cancel_download,
    get_queue_status,
    set_max_concurrent,
    clear_download_archive,
    set_update_channel,
    update_check,
    shutdown_downloads,
)
from grablytic_engine.downloader import _active_downloads, _downloads_lock
from grablytic_engine.logger import get_logger, set_global_queue, set_global_log_dir
from grablytic_engine.persistent import (
    init_persistent_logging,
    get_std_logger,
    traced_request,
    flush_now as persistent_flush,
)

log = get_logger("grablytic_engine.main")
_log_queue: _queue_module.Queue | None = None
_stdout_lock = threading.Lock()


def _write_stdout_line(line_str: str) -> None:
    """Atomically write and flush a line to stdout under _stdout_lock.

    Prevents interleaved JSON output between the background poll_queues
    thread and main request/response handling. Interleaved JSON lines
    corrupt the client/Dart JSON parser.
    """
    if not line_str.endswith("\n"):
        line_str += "\n"
    with _stdout_lock:
        sys.stdout.write(line_str)
        sys.stdout.flush()


def poll_queues():
    while True:
        if _log_queue is not None:
            while not _log_queue.empty():
                try:
                    log_entry = _log_queue.get_nowait()
                    _write_stdout_line(json.dumps(log_entry))
                except Exception:
                    break

        with _downloads_lock:
            active_ids = list(_active_downloads.keys())

        for download_id in active_ids:
            with _downloads_lock:
                info = _active_downloads.get(download_id)
                if not info:
                    continue
                prog_q = info.get("progress_queue")
                res_q = info.get("result_queue")

            if prog_q:
                while not prog_q.empty():
                    try:
                        event_str = prog_q.get_nowait()
                        _write_stdout_line(event_str)
                    except Exception:
                        break

            if res_q:
                while not res_q.empty():
                    try:
                        res = res_q.get_nowait()
                        is_success = res.get("success", False)
                        if is_success:
                            event = {
                                "type": "event",
                                "event": "finished",
                                "download_id": download_id,
                                "filesize_bytes": res.get("filesize_bytes", 0),
                                "total_bytes": res.get("filesize_bytes", 0),
                                "file_path": res.get("file_path"),
                                "thumbnail_path": res.get("thumbnail_path"),
                            }
                        elif res.get("error_type") == "ERROR_CANCELLED":
                            # Parity with Android: user cancellation is a
                            # distinct "cancelled" event, never an "error"
                            # (re-audit #3; download_provider.dart:172).
                            event = {
                                "type": "event",
                                "event": "cancelled",
                                "download_id": download_id,
                                "error_type": "ERROR_CANCELLED",
                                "error_message": res.get("error_message", "Download cancelled by user"),
                            }
                        else:
                            event = {
                                "type": "event",
                                "event": "error",
                                "download_id": download_id,
                                "error_type": res.get("error_type", "ERROR_UNKNOWN"),
                                "error_message": res.get("error_message", "Unknown error"),
                                "recoverable": res.get("recoverable", True),
                                "suggests_vpn": res.get("suggests_vpn", False),
                            }
                        _write_stdout_line(json.dumps(event))
                    except Exception:
                        break

        time.sleep(0.1)


def main():
    if len(sys.argv) > 1:
        command = sys.argv[1]
        if command == "bootstrap":
            _write_stdout_line(json.dumps(bootstrap()))
        elif command == "formats" and len(sys.argv) >= 3:
            _write_stdout_line(json.dumps(get_formats(sys.argv[2])))
        else:
            _write_stdout_line(f"Unknown CLI command: {command}")
        return

    threading.Thread(target=poll_queues, daemon=True).start()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        # Bound before parsing: a malformed line must produce an error
        # envelope, never an UnboundLocalError that kills the whole loop.
        req_id = None
        method = "<unparsed>"
        params = {}
        try:
            req = json.loads(line)
            req_id = req.get("id")
            method = req.get("method")
            params = req.get("params", {})

            log.info(f"Method: {method}", extra={"params": params})

            # Sanitized copy for the rotating handler (never raw secrets).
            try:
                from grablytic_engine.persistent import sanitize as _sanitize
                get_std_logger().debug(">> %s params=%s",
                                       method, _sanitize(params))
            except Exception:
                pass

            res = None
            if method == "paths/set":
                set_paths(
                    data_dir=params["data_dir"],
                    output_dir=params["output_dir"],
                    ffmpeg_path=params.get("ffmpeg_path"),
                    cache_dir=params["cache_dir"],
                    cookies_path=params.get("cookies_path"),
                    aria2c_path=params.get("aria2c_path"),
                    deno_path=params.get("deno_path"),
                    po_token=params.get("po_token"),
                    ffmpeg_ld_path=params.get("ffmpeg_ld_path"),
                )
                data_dir = params["data_dir"]
                set_global_log_dir(data_dir + "/logs")
                global _log_queue
                log_queue = _queue_module.Queue()
                set_global_queue(log_queue)
                _log_queue = log_queue
                # Persistent rotating log (STEP 3B): server_logs.log + 30s
                # flush worker live alongside the legacy daily JSONL file.
                try:
                    init_persistent_logging(data_dir + "/logs")
                except Exception:
                    pass
                res = {"success": True}
            else:
                # Request/response middleware boundary (STEP 3B): latency,
                # sanitized payloads and full tracebacks via traced_request.
                def _dispatch():
                    if method == "engine/bootstrap":
                        return bootstrap()
                    elif method == "download/start":
                        return start_download(
                            url=params["url"],
                            download_id=params["download_id"],
                            config=params.get("config"),
                            network_type=params.get("network_type", "wifi")
                        )
                    elif method == "download/cancel":
                        return cancel_download(params["download_id"])
                    elif method == "download/queue_status":
                        return {"success": True, **get_queue_status()}
                    elif method == "download/set_concurrency":
                        return set_max_concurrent(params.get("max_concurrent", 2))
                    elif method == "download/clear_archive":
                        return clear_download_archive(params.get("archive_path"))
                    elif method == "formats/get":
                        return get_formats(params["url"], params.get("config"))
                    elif method == "playlist/info":
                        return get_playlist_info(params["url"], params.get("config"))
                    elif method == "search/query":
                        return search(
                            query=params.get("query", ""),
                            site=params.get("site", "youtube"),
                            limit=params.get("limit", 20),
                            config=params.get("config"),
                        )
                    elif method == "resume/scan":
                        return scan_resume_candidates(params["cache_dir"])
                    elif method == "engine/update_check":
                        return update_check()
                    elif method == "engine/set_update_channel":
                        return set_update_channel(params["channel"])
                    else:
                        return {
                            "success": False,
                            "error_type": "ERROR_UNKNOWN_METHOD",
                            "error_message": f"Method {method} not found"
                        }

                try:
                    std_log = get_std_logger()
                except Exception:
                    std_log = None  # type: ignore[assignment]
                res = traced_request(
                    str(method), params if isinstance(params, dict) else {},
                    _dispatch, logger=std_log, engine_log=log,
                )

            response = {"id": req_id}
            if isinstance(res, dict) and res.get("success") is False:
                response["error"] = res
            else:
                response["result"] = res

            _write_stdout_line(json.dumps(response))

        except Exception as e:
            log.log_exception(e, f"Error processing {method}")
            try:
                persistent_flush()
            except Exception:
                pass
            # Opt-in auto-report (STEP 3C): gated by GRABLYTIC_AUTO_REPORT=1
            # inside notify_exception; never blocks the error response.
            try:
                from grablytic_engine.github_notifier import notify_exception
                notify_exception(e, context={"method": str(method)})
            except Exception:
                pass
            err_res = {
                "id": req_id,
                "error": {
                    "success": False,
                    "error_type": "ERROR_INTERNAL",
                    "error_message": str(e)
                }
            }
            _write_stdout_line(json.dumps(err_res))

    # Gracefully shut down any in-flight downloads on EOF/exit
    try:
        shutdown_downloads(timeout=5.0)
    except Exception:
        pass


if __name__ == "__main__":
    log.info("Engine started")
    main()
