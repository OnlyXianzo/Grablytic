import json
import queue as _queue
import time as _time

from grablytic_engine.logger import get_logger


_log = get_logger("grablytic_engine.hooks")

# Loop-2 source throttle (mirrors yt-dlp --progress-delta, which yt-dlp only
# applies to its own console output, not to progress_hooks): per-block hook
# ticks at 8k-32k per stream serialize json + JNI + Dart decode + rebuilds.
# Emit at most ~1/s or on >=1% movement; counters are absolute so dropped
# ticks lose nothing, and bars interpolate between samples.
_PROGRESS_MIN_INTERVAL_S = 1.0
_PROGRESS_MIN_PCT_DELTA = 1.0

# Loop-2 retention bound: the queue's only contract is latest-known-bytes at
# finish (_drain_public). Unbounded growth retained tens of thousands of JSON
# strings per large download on Android (nothing drains until finish), then
# an O(n) drain+restore paused the merge. Drop-oldest keeps memory constant.
_QUEUE_MAXSIZE = 500


def _put_bounded(q: _queue.Queue, item: str) -> None:
    """Enqueue without ever blocking the download thread.

    Rare terminal events (stream_finished/error) must not wedge behind a
    full queue of progress ticks: evict oldest and retry. Never raises.
    """
    try:
        q.put_nowait(item)
        return
    except Exception:
        pass
    try:
        q.get_nowait()
    except Exception:
        pass
    try:
        q.put_nowait(item)
    except Exception:
        pass

# Set on the first failed callback delivery per process. Every delivery
# fault is otherwise silent by design — but total silence is exactly how
# "0% forever with a finished file on disk" happens, so the first one
# warns loudly (method + error), implicating either the Chaquopy proxy
# (R8-stripped?) or the Kotlin sink.
_callback_failed_once = False


def _emit_event(event_callback, event_json: str) -> None:
    """Deliver one event via the Chaquopy callback. Never raises."""
    if event_callback is None:
        return
    try:
        event_callback.onEvent(event_json)
    except Exception as exc:
        global _callback_failed_once
        if not _callback_failed_once:
            _callback_failed_once = True
            try:
                _log.warn(
                    f"Engine event callback failing ({type(exc).__name__}: "
                    f"{exc}); progress UI will stall while downloads continue"
                )
            except Exception:
                pass


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
    # Loop-2 sampler state (closure-local, same thread as the hook).
    _sample = {"next_t": 0.0, "last_pct": -1.0}

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
                        _log.info(f"reached {hit}% ({downloaded}/{total} bytes)", extra={"download_id": download_id})
                    except Exception:
                        pass
            # Loop-2 gate: admit first tick, then ≥1s or ≥1% movement.
            # Unknown totals (pct<0) admit on time only.
            pct_f = (downloaded * 100.0 / total) if total > 0 else -1.0
            now = _time.monotonic()
            if not (now >= _sample["next_t"]
                    or abs(pct_f - _sample["last_pct"]) >= _PROGRESS_MIN_PCT_DELTA):
                return
            _sample["next_t"] = now + _PROGRESS_MIN_INTERVAL_S
            _sample["last_pct"] = pct_f
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
            # callback feeds Kotlin/Flutter. Bounded drop-oldest (Loop-2):
            # never blocks, never grows without bound.
            _put_bounded(queue, event_json)
            _emit_event(event_callback, event_json)

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
            # callback feeds Kotlin/Flutter. Bounded drop-oldest (Loop-2):
            # never blocks, never grows without bound.
            _put_bounded(queue, event_json)
            _emit_event(event_callback, event_json)

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
            # callback feeds Kotlin/Flutter. Bounded drop-oldest (Loop-2):
            # never blocks, never grows without bound.
            _put_bounded(queue, event_json)
            _emit_event(event_callback, event_json)

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
            # callback feeds Kotlin/Flutter. Bounded drop-oldest (Loop-2):
            # never blocks, never grows without bound.
            _put_bounded(queue, event_json)
            _emit_event(event_callback, event_json)

    return postprocessor_hook
