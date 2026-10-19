import json
import threading
import time
import os
import queue as _queue
import uuid
from collections import deque
from datetime import datetime, timezone

from grablytic_engine.ytdlp_network import GuardedYoutubeDL as YoutubeDL

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
# Condition over the SAME lock as `_downloads_lock`, so a waiter for a free
# concurrency slot and the admission path can never disagree about who
# holds the lock. `notify_all` is the wake-up; it must be called with the
# lock released (see `_notify_slot_change`).
_slot_cv = threading.Condition(_downloads_lock)

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
#
# ONE dict, keyed by download_id. Not a list, and not a list + a parallel
# set of ids: every operation the queue needs is O(1) on a dict
# (membership `did in _pending_queue`, removal `del _pending_queue[did]`,
# FIFO pop of the first key), and because insertion order is preserved the
# first key is always the oldest entry. The old list+set pair could drift
# apart — a queue entry present in one but not the other — and that drift
# silently broke cancellation and dedup.
_pending_queue: dict[str, dict] = {}
# O(1) live-URL dedup index. `_find_live_url_holder` used to scan the
# whole active map AND the whole pending queue on every admission
# (O(n+m) per new download — 1500 items at 500 queued / 1000 history).
# This maps (url, audio_only) -> {download_id} for every LIVE download.
_live_url_index: dict[tuple, set] = {}
# Hard cap on the active map. Terminal entries are reaped by the cleanup
# loop (result drained OR 30s old), but a client that never reads the
# result queue could otherwise grow the map without bound.
_MAX_ACTIVE_ENTRIES = 2000

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
_ffmpeg_patch_lock = threading.Lock()
# Diagnostic state for the FFmpeg gate. `installed` is only True when the
# gate is VERIFIABLY in place (the patch was found on the class and the
# attribute identity check passed) — never merely "we tried".
_ffmpeg_patch_state: dict = {
    "installed": False,
    "seam": None,
    "error": None,
}
# Thread-local cancel context so the FFmpeg gate can be interrupted by a
# user cancel while it waits for the semaphore (the wait used to be
# uninterruptible for up to 600s, so a cancel was acknowledged only after
# the merge finished — the UI said "cancelled" while FFmpeg kept writing).
_cancel_ctx = threading.local()


def _current_cancel_event():
    """The cancel event of the download thread that owns this call."""
    return getattr(_cancel_ctx, "event", None)


def _set_current_cancel_event(event) -> None:
    _cancel_ctx.event = event


def _ffmpeg_gate_acquire(cancel_event=None) -> bool:
    """Acquire the FFmpeg gate, honouring a cancel request.

    Polls the semaphore in short slices so a cancel lands within
    ~250ms instead of after the full gate timeout. Returns True when the
    gate was acquired, False when the wait was cancelled or timed out.
    """
    deadline = time.monotonic() + _FFMPEG_GATE_TIMEOUT
    while True:
        if cancel_event is not None:
            try:
                if cancel_event.is_set():
                    return False
            except Exception:
                pass
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
        slice_s = min(0.25, remaining)
        if _ffmpeg_semaphore.acquire(timeout=slice_s):
            return True


def _ffmpeg_gate_release() -> None:
    try:
        _ffmpeg_semaphore.release()
    except Exception:
        pass



def _cancel_event_is_set(cancel_event) -> bool:
    if cancel_event is None:
        return False
    try:
        return bool(cancel_event.is_set())
    except Exception:
        return False


def _raise_ffmpeg_gate_busy() -> None:
    message = (
        "FFmpeg post-processing busy: another merge still "
        f"running after {int(_FFMPEG_GATE_TIMEOUT)}s; "
        "please retry the download"
    )
    log.warn(message)
    raise RuntimeError(message)


def _run_with_ffmpeg_gate(callable_obj, args, kwargs, cancel_event=None):
    if not _ffmpeg_gate_acquire(cancel_event):
        if _cancel_event_is_set(cancel_event):
            raise KeyboardInterrupt("Download cancelled by user")
        _raise_ffmpeg_gate_busy()
    try:
        return callable_obj(*args, **kwargs)
    finally:
        _ffmpeg_gate_release()


def _is_ffmpeg_command(args) -> bool:
    try:
        if not args:
            return False
        command = args[0]
        if isinstance(command, (list, tuple)) and command:
            executable = str(command[0])
        elif isinstance(command, str):
            executable = command
        else:
            return False
        basename = os.path.basename(executable).lower()
        if basename.endswith(".exe"):
            basename = basename[:-4]
        return basename in {"ffmpeg", "ffprobe", "avconv"}
    except Exception:
        return False

def _install_ffmpeg_seam_primary() -> str:
    """Install the gate on ``FFmpegPostProcessor.real_run_ffmpeg``.

    Returns the seam name on success, raises on failure. The seam is
    verified: the attribute must have existed and the assignment must stick.
    """
    import yt_dlp.postprocessor.ffmpeg as yt_ffmpeg

    pp_cls = getattr(yt_ffmpeg, "FFmpegPostProcessor", None)
    if pp_cls is None:
        raise AttributeError(
            "yt_dlp.postprocessor.ffmpeg.FFmpegPostProcessor is missing"
        )
    original = getattr(pp_cls, "real_run_ffmpeg", None)
    if original is None or not callable(original):
        raise AttributeError(
            "FFmpegPostProcessor.real_run_ffmpeg is missing — yt-dlp "
            "renamed the seam, so the FFmpeg serialization gate cannot "
            "be installed here"
        )
    if getattr(original, "grablytic_ffmpeg_gate", False):
        return "FFmpegPostProcessor.real_run_ffmpeg"

    def serialized_real_run_ffmpeg(self, *args, **kwargs):
        return _run_with_ffmpeg_gate(
            original,
            (self, *args),
            kwargs,
            cancel_event=_current_cancel_event(),
        )

    serialized_real_run_ffmpeg.grablytic_ffmpeg_gate = True
    pp_cls.real_run_ffmpeg = serialized_real_run_ffmpeg
    if getattr(pp_cls, "real_run_ffmpeg", None) is not serialized_real_run_ffmpeg:
        raise RuntimeError(
            "FFmpeg serialization assignment did not stick (yt-dlp may "
            "use __slots__ / a metaclass that rejects attribute writes)"
        )
    return "FFmpegPostProcessor.real_run_ffmpeg"

def _install_ffmpeg_seam_fallback() -> str:
    """Serialize ffmpeg/ffprobe process spawns when the primary seam is absent."""
    from yt_dlp.utils import Popen

    original_descriptor = Popen.__dict__.get("run")
    if isinstance(original_descriptor, classmethod) and getattr(
        original_descriptor.__func__, "grablytic_ffmpeg_gate", False
    ):
        return "yt_dlp.utils.Popen.run"
    if not isinstance(original_descriptor, classmethod):
        raise AttributeError(
            "yt_dlp.utils.Popen.run is no longer a classmethod — the "
            "fallback serialization seam cannot be installed"
        )

    def serialized_run(cls, *args, **kwargs):
        original_run = original_descriptor.__get__(None, cls)
        if not _is_ffmpeg_command(args):
            return original_run(*args, **kwargs)
        return _run_with_ffmpeg_gate(
            original_run,
            args,
            kwargs,
            cancel_event=_current_cancel_event(),
        )

    serialized_run.grablytic_ffmpeg_gate = True
    Popen.run = classmethod(serialized_run)
    installed = Popen.__dict__.get("run")
    if not isinstance(installed, classmethod) or installed.__func__ is not serialized_run:
        raise RuntimeError("Popen.run serialization assignment did not stick")
    return "yt_dlp.utils.Popen.run"

