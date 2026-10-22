#!/usr/bin/env python3
"""Index high-signal sink lines in a repository for a human or agent to triage.

This is a *finding index*, not a scanner. It prints file:line and a snippet for
constructs worth reading; it does not decide whether any of them is reachable,
and every line it emits still needs a data-flow read.

Usage:
    python3 surface_scan.py <path> [--max-per-cat N] [--no-color]

Exit code is 0 even when matches exist. Non-zero only for bad usage.
"""

from __future__ import annotations

import argparse
import os
import re
import sys

# (category, compiled regex). Keep these narrow: a pattern that matches every
# line trains the reader to ignore the output.
RULES = [
    (
        "cmd-exec",
        re.compile(
            r"shell\s*=\s*True|\bRuntime\.getRuntime\(\)\.exec|\bexec\(\s*[a-zA-Z_]|child_process\.(?:exec|execSync)|\bsubprocess\.(?:run|call|Popen)\([^)]*shell\s*=\s*True|os\.system\("
        ),
    ),
    (
        "code-eval",
        re.compile(
            r"\beval\(|new\s+Function\(|\bexec\(|(?<![\w.])compile\(\s*[a-zA-Z_]"
        ),
    ),
    (
        "deserialize",
        re.compile(
            r"pickle\.loads?|yaml\.load\(|marshal\.loads?|ObjectInputStream|readObject\(|JsonSerializerSettings.*TypeNameHandling|unserialize\("
        ),
    ),
    (
        "sql-build",
        re.compile(
            r"\b(?:SELECT|INSERT|UPDATE|DELETE)\b[^\n]{0,80}(?:\+|%s|\{\}|\.format|f\"|f')|execute\(\s*f\"|createQuery\(\s*\w+\s*\+"
        ),
    ),
    (
        "path-join",
        re.compile(
            r"os\.path\.join\(|Path\([^)]*\)\s*/\s*[a-zA-Z_]|filepath\.Join\(|Files\.(?:write|read|newInputStream)\(|\bFile\([^)]*,\s*[a-zA-Z_]"
        ),
    ),
    (
        "http-client",
        re.compile(
            r"\brequests\.(?:get|post)\(|urllib\.request|HttpURLConnection|HttpClient\.new|okhttp|Dio\(|http\.get\(|fetch\(|axios\."
        ),
    ),
    (
        "tls-off",
        re.compile(
            r"verify\s*=\s*False|CERT_NONE|TrustAllCerts|X509TrustManager|hostnameVerifier|badCertificateCallback\s*=>\s*\(?[^)]*\)?\s*=>\s*true|checkServerTrusted\([^)]*\)\s*\{\s*\}"
        ),
    ),
    (
        "random",
        re.compile(
            r"\brandom\.(?:random|randint|choice|shuffle)\(|Math\.random\(|new Random\(|java\.util\.Random|Random\(\)"
        ),
    ),
    (
        "secret-literal",
        re.compile(
            r"(?:api[_-]?key|secret|token|password|passwd|private[_-]?key)\s*[:=]\s*[\"'][^\"']{12,}[\"']"
        ),
    ),
    (
        "xml-parse",
        re.compile(
            r"FEATURE_PROCESS_DOCDECL|resolve_entities|XMLParser\(|parseString\(|DocumentBuilderFactory\.newInstance"
        ),
    ),
    (
        "archive",
        re.compile(
            r"ZipFile|TarFile|zipfile|tarfile|ZipInputStream|extractall\(|unzip"
        ),
    ),
    (
        "ipc-boundary",
        re.compile(
            r"MethodChannel|EventChannel|BroadcastReceiver|PendingIntent|getUriForFile|\bexported\s*=\s*\"true\""
        ),
    ),
]

SKIP_DIRS = {
    ".git",
    ".hg",
    ".svn",
    "node_modules",
    "vendor",
    "dist",
    "build",
    "out",
    "target",
    "__pycache__",
    ".venv",
    "venv",
    ".mypy_cache",
    ".pytest_cache",
    ".gradle",
    "Pods",
    ".dart_tool",
    "coverage",
    ".next",
    ".nuxt",
}
SKIP_EXT = {
    ".png",
    ".jpg",
    ".jpeg",
    ".gif",
    ".webp",
    ".ico",
    ".pdf",
    ".zip",
    ".gz",
    ".jar",
    ".apk",
    ".so",
    ".dylib",
    ".dll",
    ".exe",
    ".woff",
    ".woff2",
    ".ttf",
    ".mp3",
    ".mp4",
    ".webm",
    ".lock",
}
MAX_BYTES = 2_000_000


def iter_files(root: str):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(
            d for d in dirnames if d not in SKIP_DIRS and not d.startswith(".")
        )
        for name in sorted(filenames):
            if os.path.splitext(name)[1].lower() in SKIP_EXT:
                continue
            path = os.path.join(dirpath, name)
            try:
                if os.path.getsize(path) > MAX_BYTES or os.path.islink(path):
                    continue
            except OSError:
                continue
            yield path


def scan(root: str, max_per_cat: int):
    results: dict[str, list[tuple[str, int, str]]] = {cat: [] for cat, _ in RULES}
    scanned = 0
    for path in iter_files(root):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                lines = fh.readlines()
        except OSError:
            continue
        scanned += 1
        rel = os.path.relpath(path, root)
        for lineno, line in enumerate(lines, 1):
            if len(line) > 400:
                line = line[:400] + "…"
            for cat, rx in RULES:
                if rx.search(line):
                    bucket = results[cat]
                    if len(bucket) < max_per_cat:
                        bucket.append((rel, lineno, line.strip()))
    return results, scanned


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("root")
    ap.add_argument("--max-per-cat", type=int, default=40)
    ap.add_argument("--no-color", action="store_true")
    args = ap.parse_args(argv)

    if not os.path.isdir(args.root):
        print(f"not a directory: {args.root}", file=sys.stderr)
        return 2

    results, scanned = scan(args.root, args.max_per_cat)
    color = sys.stdout.isatty() and not args.no_color
    bold = "\033[1m" if color else ""
    dim = "\033[2m" if color else ""
    off = "\033[0m" if color else ""

    total = 0
    for cat, hits in results.items():
        if not hits:
            continue
        total += len(hits)
        print(
            f"\n{bold}{cat}{off}  ({len(hits)}{'+' if len(hits) == args.max_per_cat else ''})"
        )
        for rel, lineno, snippet in hits:
            print(f"  {rel}:{lineno}")
            print(f"    {dim}{snippet}{off}")

    print(f"\n{bold}{total}{off} candidate lines across {scanned} files.")
    print(
        "Each line is a question, not a finding: is attacker-controlled data reaching this sink?"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
