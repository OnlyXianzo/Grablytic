import json
import threading
import time
import os
import queue as _queue
import uuid
from collections import deque
from datetime import datetime, timezone

from yt_dlp import YoutubeDL

from grablytic_engine.opts_builder import build_ydl_opts
from grablytic_engine.errors import classify_error, GrablyticError
from grablytic_engine.hooks import _QUEUE_MAXSIZE, _emit_event, _put_bounded
from grablytic_engine.paths import get_paths
from grablytic_engine.playlist import detect_playlist
from grablytic_engine.config import coerce_config
from grablytic_engine.logger import (
    download_context,
    get_logger,
    set_global_event_callback,
    EngineLogger,
)


log = get_logger("grablytic_engine.downloader")

_active_downloads: dict[str, dict] = {}
_downloads_lock = threading.Lock()

# ── Download queue / concurrency gate (Milestone 1) ──────────────────────
# Verified approach: default 2 concurrent (Seal-proven 3, YTDLnis default 1,
# 10 proven crash-prone), user-configurable 1–5, FIFO promotion, Dart owns
# admission UI while this semaphore is the airtight backstop for direct
# engine callers. Single-ID FGS collapse + GIL/FFmpeg oversubscription are
# the failure modes this prevents.
_DEFAULT_MAX_CONCURRENT = 2
_ABSOLUTE_MAX_CONCURRENT = 5
_max_concurrent = _DEFAULT_MAX_CONCURRENT
_MAX_PENDING_QUEUE = 500
# FIFO of parked entries: each holds download_id/url/config/network_type/
# progress_queue/result_queue/cancel_event/event_callback/queued_at.
_pending_queue: list[dict] = []

# ── FFmpeg post-processing serializer ────────────────────────────────────
# Multiple concurrent downloads downloading over network is fine, but when
# they finish, running multiple native FFmpeg remux/merge processes in parallel
# pins all CPU cores to 100%, causing device lag, UI freezing, thermal
# throttling, and Android LMK (Low Memory Killer) crashes.
# We serialize FFmpeg execution with a process-wide semaphore so only one
# FFmpeg invocation runs at a time across all active downloads.
# Timed acquire (item 7): a bare `with` lets one hung merge wedge EVERY later
# download's post-processing forever. The waiter fails fast with a clear
# error for THAT download while the gate stays usable for the next one.
# 600s: ~10x a worst-case low-end 4K remux (seconds to a few minutes even
# throttled), so legit slow merges pass, while a genuine hang is still
# bounded instead of forever.
_FFMPEG_GATE_TIMEOUT = 600.0
_ffmpeg_semaphore = threading.Semaphore(1)
_ffmpeg_patched = False
_ffmpeg_patch_lock = threading.Lock()


def _ensure_ffmpeg_serialized() -> None:
    global _ffmpeg_patched
    if _ffmpeg_patched:
        return
    with _ffmpeg_patch_lock:
        if _ffmpeg_patched:
            return
        try:
            import yt_dlp.postprocessor.ffmpeg as yt_ffmpeg
            orig_real_run_ffmpeg = yt_ffmpeg.FFmpegPostProcessor.real_run_ffmpeg

            def serialized_real_run_ffmpeg(self, *args, **kwargs):
                acquired = _ffmpeg_semaphore.acquire(timeout=_FFMPEG_GATE_TIMEOUT)
                if not acquired:
                    # NOTE: wording avoids "timeout"/"timed out" so
                    # classify_error() does not misroute this to
                    # ERROR_NETWORK (transient list); it surfaces as
                    # ERROR_UNKNOWN (recoverable) with a Retry action.
                    msg = (
                        "FFmpeg post-processing busy: another merge still "
                        f"running after {int(_FFMPEG_GATE_TIMEOUT)}s; "
                        "please retry the download"
                    )
                    log.warn(msg)
                    raise RuntimeError(msg)
                try:
                    return orig_real_run_ffmpeg(self, *args, **kwargs)
                finally:
                    _ffmpeg_semaphore.release()

            yt_ffmpeg.FFmpegPostProcessor.real_run_ffmpeg = serialized_real_run_ffmpeg
            _ffmpeg_patched = True
        except Exception as e:
            log.warning(f"Failed to serialize FFmpeg postprocessor: {e}")


_ensure_ffmpeg_serialized()


def set_max_concurrent(n) -> dict:
    """Set max simultaneous downloads, clamped to 1–5. Returns new limit."""
    global _max_concurrent
    try:
        n = int(n)
    except Exception:
        n = _DEFAULT_MAX_CONCURRENT
    with _downloads_lock:
        old_max = _max_concurrent
        _max_concurrent = max(1, min(_ABSOLUTE_MAX_CONCURRENT, n))
        increased = _max_concurrent > old_max
    if increased:
        try:
            _pump_queue()
        except Exception:
            pass
    return {"success": True, "max_concurrent": _max_concurrent}


def _new_slot_token() -> str:
    """Unique generation identity for one slot admission (BRUTAL-2a)."""
    return uuid.uuid4().hex


def _close_own_slot(download_id: str, slot_token) -> bool:
    """Stamp finished_at only if the entry still belongs to this generation.

    Returns True when this caller owned (and just closed) the slot. A stale
    worker whose id was reused, or a watchdog firing after a fast retry,
    gets False and must not emit, stamp, or pump. Legacy records without a
    token match token None (today's unconditional stamp behavior).
    Idempotent: an already-terminal entry returns False so a watchdog
    close followed by the late worker finally cannot double-pump.
    """
    with _downloads_lock:
        info = _active_downloads.get(download_id)
        if info is None:
            return False
        if info.get("slot_token") != slot_token:
            return False
        if info.get("finished_at"):
            return False
        info["finished_at"] = datetime.now(timezone.utc)
        return True