def _ensure_ffmpeg_serialized() -> bool:
    """Install the process-wide FFmpeg serialization gate.

    Returns True when the gate is verifiably installed. NEVER raises and
    NEVER fails silently: a failure is recorded in
    ``_ffmpeg_patch_state`` and logged at ERROR level, and the status is
    surfaced by :func:`ffmpeg_serialization_status` (and therefore by
    bootstrap) so the condition is visible instead of invisible.
    """
    if _ffmpeg_patch_state.get("installed"):
        return True
    with _ffmpeg_patch_lock:
        if _ffmpeg_patch_state.get("installed"):
            return True
        errors: list[str] = []
        for name, installer in (
            ("primary", _install_ffmpeg_seam_primary),
            ("fallback", _install_ffmpeg_seam_fallback),
        ):
            try:
                seam = installer()
            except Exception as exc:
                errors.append(f"{name}: {type(exc).__name__}: {exc}")
                continue
            _ffmpeg_patch_state.update(
                installed=True,
                seam=seam,
                error=None,
            )
            log.info(f"FFmpeg serialization gate installed on {seam}")
            return True
        # Both seams failed. Loudly record it: the engine still works, but
        # concurrent post-processing is UNSERIALIZED, which is exactly the
        # CPU-oversubscription / thermal-throttling / LMK failure the gate
        # exists to prevent.
        detail = "; ".join(errors) or "unknown error"
        _ffmpeg_patch_state.update(installed=False, seam=None, error=detail)
        try:
            log.error(
                "FFmpeg serialization gate NOT installed — concurrent "
                f"post-processing is unsynchronized ({detail})"
            )
        except Exception:
            pass
        return False


def ffmpeg_serialization_status() -> dict:
    """Health of the FFmpeg gate: {'installed', 'seam', 'error'}."""
    return {
        "installed": bool(_ffmpeg_patch_state.get("installed")),
        "seam": _ffmpeg_patch_state.get("seam"),
        "error": _ffmpeg_patch_state.get("error"),
    }


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
        # A download sleeping through a retry backoff may be waiting for
        # exactly this extra slot.
        _notify_slot_change()
    return {"success": True, "max_concurrent": _max_concurrent}


def _apply_verbosity(opts: dict, config: dict) -> None:
    """Let the USER's verbose setting decide.

    The engine used to set `opts["verbose"] = True` unconditionally, so
    yt-dlp's verbose output flooded the log on every download and the
    setting in the UI did nothing.
    """
    try:
        verbose = bool((config or {}).get("verbose"))
    except Exception:
        verbose = False
    if verbose:
        opts["verbose"] = True
    else:
        opts.pop("verbose", None)


def _mark_result_delivered(download_id: str) -> None:
    """Mark a download's terminal result as handed to the client.

    The cleanup loop used to reap an entry when `res_q.empty()` — and
    `Queue.empty()` is documented as UNRELIABLE in multi-threaded
    contexts. The invariant it leaned on ("the worker puts its terminal
    BEFORE stamping finished_at") was an engine-internal detail, not an
    upstream yt-dlp contract, and a race there reaped an entry whose
    result the client had not read yet.

    This flag records the fact itself: the result reached the client —
    through the event callback, or by being drained from the result
    queue.
    """
    try:
        with _downloads_lock:
            info = _active_downloads.get(download_id)
            if isinstance(info, dict):
                info["result_delivered"] = True
    except Exception:
        pass


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
        # The entry is no longer LIVE — drop it from the dedup index so a
        # new download of the same URL is not rejected as a duplicate.
        _index_remove(download_id, info.get("url"), info.get("audio_only"))
    # A slot just freed up — wake anything waiting to re-acquire one.
    _notify_slot_change()
    return True


# ── Live-URL dedup index ───────────────────────────────────────────────
# The index maps (url, audio_only) -> {download_id} for every download
# that is still LIVE (active and not terminal, or parked in the pending
# queue). It is maintained incrementally at every admission / promotion /
# terminal / cleanup transition, and `_live_url_index_matches_bruteforce`
# proves it agrees with a full scan.


def _pending_pop_first() -> dict | None:
    """Remove and return the OLDEST parked entry (FIFO). O(1).

    Dicts preserve insertion order, so the first key is the oldest
    entry. Caller holds `_downloads_lock`.
    """
    if not _pending_queue:
        return None
    did = next(iter(_pending_queue))
    return _pending_queue.pop(did)


def _index_key(url, audio_only) -> tuple:
    return (url, bool(audio_only))


def _index_add(download_id: str, url, audio_only) -> None:
    """Register a live download in the dedup index. Caller holds the lock."""
    if not download_id or not isinstance(url, str):
        return
    _live_url_index.setdefault(_index_key(url, audio_only), set()).add(download_id)


def _index_remove(download_id: str, url, audio_only) -> None:
    """Deregister a download from the dedup index. Caller holds the lock."""
    if not download_id or not isinstance(url, str):
        return
    key = _index_key(url, audio_only)
    holders = _live_url_index.get(key)
    if not holders:
        return
    holders.discard(download_id)
    if not holders:
        _live_url_index.pop(key, None)


def _live_url_index_matches_bruteforce() -> bool:
    """True when the incremental index agrees with a full scan.

    Test/debug helper — O(n+m) by construction, never used on the hot
    path.
    """
    expected: dict[tuple, set] = {}
    # LOCK-FREE on purpose: every caller already holds `_downloads_lock`
    # and a plain `threading.Lock` is not re-entrant — taking it here
    # would deadlock the caller.
    for did, info in list(_active_downloads.items()):
        if info.get("finished_at"):
            continue
        expected.setdefault(
            _index_key(info.get("url"), info.get("audio_only")), set()
        ).add(did)
    for e in list(_pending_queue.values()):
        did = e.get("download_id")
        if not did:
            continue
        expected.setdefault(
            _index_key(e.get("url"), _is_audio_mode(e.get("config"))), set()
        ).add(did)
    return expected == _live_url_index


def _running_count() -> int:
    """Active (non-terminal) downloads. Caller should hold _downloads_lock
    or accept a best-effort snapshot.

    A download that is sleeping through a retry backoff does NOT count:
    it is not doing any work, and holding a concurrency slot for 15
    seconds of sleep idles the whole engine.
    """
    count = 0
    for info in _active_downloads.values():
        if info.get("finished_at"):
            continue
        if info.get("backing_off"):
            continue
        count += 1
    return count


