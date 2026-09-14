import os
import time
import json


def scan_resume_candidates(cache_dir: str) -> dict:
    candidates = []
    now = time.time()
    max_age = 86400  # 24h

    if not os.path.isdir(cache_dir):
        return {"success": True, "candidates": []}

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
        info_path = filepath.replace(".part", "") + ".info.json"
        if not os.path.exists(info_path):
            base, _ = os.path.splitext(filepath.replace(".part", ""))
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

    return {"success": True, "candidates": candidates}
