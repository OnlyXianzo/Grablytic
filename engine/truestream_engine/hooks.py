import json
import queue as _queue


_POSTPROCESSOR_STAGES = {
    "after_move": ("merging", "Merging streams..."),
    "after_thumbnail": ("embedding_thumbnail", "Embedding thumbnail..."),
    "after_video": ("muxing", "Muxing video & audio..."),
    "after_audio": ("extracting_audio", "Extracting audio..."),
}


def build_progress_hook(queue: _queue.Queue, download_id: str, event_callback=None):
    def progress_hook(d: dict):
        status = d.get("status", "")

        if status == "downloading":
            event_json = json.dumps({
                "type": "event",
                "event": "downloading",
                "download_id": download_id,
                "downloaded_bytes": d.get("downloaded_bytes", 0),
                "total_bytes": d.get("total_bytes") or d.get("total_bytes_estimate", 0),
                "total_bytes_is_estimate": d.get("total_bytes") is None,
                "speed": d.get("speed", 0),
                "eta": d.get("eta", 0),
                "filename": d.get("filename", ""),
                "fragment_index": d.get("fragment_index"),
                "fragment_count": d.get("fragment_count"),
                "stream": d.get("info_dict", {}).get("__stream_type"),
            })
            if event_callback is not None:
                try:
                    event_callback.onEvent(event_json)
                except Exception:
                    pass
            else:
                queue.put(event_json)

        elif status == "finished":
            event_json = json.dumps({
                "type": "event",
                "event": "finished",
                "download_id": download_id,
                "filename": d.get("filename", ""),
                "total_bytes": d.get("total_bytes", 0),
            })
            if event_callback is not None:
                try:
                    event_callback.onEvent(event_json)
                except Exception:
                    pass
            else:
                queue.put(event_json)

        elif status == "error":
            event_json = json.dumps({
                "type": "event",
                "event": "error",
                "download_id": download_id,
                "error_type": "ERROR_DOWNLOAD",
                "error_message": d.get("error", "Unknown error"),
                "recoverable": True,
            })
            if event_callback is not None:
                try:
                    event_callback.onEvent(event_json)
                except Exception:
                    pass
            else:
                queue.put(event_json)

    return progress_hook


def build_postprocessor_hook(queue: _queue.Queue, download_id: str, event_callback=None):
    def postprocessor_hook(d: dict):
        status = d.get("status", "")
        pp_key = d.get("postprocessor", "")
        stage, label = _POSTPROCESSOR_STAGES.get(status, ("", "Processing..."))

        if status == "started":
            event_json = json.dumps({
                "type": "event",
                "event": "postprocessing",
                "download_id": download_id,
                "stage": stage or pp_key,
                "stage_label": label,
            })
            if event_callback is not None:
                try:
                    event_callback.onEvent(event_json)
                except Exception:
                    pass
            else:
                queue.put(event_json)

    return postprocessor_hook