def _notify_slot_change() -> None:
    """Wake any download waiting for a free concurrency slot.

    Must be called with `_downloads_lock` NOT held: `_slot_cv` shares that
    lock, and a plain `threading.Lock` is not re-entrant.
    """
    try:
        with _slot_cv:
            _slot_cv.notify_all()
    except Exception:
        pass


def _begin_backoff(download_id: str, delay: float, cancel) -> None:
    """Release the concurrency slot for `delay` seconds, then re-acquire one.

    The slot is handed back to the engine for the duration of the sleep
    (the entry is flagged `backing_off`, so `_running_count` ignores it)
    and the pending queue is pumped so a waiting download can start
    immediately.

    After the sleep the download waits for a free slot again. It does NOT
    barge past a live download: the wait ends only when the engine is
    actually below the concurrency limit (or the download is cancelled).
    """
    with _downloads_lock:
        info = _active_downloads.get(download_id)
        if isinstance(info, dict):
            info["backing_off"] = True
    # A slot just became free — let a queued download take it.
    try:
        _pump_queue()
    except Exception:
        pass
    try:
        time.sleep(delay)
    except Exception:
        pass
    # Re-acquire a slot (interruptible by cancellation).
    with _slot_cv:
        while True:
            if cancel is not None:
                try:
                    if cancel.is_set():
                        break
                except Exception:
                    pass
            if _running_count() < _max_concurrent:
                break
            _slot_cv.wait(timeout=0.5)
        info = _active_downloads.get(download_id)
        if isinstance(info, dict):
            info["backing_off"] = False
    _notify_slot_change()


def _is_audio_mode(config) -> bool:
    """True when this download produces an audio-only artifact. Never raises
    (Chaquopy proxies / garbage configs fall back to video mode)."""
    try:
        return bool((config or {}).get("audio_only", False))
    except Exception:
        return False


def _find_live_url_holder(url: str, audio_only: bool):
    """ID of a live (non-terminal) active-or-queued download for the same
    (url, audio-mode), or None. Caller must hold _downloads_lock.

    O(1): the candidate set comes from the incremental dedup index, so
    this no longer walks the whole active map and the whole pending
    queue on every admission.
    """
    holders = _live_url_index.get(_index_key(url, audio_only))
    if not holders:
        return None
    live: list[str] = []
    stale: list[str] = []
    # Deterministic order so the duplicate error always names the same id.
    for did in sorted(holders):
        info = _active_downloads.get(did)
        if info is not None and not info.get("finished_at"):
            live.append(did)
        elif did in _pending_queue:
            live.append(did)
        else:
            # Neither active nor parked: the entry is gone (or terminal).
            # Prune it so the index cannot grow without bound.
            stale.append(did)
    for did in stale:
        holders.discard(did)
    if not holders:
        _live_url_index.pop(_index_key(url, audio_only), None)
    return live[0] if live else None


def get_queue_status() -> dict:
    with _downloads_lock:
        return {
            "success": True,
            "active": [
                did
                for did, info in _active_downloads.items()
                if not info.get("finished_at")
            ],
            "queued": list(_pending_queue.keys()),
            "max_concurrent": _max_concurrent,
        }


def _spawn_thread(entry: dict) -> threading.Thread | None:
    # Register in the active map BEFORE starting the thread.
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
            terminal = json.dumps(
                {
                    "type": "event",
                    "event": "cancelled",
                    "download_id": download_id,
                    "error_type": "ERROR_CANCELLED",
                    "error_message": "Download cancelled by user",
                }
            )
            cb = entry.get("event_callback")
            if cb is not None:
                try:
                    _emit_event(cb, terminal)
                except Exception:
                    pass
            else:
                try:
                    entry["result_queue"].put(
                        {
                            "success": False,
                            "download_id": download_id,
                            "error_type": "ERROR_CANCELLED",
                            "error_message": "Download cancelled by user",
                        }
                    )
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
                # Set once the terminal result has reached the client.
                "result_delivered": False,
            }
        else:
            if (
                "event_callback" not in _active_downloads[download_id]
                and entry.get("event_callback") is not None
            ):
                _active_downloads[download_id]["event_callback"] = entry.get(
                    "event_callback"
                )
        # Defensive: the entry is live for the whole time it is in the
        # active map without a finished_at stamp, so it must be reachable
        # through the O(1) dedup index.
        _index_add(
            download_id,
            entry["url"],
            _is_audio_mode(entry.get("config")),
        )
        # BRUTAL-2a: generation identity is fixed at registration (before
        # start) so the worker's finally-block can prove ownership even if
        # the entry is replaced under the same id mid-flight.
        slot_token = _active_downloads[download_id].get("slot_token")
    t = threading.Thread(
        target=download_thread,
        args=(
            entry["url"],
            download_id,
            entry["config"],
            entry["network_type"],
            entry["progress_queue"],
            entry["result_queue"],
            cancel_event,
            entry["event_callback"],
            slot_token,
        ),
        daemon=True,
    )
    try:
        t.start()
    except Exception as exc:
        log.error(
            f"Failed to start download thread: {exc}",
            extra={"download_id": download_id},
        )
        _close_own_slot(download_id, slot_token)
        err_event = json.dumps(
            {
                "type": "event",
                "event": "error",
                "download_id": download_id,
                "error_type": "ERROR_THREAD_SPAWN",
                "error_message": f"Could not start downloader thread: {exc}",
                "recoverable": True,
                "suggests_vpn": False,
            }
        )
        cb = entry.get("event_callback")
        if cb is not None:
            try:
                _emit_event(cb, err_event)
            except Exception:
                pass
        else:
            try:
                entry["result_queue"].put(
                    {
                        "success": False,
                        "download_id": download_id,
                        "error_type": "ERROR_THREAD_SPAWN",
                        "error_message": f"Could not start downloader thread: {exc}",
                        "recoverable": True,
                        "suggests_vpn": False,
                    }
                )
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
            entry = _pending_pop_first()
            if entry is None:
                return
            did = entry["download_id"]
            if did in _active_downloads and not _active_downloads[did].get(
                "finished_at"
            ):
                # Superseded (cancelled/replaced) while parked — skip.
                _index_remove(
                    did,
                    _active_downloads[did].get("url"),
                    _active_downloads[did].get("audio_only"),
                )
                continue
            # Atomically move from _pending_queue into _active_downloads
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
            promotion = json.dumps(
                {
                    "type": "event",
                    "event": "downloading",
                    "download_id": did,
                    "promoted_from_queue": True,
                }
            )
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


