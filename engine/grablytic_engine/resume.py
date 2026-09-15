import os
import time
import json


def _strip_part_suffix(path: str) -> str:
    """Remove one trailing '.part' only.

    str.replace() would strip EVERY occurrence, mangling names like
    'my.part.video.f137.part' into 'my.video.f137' and missing the
    sibling .info.json.
    """
    if path.endswith(".part"):
        return path[: -len(".part")]
    return path


def scan_resume_candidates(cache_dir: str, limit: int = 50) -> dict:
    """Scan for interrupted (.part) downloads.

    Contract (Dart home_screen renders `expired` rows distinctly and only
    offers resume for fresh ones with a URL): expired entries are FLAGGED,
    never dropped. Freshest-first, capped at `limit` with `total`/`truncated`
    so the UI can say "showing 50 of 132". Additive keys only — older Dart
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
        limit = 50
    limit = max(1, limit)

    for entry in os.listdir(cache_dir):
        if not entry.endswith(".part"):
            continue

        filepath = os.path.join(cache_dir, entry)
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

        candidates.append({
            "filename": entry,
            "filepath": filepath,
            "size_bytes": stat.st_size,
            "age_seconds": int(age),
            "likely_url": likely_url,
            "expired": age > max_age,
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