def _running_count() -> int:
    """Active (non-terminal) downloads. Caller should hold _downloads_lock
    or accept a best-effort snapshot."""
    count = 0
    for info in _active_downloads.values():
        if not info.get("finished_at"):
            count += 1
    return count


def _is_audio_mode(config) -> bool:
    """True when this download produces an audio-only artifact. Never raises
    (Chaquopy proxies / garbage configs fall back to video mode)."""
    try:
        return bool((config or {}).get("audio_only", False))
    except Exception:
        return False


def _find_live_url_holder(url: str, audio_only: bool):
    """ID of a live (non-terminal) active-or-queued download for the same
    (url, audio-mode), or None. Caller must hold _downloads_lock. T1-5."""
    for did, info in _active_downloads.items():
        if info.get("finished_at"):
            continue
        if info.get("url") == url and bool(info.get("audio_only", False)) == audio_only:
            return did
    for e in _pending_queue:
        if e.get("url") == url and _is_audio_mode(e.get("config")) == audio_only:
            return e.get("download_id")
    return None


def get_queue_status() -> dict:
    with _downloads_lock:
        return {
            "success": True,
            "active": [did for did, info in _active_downloads.items()
                       if not info.get("finished_at")],
            "queued": [e["download_id"] for e in _pending_queue],
            "max_concurrent": _max_concurrent,
        }


def _spawn_thread(entry: dict) -> threading.Thread | None:
    # T1-1 fix: register in the active map BEFORE starting the thread.
    # Without this, a fast cancel/finish between t.start() and map
    # registration hits NOT_FOUND while the thread is already running.
    cancel_event = entry["cancel_event"]
    download_id = entry["download_id"]

    if cancel_event.is_set():
        # BRUTAL-2a: close only our own generation (helper locks internally).
        with _downloads_lock:
            rec = _active_downloads.get(download_id)
            own_token = rec.get("slot_token") if isinstance(rec, dict) else None
        owned = _close_own_slot(download_id, own_token)
        if owned:
            terminal = json.dumps({
                "type": "event",
                "event": "cancelled",
                "download_id": download_id,
                "error_type": "ERROR_CANCELLED",
                "error_message": "Download cancelled by user",
            })
            cb = entry.get("event_callback")
            if cb is not None:
                try:
                    _emit_event(cb, terminal)
                except Exception:
                    pass
            else:
                try:
                    entry["result_queue"].put({
                        "success": False,
                        "download_id": download_id,
                        "error_type": "ERROR_CANCELLED",
                        "error_message": "Download cancelled by user",
                    })
                except Exception:
                    pass
            try:
                _pump_queue()
            except Exception:
                pass
        return None

    with _downloads_lock:
        if download_id not in _active_downloads:
            _active_downloads[download_id] = {
                "cancel_event": cancel_event,
                "progress_queue": entry["progress_queue"],
                "result_queue": entry["result_queue"],
                "url": entry["url"],
                "audio_only": _is_audio_mode(entry.get("config")),
                "thread": None,  # set after start
                "started_at": datetime.now(timezone.utc),
                "slot_token": _new_slot_token(),
                "event_callback": entry.get("event_callback"),
            }
        else:
            if "event_callback" not in _active_downloads[download_id] and entry.get("event_callback") is not None:
                _active_downloads[download_id]["event_callback"] = entry.get("event_callback")
        # BRUTAL-2a: generation identity is fixed at registration (before
        # start) so the worker's finally-block can prove ownership even if
        # the entry is replaced under the same id mid-flight.
        slot_token = _active_downloads[download_id].get("slot_token")
    t = threading.Thread(
        target=download_thread,
        args=(entry["url"], download_id, entry["config"],
              entry["network_type"], entry["progress_queue"],
              entry["result_queue"], cancel_event,
              entry["event_callback"], slot_token),
        daemon=True,
    )
    try:
        t.start()
    except Exception as exc:
        log.error(f"Failed to start download thread: {exc}", extra={"download_id": download_id})
        _close_own_slot(download_id, slot_token)
        err_event = json.dumps({
            "type": "event",
            "event": "error",
            "download_id": download_id,
            "error_type": "ERROR_THREAD_SPAWN",
            "error_message": f"Could not start downloader thread: {exc}",
            "recoverable": True,
            "suggests_vpn": False,
        })
        cb = entry.get("event_callback")
        if cb is not None:
            try:
                _emit_event(cb, err_event)
            except Exception:
                pass
        else:
            try:
                entry["result_queue"].put({
                    "success": False,
                    "download_id": download_id,
                    "error_type": "ERROR_THREAD_SPAWN",
                    "error_message": f"Could not start downloader thread: {exc}",
                    "recoverable": True,
                    "suggests_vpn": False,
                })
            except Exception:
                pass
        try:
            _pump_queue()
        except Exception:
            pass
        return None

    with _downloads_lock:
        if download_id in _active_downloads:
            _active_downloads[download_id]["thread"] = t
    return t