# ── Lazy cleanup thread and graceful shutdown ───────────────────

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
                        # Reap only when the result actually reached the
                        # client. `res_q.empty()` is not a safe proxy for
                        # that (unreliable in multi-threaded contexts).
                        if info.get("result_delivered"):
                            to_remove.append(did)
                        # Failsafe: clean up after 30 seconds regardless
                        # of read status.
                        elif (now - fin_at).total_seconds() > 30:
                            to_remove.append(did)

                for did in to_remove:
                    info = _active_downloads.pop(did, None)
                    if isinstance(info, dict):
                        # Defensive: a reaped entry is never live again.
                        _index_remove(
                            did,
                            info.get("url"),
                            info.get("audio_only"),
                        )
                # Hard cap: a client that never drains the result queue
                # could otherwise grow the active map without bound. Drop
                # the OLDEST terminal entries first (live ones are never
                # evicted — that would orphan a running download).
                overflow = len(_active_downloads) - _MAX_ACTIVE_ENTRIES
                if overflow > 0:
                    terminal = sorted(
                        (
                            (info.get("finished_at"), did)
                            for did, info in _active_downloads.items()
                            if info.get("finished_at")
                        )
                    )
                    for _, did in terminal[:overflow]:
                        info = _active_downloads.pop(did, None)
                        if isinstance(info, dict):
                            _index_remove(
                                did,
                                info.get("url"),
                                info.get("audio_only"),
                            )
        except Exception:
            pass
        _cleanup_stop_event.wait(1.0)


