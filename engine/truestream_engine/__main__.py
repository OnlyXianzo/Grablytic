import sys
import json
import threading
import time
import queue as _queue_module
from truestream_engine import (
    set_paths,
    bootstrap,
    get_formats,
    get_playlist_info,
    scan_resume_candidates,
    start_download,
    cancel_download,
    set_update_channel,
    update_check,
)
from truestream_engine.downloader import _active_downloads, _downloads_lock
from truestream_engine.logger import get_logger, set_global_queue, set_global_log_dir

log = get_logger("truestream_engine.main")
_log_queue: _queue_module.Queue | None = None


def poll_queues():
    while True:
        if _log_queue is not None:
            while not _log_queue.empty():
                try:
                    log_entry = _log_queue.get_nowait()
                    print(json.dumps(log_entry), flush=True)
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
                        print(event_str, flush=True)
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
                        print(json.dumps(event), flush=True)
                    except Exception:
                        break

        time.sleep(0.1)


def main():
    if len(sys.argv) > 1:
        command = sys.argv[1]
        if command == "bootstrap":
            print(json.dumps(bootstrap()))
        elif command == "formats" and len(sys.argv) >= 3:
            print(json.dumps(get_formats(sys.argv[2])))
        else:
            print(f"Unknown CLI command: {command}")
        return

    threading.Thread(target=poll_queues, daemon=True).start()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
            req_id = req.get("id")
            method = req.get("method")
            params = req.get("params", {})

            log.info(f"Method: {method}", extra={"params": params})

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
                )
                data_dir = params["data_dir"]
                set_global_log_dir(data_dir + "/logs")
                global _log_queue
                log_queue = _queue_module.Queue()
                set_global_queue(log_queue)
                _log_queue = log_queue
                res = {"success": True}
            elif method == "engine/bootstrap":
                res = bootstrap()
            elif method == "download/start":
                res = start_download(
                    url=params["url"],
                    download_id=params["download_id"],
                    config=params.get("config"),
                    network_type=params.get("network_type", "wifi")
                )
            elif method == "download/cancel":
                res = cancel_download(params["download_id"])
            elif method == "formats/get":
                res = get_formats(params["url"], params.get("config"))
            elif method == "playlist/info":
                res = get_playlist_info(params["url"], params.get("config"))
            elif method == "resume/scan":
                res = scan_resume_candidates(params["cache_dir"])
            elif method == "engine/update_check":
                res = update_check()
            elif method == "engine/set_update_channel":
                res = set_update_channel(params["channel"])
            else:
                res = {
                    "success": False,
                    "error_type": "ERROR_UNKNOWN_METHOD",
                    "error_message": f"Method {method} not found"
                }

            response = {"id": req_id}
            if isinstance(res, dict) and res.get("success") is False:
                response["error"] = res
            else:
                response["result"] = res

            print(json.dumps(response), flush=True)

        except Exception as e:
            log.log_exception(e, f"Error processing {method}")
            err_res = {
                "id": None,
                "error": {
                    "success": False,
                    "error_type": "ERROR_INTERNAL",
                    "error_message": str(e)
                }
            }
            print(json.dumps(err_res), flush=True)


if __name__ == "__main__":
    log.info("Engine started")
    main()
