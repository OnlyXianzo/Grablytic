import json
import queue as _queue

from truestream_engine.logger import get_logger


_log = get_logger("truestream_engine.hooks")


# yt-dlp postprocessor hook payloads carry the PP key in `d["postprocessor"]`
# (see PostProcessor._hook_progress: pp_key() values such as "Merger",
# "ExtractAudio", "SponsorBlock"). `status` is only "started"/"finished",
# so the stage lookup MUST key on pp_key — never on status (re-audit #8).
_POSTPROCESSOR_STAGES = {
    "MoveFiles": ("moving", "Moving file into place..."),
    "Merger": ("merging", "Merging streams..."),
    "ExtractAudio": ("extracting_audio", "Extracting audio..."),
    "ThumbnailsConvertor": ("converting_thumbnail", "Converting thumbnail..."),
    "EmbedThumbnail": ("embedding_thumbnail", "Embedding thumbnail..."),
    "Metadata": ("tagging", "Writing metadata..."),
    "SplitChapters": ("splitting_chapters", "Splitting chapters..."),
    "SponsorBlock": ("marking_sponsors", "Marking sponsor segments..."),
    "ModifyChapters": ("cutting_sponsors", "Removing sponsor segments..."),
}


def build_progress_hook(queue: _queue.Queue, download_id: str, event_callback=None):
    # Thread-local context so hook lines (milestones) carry the download id
    # in `context` — the live overlay filters on it. Built on the download
    # thread, which is where hooks fire.
    _log.set_context(download_id=download_id)
    # Milestone state: bounded stall visibility (25/50/75% INFO lines) at a
    # fixed cost of ≤3 log lines per download — never per-fragment spam.
    # Closure-local: yt-dlp invokes hooks on the download thread.
    _milestones = [25, 50, 75]

    def progress_hook(d: dict):
        status = d.get("status", "")

        if status == "downloading":
            downloaded = d.get("downloaded_bytes", 0) or 0
            total = d.get("total_bytes") or d.get("total_bytes_estimate", 0) or 0
            if total > 0 and _milestones:
                pct = (downloaded * 100) // total
                while _milestones and pct >= _milestones[0]:
                    hit = _milestones.pop(0)
                    try:
                        _log.info(f"reached {hit}% ({downloaded}/{total} bytes)")
                    except Exception:
                        pass
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
            # Dual-write: the queue feeds _last_known_bytes() (terminal
            # filesize contract) even on the live-callback path; the
            # callback feeds Kotlin/Flutter. Unbounded queues here are
            # freed with the download thread, and put() never blocks.
            try:
                queue.put(event_json)
            except Exception:
                pass
            if event_callback is not None:
                try:
                    event_callback.onEvent(event_json)
                except Exception:
                    pass

        elif status == "finished":
            # Per-FILE completion (e.g. the video DASH stream landed while the
            # audio stream is still downloading) -- NOT terminal. The UI must
            # not mark the download completed here; only the downloader's
            # terminal "finished" event (after merge + post-processing) does.
            # filesize_bytes is the contract download_provider.dart reads;
            # total_bytes kept alongside for backward compatibility.
            final_bytes = d.get("total_bytes") or d.get("total_bytes_estimate", 0)
            event_json = json.dumps({
                "type": "event",
                "event": "stream_finished",
                "download_id": download_id,
                "filename": d.get("filename", ""),
                "filesize_bytes": final_bytes,
                "total_bytes": d.get("total_bytes", 0),
            })
            # Dual-write: the queue feeds _last_known_bytes() (terminal
            # filesize contract) even on the live-callback path; the
            # callback feeds Kotlin/Flutter. Unbounded queues here are
            # freed with the download thread, and put() never blocks.
            try:
                queue.put(event_json)
            except Exception:
                pass
            if event_callback is not None:
                try:
                    event_callback.onEvent(event_json)
                except Exception:
                    pass

        elif status == "error":
            event_json = json.dumps({
                "type": "event",
                "event": "error",
                "download_id": download_id,
                "error_type": "ERROR_DOWNLOAD",
                "error_message": d.get("error", "Unknown error"),
                "recoverable": True,
            })
            # Dual-write: the queue feeds _last_known_bytes() (terminal
            # filesize contract) even on the live-callback path; the
            # callback feeds Kotlin/Flutter. Unbounded queues here are
            # freed with the download thread, and put() never blocks.
            try:
                queue.put(event_json)
            except Exception:
                pass
            if event_callback is not None:
                try:
                    event_callback.onEvent(event_json)
                except Exception:
                    pass

    return progress_hook


def build_postprocessor_hook(queue: _queue.Queue, download_id: str, event_callback=None):
    def postprocessor_hook(d: dict):
        status = d.get("status", "")
        pp_key = d.get("postprocessor", "")
        stage, label = _POSTPROCESSOR_STAGES.get(pp_key, ("", "Processing..."))

        if status == "started":
            event_json = json.dumps({
                "type": "event",
                "event": "postprocessing",
                "download_id": download_id,
                "stage": stage or pp_key,
                "stage_label": label,
            })
            # Dual-write: the queue feeds _last_known_bytes() (terminal
            # filesize contract) even on the live-callback path; the
            # callback feeds Kotlin/Flutter. Unbounded queues here are
            # freed with the download thread, and put() never blocks.
            try:
                queue.put(event_json)
            except Exception:
                pass
            if event_callback is not None:
                try:
                    event_callback.onEvent(event_json)
                except Exception:
                    pass

    return postprocessor_hook