def shutdown_downloads(timeout: float = 5.0) -> dict:
    """Gracefully shut down all active downloads on engine/interpreter exit.

    Prevents mid-write daemon thread kills that leave corrupt .part
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

    # Stop the watchdog pool: a pending watchdog job would otherwise keep
    # a daemon thread alive past interpreter exit.
    try:
        stop_watchdog_pool()
    except Exception:
        pass

    with _downloads_lock:
        for e in list(_pending_queue.values()):
            _index_remove(
                e.get("download_id"),
                e.get("url"),
                _is_audio_mode(e.get("config")),
            )
        _pending_queue.clear()
        active = [
            (did, info)
            for did, info in list(_active_downloads.items())
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
    re.compile(r"\[download\]\s+(.*?)\s+has already been downloaded"),
    re.compile(r"\[download\]\s+Destination:\s+(.*)"),
    re.compile(r'\[Merger\]\s+Merging formats into\s+"([^"]+)"'),
    re.compile(r'\[MoveFiles\]\s+Moving file.*?\s+to\s+"?([^"]+)"?'),
    re.compile(r'\[EmbedThumbnail\]\s+ffmpeg:\s+Adding thumbnail to\s+"([^"]+)"'),
    re.compile(r'\[Metadata\]\s+Adding metadata to\s+"([^"]+)"'),
    re.compile(r'\[FixupM3u8\]\s+Fixing code of\s+"([^"]+)"'),
]


class YDLogger:
    """yt-dlp logger bridge. Collects error lines and tracks output file paths."""

    # Bound the tail — ignoreerrors playlists can log thousands of
    # entries. Most-recent retained (diagnostically relevant). output_files
    # is capped high enough for legit big playlists but can never grow
    # without bound; a set gives O(1) dedup instead of O(n) list scans.
    MAX_ERRORS = 200
    MAX_OUTPUT_FILES = 2000

    def __init__(
        self, logger: EngineLogger | None = None, download_id: str | None = None
    ):
        self.logger = logger if logger is not None else log
        self.download_id = download_id
        self.errors: deque[str] = deque(maxlen=self.MAX_ERRORS)
        self.output_files: list[str] = []
        self._output_seen: set[str] = set()
        # yt-dlp logs from several threads (extractor + post-processor).
        # `output_files` is a list and `_output_seen` a set: both were
        # mutated concurrently, so the tail could be read mid-update.
        self._lock = threading.Lock()

    def last_error(self) -> str | None:
        """The most recent error line, or None. Safe from any thread."""
        with self._lock:
            return self.errors[-1] if self.errors else None

    def _extract_path(self, msg):
        if not isinstance(msg, str):
            return
        for pat in _PATH_PATTERNS:
            m = pat.search(msg)
            if m:
                candidate = m.group(1).strip().strip('"').strip("'")
                if not candidate:
                    break
                with self._lock:
                    if candidate not in self._output_seen:
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

    The old prog_q.mutex/prog_q.queue reach-through depended on
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


def _find_thumbnail_path(
    final_path: str | None, config: dict | None = None
) -> str | None:
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
            preferred = (
                str((config or {}).get("thumbnail_format") or "").lower().strip()
            )
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


# ── Transient auto-retry (FEATURE 5) ─────────────────────────────────────
# Bulk sessions hit transient "empty media response"-class failures that
# succeed on manual retry. Auto-retry those in-slot: max 2 retries per item
# with exponential backoff (5s, 15s). The retry verdict reuses
# errors.classify_error() — recoverable AND not in the permanent denylist —
# so private/deleted/no-video/photo-post-class permanents NEVER retry.
# The loop runs inside the already-admitted slot (same slot_token, single
# terminal event, single pump in finally): retries respect the concurrency
# gate and admission queue instead of bypassing them.
_MAX_AUTO_RETRIES = 2
_RETRY_BACKOFF_SECONDS = (5.0, 15.0)
_NO_RETRY_PERMANENT = frozenset(
    {
        "ERROR_PRIVATE",  # private video — retry cannot help
        "ERROR_UNAVAILABLE",  # deleted/unavailable video
        "ERROR_DRM",  # DRM-protected — deterministic
        "ERROR_QUOTA_EXCEEDED",  # disk full — retry cannot help
        "ERROR_FORMAT_UNAVAILABLE",  # no-video / photo-post class: no media
        "ERROR_FFMPEG_MISSING",  # environment issue, not per-item transient
        "ERROR_CANCELLED",  # user intent — never retry
    }
)


def _is_transient_retryable(err) -> bool:
    """True only for failures worth an auto-retry.

    Reuses classify_error()'s verdict (recoverable flag) minus the
    permanent denylist above. Never raises — unknown shapes do not retry.
    """
    try:
        if not bool(getattr(err, "recoverable", False)):
            return False
        return str(getattr(err, "error_type", "")) not in _NO_RETRY_PERMANENT
    except Exception:
        return False


def _note_attempt(download_id: str, attempt_no: int) -> None:
    """Record the per-item attempt counter on the active slot entry.

    Additive keys only (attempts/retries); never raises.
    """
    try:
        with _downloads_lock:
            info = _active_downloads.get(download_id)
            if isinstance(info, dict):
                info["attempts"] = attempt_no
                info["retries"] = max(0, attempt_no - 1)
    except Exception:
        pass


def _maybe_retry_transient(err, attempts_made: int, cancel, download_id: str) -> bool:
    """Sleep through backoff and approve one more attempt, or return False.

    Returns False when the attempts budget is spent, the failure is
    permanent, or cancellation was requested. Raises KeyboardInterrupt when
    cancellation lands during backoff so the normal cancelled path runs.
    Logs each approved retry at WARN with the attempt number.
    """
    if cancel is not None:
        try:
            if cancel.is_set():
                return False
        except Exception:
            pass
    if attempts_made > _MAX_AUTO_RETRIES:
        return False
    if not _is_transient_retryable(err):
        return False
    idx = min(attempts_made - 1, len(_RETRY_BACKOFF_SECONDS) - 1)
    delay = _RETRY_BACKOFF_SECONDS[idx]
    try:
        log.warn(
            f"Transient failure ({err.error_type}); auto-retry "
            f"attempt {attempts_made + 1}/{_MAX_AUTO_RETRIES + 1} after {delay:g}s",
            extra={"download_id": download_id},
        )
    except Exception:
        pass
    # The backoff sleep does NOT hold the concurrency slot: the slot is
    # released for the duration of the wait and re-acquired afterwards.
    _begin_backoff(download_id, delay, cancel)
    if cancel is not None:
        try:
            if cancel.is_set():
                raise KeyboardInterrupt("Download cancelled by user")
        except Exception:
            pass
    return True


def _single_item_error(url, opts, config, ydl_logger):
    """Classify a single-item logger.error tail, or None when not failing.

    Mirrors the single-vs-playlist determination: playlists keep lenient
    behavior (per-item deleted/private errors are normal), while any
    logger.error on a SINGLE item means broken output. Returns the
    GrablyticError for a failing single item, else None. Never raises.
    """
    try:
        errors = getattr(ydl_logger, "errors", None)
        if not errors:
            return None
        try:
            is_playlist_url = detect_playlist(url) if isinstance(url, str) else False
        except Exception:
            is_playlist_url = False
        try:
            safe_opts = opts or {}
            safe_config = config or {}
            if (
                safe_opts.get("noplaylist")
                or safe_config.get("no_playlist")
                or safe_opts.get("playlist_items") == "1"
            ):
                single = True
            elif is_playlist_url:
                single = False
            else:
                single = safe_opts.get("playlist_items") in (None, "1")
        except Exception:
            single = True
        if not single:
            return None
        last = errors[-1]
        # AARAV-1: classify the real message instead of a blanket
        # ERROR_POSTPROCESS_FAILED (Dart maps every known type).
        return classify_error(Exception(last))
    except Exception:
        return None


def _register_download_worker(
    url,
    download_id: str,
    config,
    progress_queue,
    result_queue,
    cancel_event,
    event_callback,
):
    config = coerce_config(config)
    cancel = cancel_event or threading.Event()
    progress = progress_queue or _queue.Queue(maxsize=_QUEUE_MAXSIZE)
    result = result_queue or _queue.Queue(maxsize=_QUEUE_MAXSIZE)
    with _downloads_lock:
        existing = _active_downloads.get(download_id, {})
        existing.update(
            {
                "cancel_event": cancel,
                "progress_queue": progress,
                "result_queue": result,
                "url": url,
                "audio_only": _is_audio_mode(config),
                "started_at": datetime.now(timezone.utc),
                "event_callback": event_callback or existing.get("event_callback"),
            }
        )
        _active_downloads[download_id] = existing
    return config, cancel, progress, result


def _safe_url_for_log(url) -> str:
    return url.split("?", 1)[0] if isinstance(url, str) else "<url>"


def _log_output_disk_space(download_id: str) -> None:
    try:
        out_dir = get_paths().get("output_dir") or get_paths().get("data_dir") or "."
        import shutil

        free_mb = shutil.disk_usage(out_dir).free // (1024 * 1024)
        log.info(
            f"Disk output ({out_dir}): {free_mb}MB free",
            extra={"download_id": download_id},
        )
    except Exception:
        pass


def _report_missing_ffmpeg(download_id: str, event_callback, result_queue) -> bool:
    paths = get_paths()
    ffmpeg_path = paths.get("ffmpeg_path")
    if ffmpeg_path and os.path.isfile(ffmpeg_path) and os.access(ffmpeg_path, os.X_OK):
        return False
    import shutil

    if shutil.which("ffmpeg"):
        return False
    message = "FFmpeg binary is missing or not executable. Please run bootstrap first."
    log.error(
        f"Cannot start download: FFmpeg binary is missing or not executable ({ffmpeg_path}). "
        "Please run bootstrap first.",
        extra={"download_id": download_id},
    )
    event = {
        "type": "event",
        "event": "error",
        "download_id": download_id,
        "error_type": "ERROR_FFMPEG_MISSING",
        "error_message": message,
        "recoverable": True,
    }
    result = {
        "success": False,
        "download_id": download_id,
        "error_type": "ERROR_FFMPEG_MISSING",
        "error_message": message,
    }
    _send_terminal_result(event_callback, result_queue, event, result)
    return True


def _send_terminal_result(event_callback, result_queue, event: dict, result: dict) -> None:
    if event_callback is not None:
        _emit_event(event_callback, json.dumps(event))
    else:
        result_queue.put(result)


def _log_effective_download_config(opts: dict, config: dict, download_id: str) -> None:
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
        if config.get("verbose"):
            from grablytic_engine.persistent import sanitize

            log.debug(
                f"Effective opts: {sanitize(opts)}",
                extra={"download_id": download_id},
            )
    except Exception:
        pass


def _build_download_options(
    url,
    download_id: str,
    config: dict,
    network_type: str,
    progress_queue,
    result_queue,
    event_callback,
):
    if _report_missing_ffmpeg(download_id, event_callback, result_queue):
        return None
    opts = build_ydl_opts(
        config=config,
        network_type=network_type,
        progress_queue=progress_queue,
        download_id=download_id,
        url=url,
        event_callback=event_callback,
    )
    paths = get_paths()
    if paths.get("cache_dir"):
        # Keep yt-dlp's internal cache apart from partial and completed media.
        opts["cachedir"] = paths["cache_dir"]
    _apply_verbosity(opts, config)
    _log_effective_download_config(opts, config, download_id)
    return opts


def _report_attempt_failure(
    download_id: str,
    event_callback,
    result_queue,
    error: GrablyticError,
    attempts_made: int,
) -> None:
    event = {
        "type": "event",
        "event": "error",
        "download_id": download_id,
        "error_type": error.error_type,
        "error_message": error.message,
        "recoverable": error.recoverable,
        "suggests_vpn": error.suggests_vpn,
        "attempts": attempts_made,
    }
    result = {
        "success": False,
        "download_id": download_id,
        "error_type": error.error_type,
        "error_message": error.message,
        "recoverable": error.recoverable,
        "suggests_vpn": error.suggests_vpn,
        "attempts": attempts_made,
    }
    _send_terminal_result(event_callback, result_queue, event, result)


def _run_download_attempts(
    url,
    download_id: str,
    config: dict,
    opts: dict,
    cancel,
    result_queue,
    event_callback,
    safe_url: str,
):
    attempts_made = 0
    while True:
        attempts_made += 1
        _note_attempt(download_id, attempts_made)
        ydl_logger = YDLogger(log, download_id=download_id)
        opts["logger"] = ydl_logger
        try:
            ydl = YoutubeDL(opts)

            def ydl_hook(progress):
                if cancel.is_set():
                    raise KeyboardInterrupt("Download cancelled by user")
                return progress

            ydl.add_progress_hook(ydl_hook)
            ydl.download([url])
        except Exception as exc:
            error = classify_error(exc)
            if _maybe_retry_transient(error, attempts_made, cancel, download_id):
                continue
            log.log_exception(
                exc,
                f"Download failed: {safe_url}",
                extra={"download_id": download_id},
            )
            _report_attempt_failure(
                download_id, event_callback, result_queue, error, attempts_made
            )
            return None

        single_error = _single_item_error(url, opts, config, ydl_logger)
        if single_error is None:
            return attempts_made, ydl_logger
        if _maybe_retry_transient(single_error, attempts_made, cancel, download_id):
            continue
        try:
            last_message = ydl_logger.errors[-1] if ydl_logger.errors else ""
        except Exception:
            last_message = ""
        log.error(
            f"Download failed, failing item: {last_message[:200]}",
            extra={"download_id": download_id},
        )
        _report_attempt_failure(
            download_id, event_callback, result_queue, single_error, attempts_made
        )
        return None


def _send_cancelled_result(download_id: str, event_callback, result_queue) -> None:
    event = {
        "type": "event",
        "event": "cancelled",
        "download_id": download_id,
        "error_type": "ERROR_CANCELLED",
        "error_message": "Download cancelled by user",
    }
    result = {
        "success": False,
        "download_id": download_id,
        "error_type": "ERROR_CANCELLED",
        "error_message": "Download cancelled by user",
    }
    _send_terminal_result(event_callback, result_queue, event, result)


def _select_output_path(ydl_logger: YDLogger, progress_file):
    for output_path in reversed(ydl_logger.output_files):
        if os.path.isfile(output_path):
            return output_path
    if progress_file and os.path.isfile(progress_file):
        return progress_file
    return None


def _reconcile_output_size(final_path, final_bytes: int) -> int:
    if not final_path:
        return final_bytes
    try:
        disk_size = os.path.getsize(final_path)
    except Exception:
        return final_bytes
    if disk_size > 0 and (final_bytes <= 0 or disk_size > final_bytes):
        return disk_size
    return final_bytes


def _report_download_success(
    download_id: str,
    config: dict,
    progress_queue,
    result_queue,
    event_callback,
    ydl_logger: YDLogger,
    attempts_made: int,
) -> None:
    final_bytes, progress_file = _last_known_file_info(progress_queue)
    final_path = _select_output_path(ydl_logger, progress_file)
    final_bytes = _reconcile_output_size(final_path, final_bytes)
    _delete_infojson_sidecars(final_path)
    thumbnail_path = _find_thumbnail_path(final_path, config)
    event = {
        "type": "event",
        "event": "finished",
        "download_id": download_id,
        "filesize_bytes": final_bytes,
        "total_bytes": final_bytes,
        "file_path": final_path,
        "thumbnail_path": thumbnail_path,
        "attempts": attempts_made,
    }
    result = {
        "success": True,
        "download_id": download_id,
        "filesize_bytes": final_bytes,
        "file_path": final_path,
        "thumbnail_path": thumbnail_path,
        "attempts": attempts_made,
    }
    _send_terminal_result(event_callback, result_queue, event, result)


def _execute_download(
    url,
    download_id: str,
    config: dict,
    network_type: str,
    progress_queue,
    result_queue,
    cancel,
    event_callback,
    safe_url: str,
) -> None:
    log.info(f"Download started: {safe_url}", extra={"download_id": download_id})
    _log_output_disk_space(download_id)
    opts = _build_download_options(
        url,
        download_id,
        config,
        network_type,
        progress_queue,
        result_queue,
        event_callback,
    )
    if opts is None:
        return
    outcome = _run_download_attempts(
        url,
        download_id,
        config,
        opts,
        cancel,
        result_queue,
        event_callback,
        safe_url,
    )
    if outcome is None:
        return
    attempts_made, ydl_logger = outcome
    if cancel.is_set():
        log.warn(f"Download cancelled: {download_id}", extra={"download_id": download_id})
        _send_cancelled_result(download_id, event_callback, result_queue)
        return
    log.info("Download completed", extra={"download_id": download_id})
    _report_download_success(
        download_id,
        config,
        progress_queue,
        result_queue,
        event_callback,
        ydl_logger,
        attempts_made,
    )


def _report_download_exception(
    exc: Exception, safe_url: str, download_id: str, event_callback, result_queue
) -> None:
    log.log_exception(
        exc, f"Download failed: {safe_url}", extra={"download_id": download_id}
    )
    error = classify_error(exc)
    event = {
        "type": "event",
        "event": "error",
        "download_id": download_id,
        "error_type": error.error_type,
        "error_message": error.message,
        "recoverable": error.recoverable,
        "suggests_vpn": error.suggests_vpn,
    }
    result = {
        "success": False,
        "download_id": download_id,
        "error_type": error.error_type,
        "error_message": error.message,
        "recoverable": error.recoverable,
        "suggests_vpn": error.suggests_vpn,
    }
    _send_terminal_result(event_callback, result_queue, event, result)


def _report_download_crash(exc: BaseException, download_id: str, event_callback, result_queue) -> None:
    kind = type(exc).__name__
    try:
        log.error(
            f"Download aborted ({kind}): {download_id}",
            extra={"download_id": download_id},
        )
    except Exception:
        pass
    message = f"Downloader stopped unexpectedly ({kind})"
    event = {
        "type": "event",
        "event": "error",
        "download_id": download_id,
        "error_type": "ERROR_DOWNLOADER_CRASH",
        "error_message": message,
        "recoverable": True,
        "suggests_vpn": False,
    }
    result = {
        "success": False,
        "download_id": download_id,
        "error_type": "ERROR_DOWNLOADER_CRASH",
        "error_message": message,
        "recoverable": True,
        "suggests_vpn": False,
    }
    _send_terminal_result(event_callback, result_queue, event, result)


def _finish_download_worker(download_id: str, slot_token, event_callback) -> None:
    log.clear_context()
    _set_current_cancel_event(None)
    owned = _close_own_slot(download_id, slot_token)
    if not owned:
        return
    if event_callback is not None:
        _mark_result_delivered(download_id)
    try:
        _pump_queue()
    except Exception:
        pass


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
        config, cancel, progress, result = _register_download_worker(
            url,
            download_id,
            config,
            progress_queue,
            result_queue,
            cancel_event,
            event_callback,
        )
        log.set_context(download_id=download_id)
        _set_current_cancel_event(cancel)
        try:
            _ensure_ffmpeg_serialized()
        except Exception:
            pass

        safe_url = "<url>"
        try:
            safe_url = _safe_url_for_log(url)
            _execute_download(
                url,
                download_id,
                config,
                network_type,
                progress,
                result,
                cancel,
                event_callback,
                safe_url,
            )
        except KeyboardInterrupt:
            log.warn(
                f"Download cancelled: {download_id}",
                extra={"download_id": download_id},
            )
            _send_cancelled_result(download_id, event_callback, result)
        except Exception as exc:
            _report_download_exception(
                exc, safe_url, download_id, event_callback, result
            )
        except BaseException as exc:
            _report_download_crash(exc, download_id, event_callback, result)
        finally:
            _finish_download_worker(download_id, slot_token, event_callback)


def _start_download_preflight(download_id: str, url: str) -> dict | None:
    with _shutdown_lock:
        if _is_shutting_down:
            return {
                "success": False,
                "download_id": download_id,
                "error_type": "ERROR_SHUTTING_DOWN",
                "error_message": "Engine is shutting down",
            }
    try:
        from grablytic_engine.url_guard import is_safe_media_url

        safe_url = is_safe_media_url(url)
    except Exception:
        safe_url = False
    if safe_url:
        return None
    return {
        "success": False,
        "download_id": download_id,
        "error_type": "ERROR_INVALID_PARAM",
        "error_message": "URL must be a public http(s) address",
    }


def _admission_conflict(download_id: str, url: str, audio_only: bool) -> dict | None:
    existing = _active_downloads.get(download_id)
    if existing is not None and not existing.get("finished_at"):
        return {
            "success": False,
            "download_id": download_id,
            "error_type": "ERROR_ALREADY_ACTIVE",
            "error_message": "Download already in progress for this ID",
        }
    if existing is not None:
        _active_downloads.pop(download_id, None)
    if download_id in _pending_queue:
        return {
            "success": False,
            "download_id": download_id,
            "error_type": "ERROR_ALREADY_ACTIVE",
            "error_message": "Download already queued for this ID",
        }
    holder = _find_live_url_holder(url, audio_only)
    if holder is None:
        return None
    return {
        "success": False,
        "download_id": download_id,
        "error_type": "ERROR_DUPLICATE_URL",
        "error_message": f"URL already downloading under ID {holder}",
        "existing_download_id": holder,
    }


def _new_download_queues() -> tuple:
    return (
        _queue.Queue(maxsize=_QUEUE_MAXSIZE),
        _queue.Queue(maxsize=_QUEUE_MAXSIZE),
        threading.Event(),
    )


def _admit_download(
    url: str,
    download_id: str,
    config: dict | None,
    network_type: str,
    event_callback,
) -> dict:
    with _downloads_lock:
        audio_only = _is_audio_mode(config)
        conflict = _admission_conflict(download_id, url, audio_only)
        if conflict is not None:
            return {"error": conflict}
        queued = _running_count() >= _max_concurrent
        if queued and len(_pending_queue) >= _MAX_PENDING_QUEUE:
            return {
                "error": {
                    "success": False,
                    "download_id": download_id,
                    "error_type": "ERROR_QUEUE_FULL",
                    "error_message": (
                        "Download queue is full "
                        f"(maximum {_MAX_PENDING_QUEUE} pending items)"
                    ),
                    "queue_size": len(_pending_queue),
                    "max_queue_size": _MAX_PENDING_QUEUE,
                }
            }
        progress_queue, result_queue, cancel_event = _new_download_queues()
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
        if queued:
            _pending_queue[download_id] = entry
            _index_add(download_id, url, audio_only)
            position = len(_pending_queue)
        else:
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
                "result_delivered": False,
            }
            _index_add(download_id, url, audio_only)
            position = None
    return {"queued": queued, "position": position, "entry": entry}


def _notify_queued_download(entry: dict, position: int) -> None:
    callback = entry.get("event_callback")
    if callback is None:
        return
    try:
        _emit_event(
            callback,
            json.dumps(
                {
                    "type": "event",
                    "event": "queued",
                    "download_id": entry["download_id"],
                    "position": position,
                }
            ),
        )
    except Exception:
        pass


def start_download(
    url: str,
    download_id: str,
    config: dict | None = None,
    network_type: str = "wifi",
    event_callback=None,
) -> dict:
    error = _start_download_preflight(download_id, url)
    if error is not None:
        return error
    admission = _admit_download(
        url, download_id, config, network_type, event_callback
    )
    if "error" in admission:
        return admission["error"]
    entry = admission["entry"]
    if event_callback is not None:
        try:
            set_global_event_callback(event_callback)
        except Exception:
            pass
    _ensure_cleanup_thread()
    if admission["queued"]:
        _notify_queued_download(entry, admission["position"])
        return {
            "success": True,
            "download_id": download_id,
            "thread_started": False,
            "queued": True,
            "position": admission["position"],
        }
    _spawn_thread(entry)
    return {
        "success": True,
        "download_id": download_id,
        "thread_started": True,
        "queued": False,
    }


def _cancel_terminal_payload(download_id: str) -> tuple[str, dict]:
    event = json.dumps(
        {
            "type": "event",
            "event": "cancelled",
            "download_id": download_id,
            "error_type": "ERROR_CANCELLED",
            "error_message": "Download cancelled by user",
        }
    )
    result = {
        "success": False,
        "download_id": download_id,
        "error_type": "ERROR_CANCELLED",
        "error_message": "Download cancelled by user",
    }
    return event, result


def _deliver_cancel_terminal(download_id: str, info: dict) -> None:
    event, result = _cancel_terminal_payload(download_id)
    callback = info.get("event_callback")
    if callback is not None:
        try:
            _emit_event(callback, event)
        except Exception:
            pass
        return
    try:
        info["result_queue"].put(result)
    except Exception:
        pass


def _take_cancel_state(download_id: str) -> tuple:
    queued_entry = None
    worker_thread = None
    worker_alive = False
    active_slot_token = None
    active_info = None
    with _downloads_lock:
        queued_entry = _pending_queue.pop(download_id, None)
        if queued_entry is not None:
            _index_remove(
                download_id,
                queued_entry.get("url"),
                _is_audio_mode(queued_entry.get("config")),
            )
        info = _active_downloads.get(download_id)
        if queued_entry is None and not info:
            return None, None, None, False, None, True
        if info and not info.get("finished_at"):
            try:
                info["cancel_event"].set()
            except Exception:
                pass
            worker_thread = info.get("thread")
            worker_alive = _worker_thread_alive(info)
            active_slot_token = info.get("slot_token")
            active_info = info
    return (
        queued_entry,
        active_info,
        worker_thread,
        worker_alive,
        active_slot_token,
        False,
    )


def _finish_queued_cancel(download_id: str, entry: dict) -> None:
    _deliver_cancel_terminal(download_id, entry)
    if entry.get("event_callback") is not None:
        return
    with _downloads_lock:
        _active_downloads[download_id] = {
            "cancel_event": entry["cancel_event"],
            "progress_queue": entry["progress_queue"],
            "result_queue": entry["result_queue"],
            "url": entry["url"],
            "audio_only": _is_audio_mode(entry.get("config")),
            "thread": None,
            "started_at": entry.get("queued_at") or datetime.now(timezone.utc),
            "finished_at": datetime.now(timezone.utc),
            "slot_token": _new_slot_token(),
        }


def _finish_stopped_cancel(
    download_id: str, info: dict, slot_token: str | None
) -> None:
    if not _close_own_slot(download_id, slot_token):
        return
    _deliver_cancel_terminal(download_id, info)
    try:
        _pump_queue()
    except Exception:
        pass


def cancel_download(download_id: str) -> dict:
    (
        queued_entry,
        active_info,
        worker_thread,
        worker_alive,
        active_slot_token,
        missing,
    ) = _take_cancel_state(download_id)
    if missing:
        return {
            "success": False,
            "error_type": "ERROR_DOWNLOAD_NOT_FOUND",
            "error_message": f"No active download with ID: {download_id}",
        }
    if queued_entry is not None:
        _finish_queued_cancel(download_id, queued_entry)
    if active_info is not None and not worker_alive:
        _finish_stopped_cancel(download_id, active_info, active_slot_token)
    if worker_alive:
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


# Bound on "cancelling". A worker wedged where no yt-dlp progress hook
# ever fires again would otherwise leave the UI in "cancelling" forever.
# CPython threads cannot be killed, and Popen-handle interposition was
# rejected (yt-dlp helper-thread births misattribute kills across
# downloads). So on expiry: free the slot (finished_at stamp — the exact
# mechanism of the worker finally-block, keeping _cleanup_loop's invariant)
# and emit a presumed-stopped terminal. A late real terminal from the worker
# is benign (Dart treats duplicate cancelled idempotently; res_q leftovers
# drain via _cleanup_loop's 30s failsafe). Monkeypatchable in tests.
_CANCEL_WATCHDOG_SECONDS = 120.0

# The watchdog used to spawn ONE THREAD PER CANCELLED DOWNLOAD, and each
# of those threads lived for up to _CANCEL_WATCHDOG_SECONDS. A user who
# cancelled 200 downloads therefore had 200 live threads, each blocked in
# `join()` — an unbounded thread-per-event leak, and a real memory/fd
# cost on a phone.
#
# The watchdog is now a FIXED POOL of daemon workers fed by a queue. Each
# job carries the deadline stamped at CANCEL time (not at dequeue time),
# so a job that waits in the queue cannot extend the user's window.
_WATCHDOG_POOL_SIZE = 4
_watchdog_queue: _queue.Queue = _queue.Queue()
_watchdog_active_ids: set[str] = set()
_watchdog_pool_lock = threading.Lock()
_watchdog_pool_state = {"started": False, "generation": 0}
# Captured at import: the test suite swaps `threading.Thread` globally,
# and the pool must still be able to start real workers.
_real_thread = threading.Thread


def _worker_thread_alive(info) -> bool:
    """True only for a provably-live worker thread.

    Pre-spawn entries (thread None) and thread doubles without is_alive
    (test NoopThreads) report False and use the legacy terminal path.
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