def _pump_queue() -> None:
    """Promote FIFO-parked entries while slots are free. Runs after any
    terminal transition and after limit increases."""
    while True:
        with _downloads_lock:
            if _running_count() >= _max_concurrent or not _pending_queue:
                return
            entry = _pending_queue.pop(0)
            did = entry["download_id"]
            if did in _active_downloads and not _active_downloads[did].get("finished_at"):
                # Superseded (cancelled/replaced) while parked — skip.
                continue
            # T1-2 fix: Atomically move from _pending_queue into _active_downloads
            # under the exact same lock so there is no window where the ID is in neither.
            _active_downloads[did] = {
                "cancel_event": entry["cancel_event"],
                "progress_queue": entry["progress_queue"],
                "result_queue": entry["result_queue"],
                "url": entry["url"],
                "audio_only": _is_audio_mode(entry.get("config")),
                "thread": None,
                "started_at": datetime.now(timezone.utc),
                "slot_token": _new_slot_token(),
                "event_callback": entry.get("event_callback"),
            }
        try:
            _spawn_thread(entry)
            if entry["cancel_event"].is_set():
                continue
            promotion = json.dumps({
                "type": "event",
                "event": "downloading",
                "download_id": did,
                "promoted_from_queue": True,
            })
            if entry.get("event_callback") is not None:
                try:
                    _emit_event(entry["event_callback"], promotion)
                except Exception:
                    pass
            else:
                # Desktop has no callback: make promotion pollable or the
                # client that received queued:true waits until terminal.
                try:
                    _put_bounded(entry["progress_queue"], promotion)
                except Exception:
                    try:
                        entry["progress_queue"].put_nowait(promotion)
                    except Exception:
                        pass
        except Exception:
            try:
                log.error(
                    f"Queued promotion failed: {entry.get('download_id')}",
                    extra={"download_id": entry.get("download_id")},
                )
            except Exception:
                pass


# ── Lazy cleanup thread and graceful shutdown (T1-6) ───────────────────

# Store real Thread reference at import time so test monkeypatching of
# threading.Thread for download workers does not hijack the internal cleanup loop.
_real_Thread = threading.Thread
_cleanup_thread: threading.Thread | None = None
_cleanup_stop_event = threading.Event()
_shutdown_lock = threading.Lock()
_is_shutting_down = False


def _is_alive(t) -> bool:
    """Safe check whether a thread (or mock object) is alive."""
    if t is None:
        return False
    fn = getattr(t, "is_alive", None)
    if callable(fn):
        try:
            return bool(fn())
        except Exception:
            return False
    return False


def _ensure_cleanup_thread() -> None:
    """Lazily start the background cleanup loop only when downloads exist.
    Avoids spinning an import-time background thread in tests and Chaquopy.
    """
    global _cleanup_thread
    with _downloads_lock:
        if _cleanup_thread is None or not _is_alive(_cleanup_thread):
            _cleanup_stop_event.clear()
            _cleanup_thread = _real_Thread(
                target=_cleanup_loop,
                daemon=True,
                name="grablytic-cleanup",
            )
            _cleanup_thread.start()


def stop_cleanup_thread() -> None:
    """Stop the background cleanup loop (used on shutdown and in test cleanup)."""
    global _cleanup_thread
    _cleanup_stop_event.set()
    with _downloads_lock:
        t = _cleanup_thread
        _cleanup_thread = None
    if t and _is_alive(t) and threading.current_thread() != t:
        join_fn = getattr(t, "join", None)
        if callable(join_fn):
            try:
                join_fn(timeout=2.0)
            except Exception:
                pass


def _cleanup_loop():
    while not _cleanup_stop_event.is_set():
        try:
            now = datetime.now(timezone.utc)
            to_remove = []
            with _downloads_lock:
                for did, info in list(_active_downloads.items()):
                    fin_at = info.get("finished_at")
                    if fin_at:
                        res_q = info.get("result_queue")
                        # NOTE (BRUTAL-2c audit): Queue.empty() is safe HERE
                        # because (a) this whole scan runs under
                        # _downloads_lock, same lock as admission, so no
                        # entry swap can interleave the check and the pop;
                        # (b) every admission mints FRESH queue objects, so a
                        # reused id can never append to this res_q; (c) the
                        # worker always puts its terminal BEFORE stamping
                        # finished_at, so empty()==True on a finished entry
                        # means the result was read (or never existed) — it
                        # cannot mean "result still in flight".
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
        _cleanup_stop_event.wait(1.0)


def shutdown_downloads(timeout: float = 5.0) -> dict:
    """Gracefully shut down all active downloads on engine/interpreter exit.

    T1-6 fix: Prevents mid-write daemon thread kills that leave corrupt .part
    files.
    1. Sets cancel_event for all active downloads to request clean exit.
    2. Clears pending queue so queued items never spawn.
    3. Joins active download threads up to timeout seconds.
    4. Stops the cleanup loop.
    5. Returns dict with 'joined' and 'timed_out' download IDs.
    """
    global _is_shutting_down
    with _shutdown_lock:
        _is_shutting_down = True

    # Stop the cleanup loop
    _cleanup_stop_event.set()

    with _downloads_lock:
        _pending_queue.clear()
        active = [
            (did, info) for did, info in list(_active_downloads.items())
            if not info.get("finished_at")
        ]
        # Signal cooperative cancellation to all in-flight downloads
        for did, info in active:
            try:
                info["cancel_event"].set()
            except Exception:
                pass

    deadline = time.time() + timeout
    joined = []
    timed_out = []

    for did, info in active:
        t = info.get("thread")
        if t and _is_alive(t) and threading.current_thread() != t:
            remaining = max(0.05, deadline - time.time())
            join_fn = getattr(t, "join", None)
            if callable(join_fn):
                try:
                    join_fn(timeout=remaining)
                except Exception:
                    pass
            if _is_alive(t):
                timed_out.append(did)
            else:
                joined.append(did)
        else:
            joined.append(did)

    return {
        "success": True,
        "joined": joined,
        "timed_out": timed_out,
    }


