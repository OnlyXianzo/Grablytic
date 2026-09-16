import os
import time
import json
import threading


def _strip_part_suffix(path: str) -> str:
    """Remove one trailing '.part' only.

    str.replace() would strip EVERY occurrence, mangling names like
    'my.part.video.f137.part' into 'my.video.f137' and missing the
    sibling .info.json.
    """
    if path.endswith(".part"):
        return path[: -len(".part")]
    return path


# Strike store for resume attempts (BRUTAL-5 attempts>=3). Keyed by
# realpath so renames/case variants cannot fork counters. Same-process
# lock discipline as the bootstrap manifest (single engine process).
_attempts_lock = threading.Lock()
_ATTEMPTS_FILENAME = "resume_attempts.json"
_DEFAULT_MAX_ATTEMPTS = 3
_DEFAULT_RESUME_LIMIT = 50
_MAX_RESUME_LIMIT = 500
_MAX_SCAN_FILES = 2000


def _attempts_path(cache_dir: str) -> str:
    return os.path.join(cache_dir, _ATTEMPTS_FILENAME)


def _load_attempts(cache_dir: str) -> dict:
    try:
        with open(_attempts_path(cache_dir), "r", encoding="utf-8") as f:
            data = json.load(f)
            return data if isinstance(data, dict) else {}
    except (FileNotFoundError, json.JSONDecodeError, OSError, ValueError):
        return {}


def _save_attempts(cache_dir: str, attempts: dict) -> None:
    path = _attempts_path(cache_dir)
    tmp = path + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(attempts, f)
        os.replace(tmp, path)
    except OSError:
        pass


def _contained_path(cache_dir: str, filepath: str) -> str | None:
    """Realpath of filepath if strictly inside cache_dir, else None."""
    try:
        base = os.path.realpath(cache_dir)
        real = os.path.realpath(filepath)
    except OSError:
        return None
    if real == base or not real.startswith(base + os.sep):
        return None
    return real


def report_resume_attempt(cache_dir: str, filepath: str, success) -> dict:
    """Record the outcome of one resume try for filepath.

    success=True clears the strike count (file completed); falsy increments
    it. Paths escaping cache_dir are rejected. Never raises.
    """
    try:
        if not os.path.isdir(cache_dir):
            return {"success": False, "error_message": "Unknown cache dir"}
        real = _contained_path(cache_dir, filepath)
        if real is None:
            return {"success": False, "error_message": "Path escapes cache dir"}
        ok = bool(success) if not isinstance(success, str) else success.strip().lower() in (
            "1", "true", "yes",
        )
        with _attempts_lock:
            attempts = _load_attempts(cache_dir)
            if ok:
                attempts.pop(real, None)
                count = 0
            else:
                rec = attempts.get(real)
                count = (rec.get("attempts", 0) if isinstance(rec, dict) else 0) + 1
                attempts[real] = {"attempts": count, "updated": int(time.time())}
            _save_attempts(cache_dir, attempts)
        return {"success": True, "attempts": count}
    except Exception as exc:
        return {"success": False, "error_message": str(exc)[:200]}


def _iter_part_files(cache_dir: str, recursive: bool, max_files: int | None = None):
    """Yield .part file paths (top level, or full walk without followlinks)."""
    cap = max_files if max_files is not None else _MAX_SCAN_FILES
    yielded = 0
    if not recursive:
        try:
            entries = os.listdir(cache_dir)
        except OSError:
            return
        for entry in entries:
            if entry.endswith(".part"):
                yield os.path.join(cache_dir, entry)
                yielded += 1
                if yielded >= cap:
                    return
        return
    for root, _dirs, files in os.walk(cache_dir, followlinks=False):
        for name in files:
            if name.endswith(".part"):
                yield os.path.join(root, name)
                yielded += 1
                if yielded >= cap:
                    return


def scan_resume_candidates(
    cache_dir: str,
    limit: int = 50,
    recursive: bool = True,
    max_attempts: int = _DEFAULT_MAX_ATTEMPTS,
) -> dict:
    """Scan for interrupted (.part) downloads.

    Contract (Dart home_screen renders `expired` rows distinctly and only
    offers resume for fresh ones with a URL): expired entries are FLAGGED,
    never dropped. Freshest-first, capped at `limit` with `total`/`truncated`
    so the UI can say "showing 50 of 132". Each candidate also carries its
    strike `attempts` and `exhausted` (>= max_attempts failed resume tries,
    recorded via report_resume_attempt). Additive keys only — older Dart
    builds ignore the extras.
    """
    candidates = []
    now = time.time()
    max_age = 86400  # 24h

    if not os.path.isdir(cache_dir):
        return {"success": True, "candidates": [], "total": 0, "truncated": False}

    try:
        limit = int(limit)
    except (TypeError, ValueError):
        limit = _DEFAULT_RESUME_LIMIT
    limit = max(1, min(limit, _MAX_RESUME_LIMIT))
    try:
        max_attempts = int(max_attempts)
    except (TypeError, ValueError):
        max_attempts = _DEFAULT_MAX_ATTEMPTS
    max_attempts = max(1, max_attempts)
    if not isinstance(recursive, bool):
        recursive = True

    with _attempts_lock:
        strikes = _load_attempts(cache_dir)

    for filepath in _iter_part_files(cache_dir, recursive):
        entry = os.path.basename(filepath)
        try:
            stat = os.stat(filepath)
        except OSError:
            continue

        age = now - stat.st_mtime

        likely_url = None
        info_path = _strip_part_suffix(filepath) + ".info.json"
        if not os.path.exists(info_path):
            base, _ = os.path.splitext(_strip_part_suffix(filepath))
            info_path = base + ".info.json"

        if os.path.exists(info_path):
            try:
                with open(info_path, "r", encoding="utf-8") as f:
                    info_data = json.load(f)
                    likely_url = info_data.get("webpage_url") or info_data.get("url")
            except Exception:
                pass

        try:
            real = os.path.realpath(filepath)
        except OSError:
            real = filepath
        rec = strikes.get(real)
        attempts = rec.get("attempts", 0) if isinstance(rec, dict) else 0
        candidates.append({
            "filename": entry,
            "filepath": filepath,
            "size_bytes": stat.st_size,
            "age_seconds": int(age),
            "likely_url": likely_url,
            "expired": age > max_age,
            "attempts": attempts,
            "exhausted": attempts >= max_attempts,
        })

    # Freshest first so a cap drops the stalest, never the newest. Expired
    # rows stay in the payload (flagged) while they fit — the UI decides.
    candidates.sort(key=lambda c: c["age_seconds"])
    total = len(candidates)
    truncated = total > limit
    return {
        "success": True,
        "candidates": candidates[:limit],
        "total": total,
        "truncated": truncated,
    }