def _watchdog_generation_is_current(generation: int) -> bool:
    with _watchdog_pool_lock:
        return generation == _watchdog_pool_state["generation"]


def _watchdog_worker(generation: int) -> None:
    """Run watchdog jobs until the pool generation is retired."""
    while _watchdog_generation_is_current(generation):
        try:
            job = _watchdog_queue.get(timeout=0.5)
        except _queue.Empty:
            continue
        try:
            _run_watchdog_job(job)
        except Exception:
            pass
        finally:
            try:
                _watchdog_queue.task_done()
            except Exception:
                pass
            download_id = (job or {}).get("download_id")
            if download_id:
                with _watchdog_pool_lock:
                    _watchdog_active_ids.discard(download_id)


def _ensure_watchdog_pool() -> None:
    """Start the fixed watchdog pool if it is not running."""
    with _watchdog_pool_lock:
        if _watchdog_pool_state["started"]:
            return
        _watchdog_pool_state["started"] = True
        _watchdog_pool_state["generation"] += 1
        generation = _watchdog_pool_state["generation"]
    for i in range(_WATCHDOG_POOL_SIZE):
        try:
            t = _real_thread(
                target=_watchdog_worker,
                args=(generation,),
                daemon=True,
                name=f"cancel-watchdog-{i}",
            )
            t.start()
        except Exception:
            pass