def reset_shutdown_for_tests() -> None:
    """Reset shutdown state so subsequent tests can start downloads."""
    global _is_shutting_down
    with _shutdown_lock:
        _is_shutting_down = False
    _cleanup_stop_event.clear()


import atexit as _atexit
_atexit.register(shutdown_downloads)



import re

_PATH_PATTERNS = [
    re.compile(r'\[download\]\s+(.*?)\s+has already been downloaded'),
    re.compile(r'\[download\]\s+Destination:\s+(.*)'),
    re.compile(r'\[Merger\]\s+Merging formats into\s+"([^"]+)"'),
    re.compile(r'\[MoveFiles\]\s+Moving file.*?\s+to\s+"?([^"]+)"?'),
    re.compile(r'\[EmbedThumbnail\]\s+ffmpeg:\s+Adding thumbnail to\s+"([^"]+)"'),
    re.compile(r'\[Metadata\]\s+Adding metadata to\s+"([^"]+)"'),
    re.compile(r'\[FixupM3u8\]\s+Fixing code of\s+"([^"]+)"'),
]


class YDLogger:
    """yt-dlp logger bridge. Collects error lines and tracks output file paths."""

    # T3-9: bound the tail — ignoreerrors playlists can log thousands of
    # entries. Most-recent retained (diagnostically relevant). output_files
    # is capped high enough for legit big playlists but can never grow
    # without bound; a set gives O(1) dedup instead of O(n) list scans.
    MAX_ERRORS = 200
    MAX_OUTPUT_FILES = 2000

    def __init__(self, logger: EngineLogger | None = None, download_id: str | None = None):
        self.logger = logger if logger is not None else log
        self.download_id = download_id
        self.errors: deque[str] = deque(maxlen=self.MAX_ERRORS)
        self.output_files: list[str] = []
        self._output_seen: set[str] = set()

    def _extract_path(self, msg):
        if not isinstance(msg, str):
            return
        for pat in _PATH_PATTERNS:
            m = pat.search(msg)
            if m:
                candidate = m.group(1).strip().strip('"').strip("'")
                if candidate and candidate not in self._output_seen:
                    self._output_seen.add(candidate)
                    if len(self.output_files) >= self.MAX_OUTPUT_FILES:
                        self.output_files.pop(0)
                    self.output_files.append(candidate)
                break

    def debug(self, msg):
        self._extract_path(msg)
        extra = {"download_id": self.download_id} if self.download_id else None
        self.logger.debug(msg, extra=extra)

    def info(self, msg):
        self._extract_path(msg)
        extra = {"download_id": self.download_id} if self.download_id else None
        self.logger.info(msg, extra=extra)

    def warning(self, msg):
        extra = {"download_id": self.download_id} if self.download_id else None
        self.logger.warn(msg, extra=extra)

    def error(self, msg):
        self.errors.append(str(msg)[:500])
        extra = {"download_id": self.download_id} if self.download_id else None
        self.logger.error(msg, extra=extra)


def _drain_public(prog_q) -> list:
    """Snapshot buffered progress events using only the public Queue API.

    T3-8: the old prog_q.mutex/prog_q.queue reach-through depended on
    CPython internals (and scaled the locked section with playlist size).
    Drain + restore preserves every item in order; a producer racing us
    only perturbs best-effort ordering, never loses items — we re-queue
    exactly what we drained. Queues without a public drain interface
    yield an empty snapshot (same fallback as before).
    """
    items: list = []
    get = getattr(prog_q, "get_nowait", None)
    put = getattr(prog_q, "put", None)
    if not callable(get) or not callable(put):
        return items
    while True:
        try:
            items.append(get())
        except _queue.Empty:
            break
        except Exception:
            break
    for it in items:
        try:
            put(it)
        except Exception:
            break
    return items


def _last_known_file_info(prog_q) -> tuple[int, str | None]:
    """Best-effort final size and file path from buffered progress-hook events."""
    last_bytes = 0
    last_file = None
    items = _drain_public(prog_q)
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
            if isinstance(val, int) and val > last_bytes:
                last_bytes = val
        fn = ev.get("filename")
        if isinstance(fn, str) and fn:
            last_file = fn
    return last_bytes, last_file


def _last_known_bytes(prog_q) -> int:
    """Best-effort final size from buffered progress-hook events."""
    bytes_val, _ = _last_known_file_info(prog_q)
    return bytes_val


_THUMB_EXTS = (".jpg", ".jpeg", ".png", ".webp")


def _find_thumbnail_path(final_path: str | None, config: dict | None = None) -> str | None:
    """Locate the writethumbnail sidecar for a finished download.

    yt-dlp writes the thumbnail next to the media file under the media
    basename with an image extension (``prepare_filename(info, 'thumbnail')``;
    the EmbedThumbnail PP keeps it only when ``already_have_thumbnail`` is
    true — see opts_builder). Probe the configured ``thumbnail_format``
    first, then the other known extensions. Pure filesystem check, never
    raises — returns None when there is nothing to report.
    """
    try:
        if not final_path or not isinstance(final_path, str):
            return None
        if not os.path.isfile(final_path):
            return None
        base, _ = os.path.splitext(final_path)
        preferred = None
        try:
            preferred = str((config or {}).get("thumbnail_format") or "").lower().strip()
        except Exception:
            preferred = None
        exts: list[str] = []
        if preferred:
            dot = preferred if preferred.startswith(".") else f".{preferred}"
            if dot in _THUMB_EXTS:
                exts.append(dot)
        exts.extend(e for e in _THUMB_EXTS if e not in exts)
        for ext in exts:
            candidate = base + ext
            if candidate != final_path and os.path.isfile(candidate):
                return candidate
    except Exception:
        return None
    return None


