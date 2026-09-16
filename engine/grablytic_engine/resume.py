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
    try:
        from grablytic_engine.paths import get_paths
        data_dir = get_paths().get("data_dir")
        if data_dir and os.path.isdir(data_dir):
            return os.path.join(data_dir, _ATTEMPTS_FILENAME)
    except Exception:
        pass
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


def _is_strictly_contained(parent: str, child: str) -> bool:
    try:
        real_parent = os.path.realpath(parent)
        real_child = os.path.realpath(child)
    except (OSError, ValueError):
        return False
    if real_parent == real_child:
        return False
    try:
        return os.path.commonpath([real_parent, real_child]) == real_parent
    except (ValueError, OSError):
        return False


def _contained_path(cache_dir: str, filepath: str) -> str | None:
    """Realpath of filepath if strictly inside cache_dir or allowed engine paths, else None."""
    try:
        real = os.path.realpath(filepath)
    except OSError:
        return None

    allowed_roots = [cache_dir]
    try:
        from grablytic_engine.paths import get_paths
        p = get_paths()
        for k in ("output_dir", "data_dir", "cache_dir"):
            v = p.get(k)
            if v and isinstance(v, str) and v not in allowed_roots:
                allowed_roots.append(v)
    except Exception:
        pass

    for root in allowed_roots:
        if root and os.path.isdir(root) and _is_strictly_contained(root, real):
            return real
    return None


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
    """Yield .part file paths (top level, or walk bounded by depth and max files)."""
    cap = max_files if max_files is not None else _MAX_SCAN_FILES
    yielded = 0
    total_inspected = 0
    max_inspected = 5000

    if not recursive:
        try:
            entries = os.listdir(cache_dir)
        except OSError:
            return
        for entry in entries:
            total_inspected += 1
            if entry.endswith(".part"):
                yield os.path.join(cache_dir, entry)
                yielded += 1
                if yielded >= cap:
                    return
            if total_inspected >= max_inspected:
                return
        return

    base_depth = cache_dir.rstrip(os.sep).count(os.sep)
    for root, _dirs, files in os.walk(cache_dir, followlinks=False):
        current_depth = root.rstrip(os.sep).count(os.sep) - base_depth
        if current_depth >= 2:
            _dirs.clear()
        for name in files:
            total_inspected += 1
            if name.endswith(".part"):
                yield os.path.join(root, name)
                yielded += 1
                if yielded >= cap:
                    return
            if total_inspected >= max_inspected:
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
        clean_stem = _strip_part_suffix(filepath)
        info_path = clean_stem + ".info.json"
        if not os.path.exists(info_path):
            base, _ = os.path.splitext(clean_stem)
            info_path = base + ".info.json"
        if not os.path.exists(info_path):
            # Split stream tag e.g. <title>.f137.mp4 -> <title>.info.json
            import re
            base_no_fmt = re.sub(r"\.f[a-zA-Z0-9_-]+(?=\.[^.]+$|$)", "", clean_stem)
            info_path = base_no_fmt + ".info.json"
            if not os.path.exists(info_path):
                base_dir = os.path.dirname(filepath)
                base_name = os.path.splitext(os.path.basename(base_no_fmt))[0]
                info_path = os.path.join(base_dir, base_name + ".info.json")

        if os.path.exists(info_path):
            try:
                with open(info_path, "r", encoding="utf-8") as f:
                    info_data = json.load(f)
                    likely_url = (
                        info_data.get("webpage_url")
                        or info_data.get("original_url")
                        or info_data.get("url")
                    )
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