def stop_watchdog_pool() -> None:
    """Stop the watchdog pool. Called from `shutdown_downloads`."""
    with _watchdog_pool_lock:
        if not _watchdog_pool_state["started"]:
            return
        _watchdog_pool_state["started"] = False
        # Retire the workers: each one exits at its next loop check.
        _watchdog_pool_state["generation"] += 1
        _watchdog_active_ids.clear()


def _run_watchdog_job(job: dict) -> None:
    """Wait out the watchdog window for one cancelled download.

    If the worker is still alive when the deadline passes, the download is
    presumed stopped: the slot is released and a terminal is emitted.
    """
    download_id = job.get("download_id")
    worker_thread = job.get("thread")
    deadline = job.get("deadline")
    try:
        remaining = max(0.0, float(deadline) - time.monotonic())
    except Exception:
        remaining = 0.0
    join = getattr(worker_thread, "join", None)
    if callable(join):
        try:
            join(timeout=remaining)
        except Exception:
            pass
    try:
        if not bool(worker_thread.is_alive()):
            return  # worker exited; its own terminal stands
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
    terminal = json.dumps(
        {
            "type": "event",
            "event": "cancelled",
            "download_id": download_id,
            "error_type": "ERROR_CANCELLED",
            "error_message": presumed_message,
        }
    )
    if cb is not None:
        try:
            _emit_event(cb, terminal)
        except Exception:
            pass
    elif res_q is not None:
        try:
            res_q.put(
                {
                    "success": False,
                    "download_id": download_id,
                    "error_type": "ERROR_CANCELLED",
                    "error_message": presumed_message,
                }
            )
        except Exception:
            pass
    # A wedged worker never reaches its finally-block, so promote the
    # next queued entry here (same call the finally-block makes).
    try:
        _pump_queue()
    except Exception:
        pass