def _delete_infojson_sidecars(file_path: str | None) -> list[str]:
    """Delete writeinfojson sidecars beside a successfully finished download.

    Candidates are derived ONLY from the engine's own finished ``file_path``:
    ``<stem>.info.json`` (yt-dlp's sidecar name) and ``<file>.info.json``.
    Call on terminal SUCCESS only — failure/cancel keeps the sidecar so
    ``resume.py`` can recover the URL. Never raises; returns removed paths.
    """
    removed: list[str] = []
    try:
        if not file_path or not isinstance(file_path, str):
            return removed
        candidates = (
            os.path.splitext(file_path)[0] + ".info.json",
            file_path + ".info.json",
        )
        for candidate in candidates:
            try:
                # The finished file itself is never a candidate (e.g. a file
                # that already ends in .info.json); regular files only.
                if candidate == file_path:
                    continue
                if os.path.isfile(candidate):
                    os.remove(candidate)
                    removed.append(candidate)
            except Exception:
                continue
    except Exception:
        pass
    return removed


def download_thread(
    url: str,
    download_id: str,
    config: dict | None = None,
    network_type: str = "wifi",
    progress_queue: _queue.Queue | None = None,
    result_queue: _queue.Queue | None = None,
    cancel_event: threading.Event | None = None,
    event_callback=None,
    slot_token=None,
):
    with download_context(download_id):
        # Android bridge delivers config as a JSON string (Chaquopy Maps are
        # live HashMap proxies, not mappings). Coerce before any use.
        config = coerce_config(config)
        cancel = cancel_event or threading.Event()
        # Bounded queues: _put_bounded() drop-oldest only engages when the
        # queue has a maxsize; unbounded Queue() never raises Full so tens
        # of thousands of progress ticks were retained until finish (OOM).
        prog_q = progress_queue or _queue.Queue(maxsize=_QUEUE_MAXSIZE)
        res_q = result_queue or _queue.Queue(maxsize=_QUEUE_MAXSIZE)

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
                "audio_only": _is_audio_mode(config),
                "started_at": datetime.now(timezone.utc),
                "event_callback": event_callback or existing.get("event_callback"),
            })
            _active_downloads[download_id] = existing

        log.set_context(download_id=download_id)
        # T1-9: bound before try — the except-handler below logs safe_url,
        # so a failure before its in-try assignment must not raise
        # UnboundLocalError and mask the real error.
        safe_url = "<url>"
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
                    log.error(
                        f"Cannot start download: FFmpeg binary is missing or not executable ({ffmpeg_path}). "
                        "Please run bootstrap first.",
                        extra={"download_id": download_id},
                    )
                    err_event = json.dumps({
                        "type": "event",
                        "event": "error",
                        "download_id": download_id,
                        "error_type": "ERROR_FFMPEG_MISSING",
                        "error_message": "FFmpeg binary is missing or not executable. Please run bootstrap first.",
                        "recoverable": True,
                    })
                    if event_callback is not None:
                        _emit_event(event_callback, err_event)
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
                # Use cache_dir solely for yt-dlp internal HTTP/extractor cache,
                # NEVER for paths["temp"] which dumps partial/complete media streams
                # into app-internal cache subject to Android OS silent eviction.
                opts["cachedir"] = get_paths()["cache_dir"]

            ydl_logger = YDLogger(log, download_id=download_id)
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
                    from grablytic_engine.persistent import sanitize
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
                log.warn(f"Download cancelled: {download_id}", extra={"download_id": download_id})
                terminal_event = json.dumps({
                    "type": "event",
                    "event": "cancelled",
                    "download_id": download_id,
                    "error_type": "ERROR_CANCELLED",
                    "error_message": "Download cancelled by user",
                })
                if event_callback is not None:
                    _emit_event(event_callback, terminal_event)
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
                    # AARAV-1: any logger.error on a single item used to
                    # surface as ERROR_POSTPROCESS_FAILED — including format
                    # resolution failures that never reached post-processing.
                    # Classify the real message instead (Dart maps every
                    # known type; unknowns fall back safely).
                    err = classify_error(Exception(last))
                    log.error(
                        f"Download failed, failing item: {last[:200]}",
                        extra={"download_id": download_id},
                    )
                    terminal_event = json.dumps({
                        "type": "event",
                        "event": "error",
                        "download_id": download_id,
                        "error_type": err.error_type,
                        "error_message": err.message,
                        "recoverable": err.recoverable,
                        "suggests_vpn": err.suggests_vpn,
                    })
                    if event_callback is not None:
                        _emit_event(event_callback, terminal_event)
                    else:
                        res_q.put({
                            "success": False,
                            "download_id": download_id,
                            "error_type": err.error_type,
                            "error_message": err.message,
                            "recoverable": err.recoverable,
                            "suggests_vpn": err.suggests_vpn,
                        })
                    return
                log.info("Download completed", extra={"download_id": download_id})
                # Terminal finished event carries the last known byte count and file path
                # so the UI never zeroes out sizes or file paths (filesize_bytes contract).
                final_bytes, prog_file = _last_known_file_info(prog_q)

                final_path = None
                for p in reversed(ydl_logger.output_files):
                    if os.path.isfile(p):
                        final_path = p
                        break
                if not final_path and prog_file and os.path.isfile(prog_file):
                    final_path = prog_file

                if final_path and os.path.isfile(final_path):
                    try:
                        disk_size = os.path.getsize(final_path)
                        if disk_size > 0 and (final_bytes <= 0 or disk_size > final_bytes):
                            final_bytes = disk_size
                    except Exception:
                        pass

                # Local thumbnail sidecar (writethumbnail output kept via
                # already_have_thumbnail) so Dart can render Library
                # thumbnails offline instead of re-fetching remote URLs.
                # Success-path only: the sidecar served resume duty during the
                # download; on terminal success it would litter Download/.
                # Failure/cancel paths above return before reaching here, so
                # their sidecars survive for resume.py.
                _delete_infojson_sidecars(final_path)

                thumbnail_path = _find_thumbnail_path(final_path, config)

                terminal_event = json.dumps({
                    "type": "event",
                    "event": "finished",
                    "download_id": download_id,
                    "filesize_bytes": final_bytes,
                    "total_bytes": final_bytes,
                    "file_path": final_path,
                    "thumbnail_path": thumbnail_path,
                })
                if event_callback is not None:
                    _emit_event(event_callback, terminal_event)
                else:
                    res_q.put({
                        "success": True,
                        "download_id": download_id,
                        "filesize_bytes": final_bytes,
                        "file_path": final_path,
                        "thumbnail_path": thumbnail_path,
                    })

        except KeyboardInterrupt:
            log.warn(f"Download cancelled: {download_id}", extra={"download_id": download_id})
            terminal_event = json.dumps({
                "type": "event",
                "event": "cancelled",
                "download_id": download_id,
                "error_type": "ERROR_CANCELLED",
                "error_message": "Download cancelled by user",
            })
            if event_callback is not None:
                _emit_event(event_callback, terminal_event)
            else:
                res_q.put({
                    "success": False,
                    "download_id": download_id,
                    "error_type": "ERROR_CANCELLED",
                    "error_message": "Download cancelled by user",
                })
        except Exception as exc:
            log.log_exception(exc, f"Download failed: {safe_url}", extra={"download_id": download_id})
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
                _emit_event(event_callback, terminal_event)
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
                log.error(f"Download aborted ({kind}): {download_id}", extra={"download_id": download_id})
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
                _emit_event(event_callback, terminal_event)
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
            # BRUTAL-2a: stamp + promote only our own generation. A stale
            # worker exiting after a same-id retry must not mark the fresh
            # download terminal (cleanup would reap it mid-flight) nor
            # over-admit via an extra pump.
            owned = _close_own_slot(download_id, slot_token)
            if owned:
                # Free the slot, then promote the next FIFO-parked entry (if any).
                try:
                    _pump_queue()
                except Exception:
                    pass


