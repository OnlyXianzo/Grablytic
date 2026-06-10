import sys
import json
import threading
import time
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


def poll_queues():
    while True:
        # Check active downloads and read queues
        with _downloads_lock:
            active_ids = list(_active_downloads.keys())
        
        for download_id in active_ids:
            with _downloads_lock:
                info = _active_downloads.get(download_id)
                if not info:
                    continue
                prog_q = info.get("progress_queue")
                res_q = info.get("result_queue")
            
            # Read progress queue
            if prog_q:
                while not prog_q.empty():
                    try:
                        event_str = prog_q.get_nowait()
                        # print event on a single line
                        print(event_str, flush=True)
                    except Exception:
                        break
            
            # Read result queue
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
    # If running as standard CLI tool (not persistent IPC) with command args:
    if len(sys.argv) > 1:
        command = sys.argv[1]
        if command == "bootstrap":
            print(json.dumps(bootstrap()))
        elif command == "formats" and len(sys.argv) >= 3:
            print(json.dumps(get_formats(sys.argv[2])))
        else:
            print(f"Unknown CLI command: {command}")
        return

    # Start queue polling thread
    threading.Thread(target=poll_queues, daemon=True).start()

    # Otherwise, enter persistent JSON-RPC stdin loop
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
            req_id = req.get("id")
            method = req.get("method")
            params = req.get("params", {})

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

            # Send response back
            response = {"id": req_id}
            if isinstance(res, dict) and res.get("success") is False:
                response["error"] = res
            else:
                response["result"] = res
            
            print(json.dumps(response), flush=True)

        except Exception as e:
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
    main()