def _start_cancel_watchdog(download_id: str, worker_thread) -> None:
    """Queue a bounded watchdog job for a cancelled download.

    One job per download id: a second cancel of the same id must not
    create a second watchdog, because the first one already owns the
    slot. The deadline is stamped NOW — at cancel time — so the job's
    wait window is measured from the user's action, not from when a
    pool worker happens to pick the job up.
    """
    _ensure_watchdog_pool()
    with _watchdog_pool_lock:
        if download_id in _watchdog_active_ids:
            return
        _watchdog_active_ids.add(download_id)
    job = {
        "download_id": download_id,
        "thread": worker_thread,
        "deadline": time.monotonic() + _CANCEL_WATCHDOG_SECONDS,
    }
    try:
        _watchdog_queue.put_nowait(job)
    except Exception:
        with _watchdog_pool_lock:
            _watchdog_active_ids.discard(download_id)


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
            return {
                "success": False,
                "removed": False,
                "path": None,
                "error_message": "Data dir not configured",
            }

        resolved_data_dir = _os.path.realpath(data_dir)

        if archive_path:
            path = _os.path.realpath(archive_path)
        else:
            path = _os.path.realpath(_os.path.join(data_dir, "download_archive.txt"))

        # ── Containment gate ──────────────────────────────────────────
        # Verify the resolved path is strictly inside the resolved
        # data_dir.  Use os.path.commonpath to avoid the classic
        # "/data/dir_evil" matching prefix "/data/dir" substring bug.
        # Also reject paths that resolve to data_dir itself (must be a
        # *child*, not the dir).
        if not path.startswith(resolved_data_dir + _os.sep):
            return {
                "success": False,
                "removed": False,
                "path": None,
                "error_message": "Path escapes data directory",
            }

        # Regular file only, never a directory or special file.
        if not _os.path.isfile(path):
            return {"success": True, "removed": False, "path": path}

        _os.remove(path)
        return {"success": True, "removed": True, "path": path}
    except Exception as exc:
        return {
            "success": False,
            "removed": False,
            "path": None,
            "error_message": str(exc)[:200],
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