def start_download(
    url: str,
    download_id: str,
    config: dict | None = None,
    network_type: str = "wifi",
    event_callback=None,
) -> dict:
    # Reject admission if engine is currently shutting down
    with _shutdown_lock:
        if _is_shutting_down:
            return {
                "success": False,
                "download_id": download_id,
                "error_type": "ERROR_SHUTTING_DOWN",
                "error_message": "Engine is shutting down",
            }

    # SSRF gate: only public http(s) media URLs reach yt-dlp. Rejects
    # file://, localhost/LAN/link-local targets, and non-string garbage
    # before admission, queueing, or thread spawn.
    try:
        from grablytic_engine.url_guard import is_safe_media_url
        _url_ok = is_safe_media_url(url)
    except Exception:
        _url_ok = False
    if not _url_ok:
        return {
            "success": False,
            "download_id": download_id,
            "error_type": "ERROR_INVALID_PARAM",
            "error_message": "URL must be a public http(s) address",
        }

    with _downloads_lock:
        existing = _active_downloads.get(download_id)
        # Same-id reuse is only safe from a terminal state (finished_at set).
        # An active entry means redownload-while-downloading: reject instead
        # of orphaning the previous thread (interleaved progress + double
        # terminal events under one id).
        if existing is not None and not existing.get("finished_at"):
            return {
                "success": False,
                "download_id": download_id,
                "error_type": "ERROR_ALREADY_ACTIVE",
                "error_message": "Download already in progress for this ID",
            }
        if existing is not None and existing.get("finished_at"):
            # Terminal entry still awaiting cleanup — drop it so the retry
            # starts clean under the same id (history row key stability).
            _active_downloads.pop(download_id, None)
        for i, e in enumerate(_pending_queue):
            if e["download_id"] == download_id:
                return {
                    "success": False,
                    "download_id": download_id,
                    "error_type": "ERROR_ALREADY_ACTIVE",
                    "error_message": "Download already queued for this ID",
                }
        # T1-5: same URL under a different ID must not download twice.
        # Keyed on (url, audio-mode) so explicit "extract audio" re-fetches
        # (different artifact) still pass; terminal entries never block.
        audio_only = _is_audio_mode(config)
        holder = _find_live_url_holder(url, audio_only)
        if holder is not None:
            return {
                "success": False,
                "download_id": download_id,
                "error_type": "ERROR_DUPLICATE_URL",
                "error_message": f"URL already downloading under ID {holder}",
                "existing_download_id": holder,
            }
        queued = _running_count() >= _max_concurrent
        if queued:
            if len(_pending_queue) >= _MAX_PENDING_QUEUE:
                return {
                    "success": False,
                    "download_id": download_id,
                    "error_type": "ERROR_QUEUE_FULL",
                    "error_message": f"Download queue is full (maximum {_MAX_PENDING_QUEUE} pending items)",
                    "queue_size": len(_pending_queue),
                    "max_queue_size": _MAX_PENDING_QUEUE,
                }
            progress_queue = _queue.Queue(maxsize=_QUEUE_MAXSIZE)
            result_queue = _queue.Queue(maxsize=_QUEUE_MAXSIZE)
            cancel_event = threading.Event()
            entry = {
                "download_id": download_id,
                "url": url,
                "config": config,
                "network_type": network_type,
                "progress_queue": progress_queue,
                "result_queue": result_queue,
                "cancel_event": cancel_event,
                "event_callback": event_callback,
                "queued_at": datetime.now(timezone.utc),
            }
            _pending_queue.append(entry)
            position = len(_pending_queue)
        else:
            progress_queue = _queue.Queue(maxsize=_QUEUE_MAXSIZE)
            result_queue = _queue.Queue(maxsize=_QUEUE_MAXSIZE)
            cancel_event = threading.Event()
            # T1-1: Atomically register in _active_downloads under lock before releasing lock
            _active_downloads[download_id] = {
                "cancel_event": cancel_event,
                "progress_queue": progress_queue,
                "result_queue": result_queue,
                "url": url,
                "audio_only": audio_only,
                "thread": None,
                "started_at": datetime.now(timezone.utc),
                "slot_token": _new_slot_token(),
                "event_callback": event_callback,
            }

    if event_callback is not None:
        try:
            set_global_event_callback(event_callback)
        except Exception:
            pass

    _ensure_cleanup_thread()

    if queued:
        if event_callback is not None:
            try:
                _emit_event(event_callback, json.dumps({
                    "type": "event",
                    "event": "queued",
                    "download_id": download_id,
                    "position": position,
                }))
            except Exception:
                pass
        return {
            "success": True,
            "download_id": download_id,
            "thread_started": False,
            "queued": True,
            "position": position,
        }

    entry = {
        "download_id": download_id,
        "url": url,
        "config": config,
        "network_type": network_type,
        "progress_queue": progress_queue,
        "result_queue": result_queue,
        "cancel_event": cancel_event,
        "event_callback": event_callback,
        "queued_at": datetime.now(timezone.utc),
    }
    _spawn_thread(entry)

    return {
        "success": True,
        "download_id": download_id,
        "thread_started": True,
        "queued": False,
    }


