#!/usr/bin/env python3
"""Generates automated stable-release notes from git history.

Usage:
    python3 tool/generate_release_changelog.py <base_tag> <new_version>
    e.g. python3 tool/generate_release_changelog.py v0.0.2 0.0.4

Output: markdown to stdout with:
  - diffstat summary (files changed, insertions, deletions) since base_tag
  - per-area line counts (engine, android native, flutter UI, tests, ci/docs)
  - every non-merge commit grouped by subsystem (no hand curation)

Deterministic and stdlib-only: rerunning on the same history yields the
same notes. Merge commits are folded (their contents are the commits).
"""

import re
import subprocess
import sys
from datetime import datetime, timezone

ROOT = __file__.rsplit("/tool/", 1)[0]


def run(cmd: list[str]) -> str:
    return subprocess.run(
        cmd, cwd=ROOT, capture_output=True, text=True, check=True
    ).stdout.strip()


CATEGORIES: list[tuple[str, list[str]]] = [
    ("Security & Trust Boundaries",
     ["sec(", "trust", "sanitiz", "boundary", "injection", "fail-closed",
      "ssrf", "digest", "shasum", "checksum", "semaphore"]),
    ("Resume & Artifact Hygiene",
     ["resume", "strike", "sidecar", "infojson", ".part", "opts_builder"]),
    ("Android Native & OS Integration",
     ["android", "wakelock", "service", "activity", "sqlite", "sweep",
      "bootreceiver", "fileprovider", "fgs", "kotlin"]),
    ("Core Engine & yt-dlp",
     ["engine", "downloader", "queue", "concurrency", "extractor",
      "po_token", "js_runtime", "formats", "playlist", "yt-dlp", "ipc",
      "ffmpeg", "aria2", "opts", "url_guard"]),
    ("UI & Client State",
     ["flutter", "screen", "settings", "library", "onboarding", "player",
      "grid", "log viewer", "log_viewer", "media_preview", "theme"]),
    ("CI/CD, Build & Install",
     ["ci(", "ci:", "build", "nightly", "workflow", "install.sh",
      "publish", "lint", "ruff", "winget", "release"]),
    ("Performance & Resources",
     ["perf", "throttle", "memory", "leak", "sparkline", "rebuild"]),
]

AREA_PREFIXES = {
    "Python engine": ["engine/"],
    "Android native": ["android/"],
    "Flutter UI": ["lib/", "test/"],
    "Packaging & install": ["install.sh", "distribution/", "tool/"],
    "CI & workflows": [".github/"],
    "Docs & store": ["docs/", "fastlane/", "README.md", "pubspec.yaml"],
}


def categorize(subject: str) -> str:
    s = subject.lower()
    for name, keys in CATEGORIES:
        if any(k in s for k in keys):
            return name
    return "General Improvements"


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip().splitlines()[3].strip())
        return 2
    base, version = sys.argv[1], sys.argv[2]
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    log = run(["git", "log", f"{base}..HEAD", "--no-merges",
               "--format=%H %s"])
    commits = []
    for line in log.splitlines():
        sha, _, subject = line.partition(" ")
        if subject:
            commits.append((sha[:9], subject))

    groups: dict[str, list[tuple[str, str]]] = {}
    for sha, subject in commits:
        groups.setdefault(categorize(subject), []).append((sha, subject))

    shortstat = run(["git", "diff", "--shortstat", f"{base}..HEAD"])
    files = run(["git", "diff", "--numstat", f"{base}..HEAD"]).splitlines()
    area_add = {a: 0 for a in AREA_PREFIXES}
    area_del = {a: 0 for a in AREA_PREFIXES}
    other_add = other_del = 0
    for line in files:
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        try:
            a, d = int(parts[0]), int(parts[1])
        except ValueError:
            continue  # binary files report '-'
        path = parts[2]
        for area, prefixes in AREA_PREFIXES.items():
            if any(path.startswith(p) or path == p for p in prefixes):
                area_add[area] += a
                area_del[area] += d
                break
        else:
            other_add += a
            other_del += d

    out = [f"## v{version} — {today} ({len(commits)} commits since {base})",
           "",
           f"Diff vs {base}: {shortstat}.",
           "",
           "### Lines of code by area (+added / -removed)",
           ""]
    for area in AREA_PREFIXES:
        out.append(f"- {area}: +{area_add[area]} / -{area_del[area]}")
    if other_add or other_del:
        out.append(f"- Other: +{other_add} / -{other_del}")
    out += ["", "### Every change (grouped, newest last)", ""]
    for name, _ in CATEGORIES + [("General Improvements", [])]:
        items = groups.get(name)
        if not items:
            continue
        out.append(f"#### {name}")
        for sha, subject in reversed(items):
            out.append(f"- `{sha}` {subject}")
        out.append("")
    sys.stdout.write("\n".join(out).rstrip() + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