def cancel_download(download_id: str) -> dict:
    queued_entry = None
    worker_thread = None
    worker_alive = False
    active_slot_token = None
    active_info = None
    with _downloads_lock:
        for i, e in enumerate(_pending_queue):
            if e["download_id"] == download_id:
                queued_entry = _pending_queue.pop(i)
                break
        info = _active_downloads.get(download_id)
        if queued_entry is None and not info:
            return {
                "success": False,
                "error_type": "ERROR_DOWNLOAD_NOT_FOUND",
                "error_message": f"No active download with ID: {download_id}",
            }
        if info and not info.get("finished_at"):
            try:
                info["cancel_event"].set()
            except Exception:
                pass
            worker_thread = info.get("thread")
            worker_alive = _worker_thread_alive(info)
            active_slot_token = info.get("slot_token")
            active_info = info

    if queued_entry is not None:
        # Dequeued before a thread ever spawned: deliver a terminal
        # cancelled event through the same channel the thread would use.
        terminal = json.dumps({
            "type": "event",
            "event": "cancelled",
            "download_id": download_id,
            "error_type": "ERROR_CANCELLED",
            "error_message": "Download cancelled by user",
        })
        cb = queued_entry.get("event_callback")
        if cb is not None:
            try:
                _emit_event(cb, terminal)
            except Exception:
                pass
        else:
            try:
                queued_entry["result_queue"].put({
                    "success": False,
                    "download_id": download_id,
                    "error_type": "ERROR_CANCELLED",
                    "error_message": "Download cancelled by user",
                })
            except Exception:
                pass
            # Register into _active_downloads so desktop poll_queues() will
            # drain its result_queue before cleanup_loop removes it.
            with _downloads_lock:
                _active_downloads[download_id] = {
                    "cancel_event": queued_entry["cancel_event"],
                    "progress_queue": queued_entry["progress_queue"],
                    "result_queue": queued_entry["result_queue"],
                    "url": queued_entry["url"],
                    "audio_only": _is_audio_mode(queued_entry.get("config")),
                    "thread": None,
                    "started_at": queued_entry.get("queued_at") or datetime.now(timezone.utc),
                    "finished_at": datetime.now(timezone.utc),
                    "slot_token": _new_slot_token(),
                }

    if active_info is not None and not worker_alive:
        # Worker is not running (pre-spawn, threadless mock, or dead without closing slot).
        # Close slot immediately to avoid leaking capacity, stamp finished_at, emit terminal,
        # and pump the queue so parked downloads can proceed.
        closed = _close_own_slot(download_id, active_slot_token)
        if closed:
            terminal = json.dumps({
                "type": "event",
                "event": "cancelled",
                "download_id": download_id,
                "error_type": "ERROR_CANCELLED",
                "error_message": "Download cancelled by user",
            })
            cb = active_info.get("event_callback")
            if cb is not None:
                try:
                    _emit_event(cb, terminal)
                except Exception:
                    pass
            else:
                try:
                    active_info["result_queue"].put({
                        "success": False,
                        "download_id": download_id,
                        "error_type": "ERROR_CANCELLED",
                        "error_message": "Download cancelled by user",
                    })
                except Exception:
                    pass
            try:
                _pump_queue()
            except Exception:
                pass

    if worker_alive:
        # T1-3: a live worker may sit hook-blind (extractor hang, merge
        # wait, stalled socket, aria2c child) for an unbounded time, so the
        # old unconditional `cancelled: True` lied. Report the honest
        # intermediate; the terminal `cancelled` arrives via the normal
        # channel on worker exit, or via the watchdog below on a wedge.
        _start_cancel_watchdog(download_id, worker_thread)
        return {
            "success": True,
            "download_id": download_id,
            "cancelled": False,
            "cancelling": True,
        }
    return {
        "success": True,
        "download_id": download_id,
        "cancelled": True,
        "cancelling": False,
    }


# T1-3: bound on "cancelling". A worker wedged where no yt-dlp progress hook
# ever fires again would otherwise leave the UI in "cancelling" forever.
# CPython threads cannot be killed, and Popen-handle interposition was
# rejected (yt-dlp helper-thread births misattribute kills across
# downloads). So on expiry: free the slot (finished_at stamp — the exact
# mechanism of the worker finally-block, keeping _cleanup_loop's invariant)
# and emit a presumed-stopped terminal. A late real terminal from the worker
# is benign (Dart treats duplicate cancelled idempotently; res_q leftovers
# drain via _cleanup_loop's 30s failsafe). Monkeypatchable in tests.
_CANCEL_WATCHDOG_SECONDS = 120.0


def _worker_thread_alive(info) -> bool:
    """True only for a provably-live worker thread.

    Pre-spawn entries (thread None) and thread doubles without is_alive
    (test NoopThreads) report False → legacy terminal path, which T1-2 pins.
    Only a real live thread takes the honest `cancelling` intermediate.
    """
    th = info.get("thread") if isinstance(info, dict) else None
    if th is None:
        return False
    is_alive = getattr(th, "is_alive", None)
    if not callable(is_alive):
        return False
    try:
        return bool(is_alive())
    except Exception:
        return False


def _start_cancel_watchdog(download_id: str, worker_thread) -> None:
    """Daemon watchdog: presumed-stopped terminal + slot release on a wedge."""
    def _watch():
        try:
            join = getattr(worker_thread, "join", None)
            if callable(join):
                try:
                    join(timeout=_CANCEL_WATCHDOG_SECONDS)
                except Exception:
                    pass
            try:
                if not bool(worker_thread.is_alive()):
                    return  # worker exited; its own terminal stands
            except Exception:
                return
        except Exception:
            return
        presumed_message = (
            "Download cancelled by user "
            f"(worker did not stop within {int(_CANCEL_WATCHDOG_SECONDS)}s; "
            "presumed stopped)"
        )
        with _downloads_lock:
            info = _active_downloads.get(download_id)
            if info is None:
                return
            if info.get("finished_at"):
                return  # worker terminal won the race
            if info.get("thread") is not worker_thread:
                return  # slot reused under the same id; not ours to close
            slot_token = info.get("slot_token")
            cb = info.get("event_callback")
            res_q = info.get("result_queue")
        # Token-aware idempotent close: a late worker finally after us is
        # a no-op, so the slot can never double-pump into over-admission.
        if not _close_own_slot(download_id, slot_token):
            return
        terminal = json.dumps({
            "type": "event",
            "event": "cancelled",
            "download_id": download_id,
            "error_type": "ERROR_CANCELLED",
            "error_message": presumed_message,
        })
        if cb is not None:
            try:
                _emit_event(cb, terminal)
            except Exception:
                pass
        elif res_q is not None:
            try:
                res_q.put({
                    "success": False,
                    "download_id": download_id,
                    "error_type": "ERROR_CANCELLED",
                    "error_message": presumed_message,
                })
            except Exception:
                pass
        # A wedged worker never reaches its finally-block, so promote the
        # next queued entry here (same call the finally-block makes).
        try:
            _pump_queue()
        except Exception:
            pass

    try:
        t = threading.Thread(target=_watch, daemon=True,
                             name=f"cancel-watchdog-{download_id}")
        t.start()
    except Exception:
        pass


def clear_download_archive(archive_path: str | None = None) -> dict:
    """Delete the download-archive file so archive-skipped URLs can be
    re-downloaded (recovery for delete-file-then-redownload when the archive
    still lists the video — Seal #2065 workaround made explicit).

    Scope: removes exactly one resolved file **strictly inside** the engine
    data dir. When ``archive_path`` is given it is resolved and verified to
    be contained in ``data_dir`` via real-path containment (symlink-safe,
    not substring prefix). Rejects paths outside data_dir, directories,
    and non-files. Returns {'success', 'removed': bool, 'path': str|None}.
    Never raises.
    """
    try:
        import os as _os

        # Always need data_dir for containment checks.
        try:
            data_dir = get_paths().get("data_dir")
        except Exception:
            data_dir = None
        if not data_dir:
            return {"success": False, "removed": False, "path": None,
                    "error_message": "Data dir not configured"}

        resolved_data_dir = _os.path.realpath(data_dir)

        if archive_path:
            path = _os.path.realpath(archive_path)
        else:
            path = _os.path.realpath(
                _os.path.join(data_dir, "download_archive.txt")
            )

        # ── Containment gate ──────────────────────────────────────────
        # Verify the resolved path is strictly inside the resolved
        # data_dir.  Use os.path.commonpath to avoid the classic
        # "/data/dir_evil" matching prefix "/data/dir" substring bug.
        # Also reject paths that resolve to data_dir itself (must be a
        # *child*, not the dir).
        if not path.startswith(resolved_data_dir + _os.sep):
            return {"success": False, "removed": False, "path": None,
                    "error_message": "Path escapes data directory"}

        # Regular file only, never a directory or special file.
        if not _os.path.isfile(path):
            return {"success": True, "removed": False, "path": path}

        _os.remove(path)
        return {"success": True, "removed": True, "path": path}
    except Exception as exc:
        return {"success": False, "removed": False, "path": None,
                "error_message": str(exc)[:200]}


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
