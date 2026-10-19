#!/usr/bin/env python3
"""Deep secret scanner for git history and the working tree.

Part of Grablytic's skills/secret-scan/ pack.
"""

import argparse
import os
import re
import subprocess
import sys

PATTERNS = [
    ("AWS Access Key ID", re.compile(r"\b(AKIA|ASIA)[0-9A-Z]{16}\b")),
    (
        "AWS Secret Access Key",
        re.compile(r"(?i)aws_secret_access_key\s*=\s*[A-Za-z0-9/+=]{40}"),
    ),
    (
        "GitHub Personal Access Token",
        re.compile(r"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{36,}\b"),
    ),
    ("GitHub Fine-Grained PAT", re.compile(r"\bgithub_pat_[A-Za-z0-9_]{82}\b")),
    ("Slack API / Bot Token", re.compile(r"\bxox[baprs]-[0-9A-Za-z]{10,48}\b")),
    ("Google API Key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b")),
    ("OpenAI API Key", re.compile(r"\bsk-[A-Za-z0-9_-]{32,}\b")),
    ("Stripe API Secret", re.compile(r"\b(sk|rk)_(live|test)_[0-9a-zA-Z]{24,}\b")),
    (
        "Private Key Block Header",
        re.compile(r"-----BEGIN ((RSA|EC|DSA|OPENSSH) )?PRIVATE KEY-----"),
    ),
    (
        "Generic High-Entropy Secret",
        re.compile(
            r'(?i)(password|secret|api_key|access_token|auth_token)\s*[:=]\s*["\x27]([A-Za-z0-9!@#$%^&*()_+=\-]{14,})["\x27]'
        ),
    ),
]

# Allowlist for known benign test fixtures, synthetic mock data, or documentation examples
BENIGN_ALLOWLIST = [
    "http://user:pass@h:8080",
    "http://user:pass@proxy:8080",
    "AKIAIOSFODNN7EXAMPLE",
    "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    "STRIPE_MOCK_SECRET",
    "SLACK_MOCK_SECRET",
    "PROTONMAIL_MOCK_SECRET",
    "your-api-key",
    "your-real-api-key",
    "your-telegram-api-key",
    "adminpass123",
    "mysecretpassword",
]

BENIGN_CODE_PATTERNS = [
    "type: 'password'",
    'type="password"',
    "obscuretext: true",
    "hinttext",
    "labeltext",
    "formfield",
]


def _is_benign(matched, line):
    """Return True when a match is a known fixture or UI code, not a secret."""
    if any(allow in matched for allow in BENIGN_ALLOWLIST):
        return True
    lowered = line.lower()
    return any(pattern in lowered for pattern in BENIGN_CODE_PATTERNS)


def _find_secrets(line):
    """Yield (name, matched text) for every non-benign pattern hit."""
    for name, pattern in PATTERNS:
        for match in pattern.finditer(line):
            text = match.group(0)
            if not _is_benign(text, line):
                yield name, text


def _iter_added_lines(repo_path, max_commits=None):
    """Yield (commit, author, date, file, line) for added lines in git log."""
    cmd = ["git", "-C", repo_path, "log", "--all", "-p", "--unified=0"]
    if max_commits:
        cmd.extend(["-n", str(max_commits)])

    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        errors="replace",
    )

    commit = "UNKNOWN"
    author = ""
    date = ""
    file = ""
    for raw in proc.stdout:
        if raw.startswith("commit "):
            commit = raw.strip().split()[1]
        elif raw.startswith("Author: "):
            author = raw.strip()
        elif raw.startswith("Date: "):
            date = raw.strip()
        elif raw.startswith("+++ b/"):
            file = raw.strip()[6:]
        elif raw.startswith("+") and not raw.startswith("+++"):
            yield commit, author, date, file, raw[1:].strip()

    stderr = proc.stderr.read()
    if proc.wait() != 0:
        print(f"[-] git log failed in {repo_path}: {stderr.strip()}")


def scan_repo(repo_path, max_commits=None):
    """Scan added lines in every commit reachable from the repo's refs."""
    repo_path = os.path.abspath(repo_path)
    if not os.path.exists(os.path.join(repo_path, ".git")):
        print(f"[-] Skipped {repo_path} (not a git repository)")
        return []

    print("\n==========================================")
    print(f"Deep scanning Git commit history: {repo_path}")
    print("==========================================")

    findings = []
    for commit, author, date, file, content in _iter_added_lines(
        repo_path, max_commits
    ):
        for name, matched in _find_secrets(content):
            finding = {
                "type": name,
                "commit": commit,
                "author": author,
                "date": date,
                "file": file,
                "match": matched[:25] + ("..." if len(matched) > 25 else ""),
                "snippet": content[:90],
            }
            findings.append(finding)
            print(f"[!] Finding: {name}")
            print(f"    Commit:  {commit[:10]} ({author}, {date})")
            print(f"    File:    {file}")
            print(f"    Snippet: {content[:80]}")
            print("------------------------------------------")

    if not findings:
        print(
            f"[✓] Zero secrets detected in git history for {os.path.basename(repo_path)}"
        )
    else:
        print(
            f"[!] Total potential findings in {os.path.basename(repo_path)}: {len(findings)}"
        )

    return findings


def scan_working_tree(repo_path):
    """Scan files that are staged, modified, or untracked."""
    repo_path = os.path.abspath(repo_path)
    print(f"\nScanning uncommitted/working tree files in {repo_path}...")
    findings = []
    cmd = ["git", "-C", repo_path, "status", "--porcelain"]
    res = subprocess.run(cmd, capture_output=True, text=True, check=False)
    for line in res.stdout.splitlines():
        if len(line) < 3:
            continue
        filepath = os.path.join(repo_path, line[3:].strip())
        if not os.path.isfile(filepath):
            continue
        try:
            with open(filepath, "r", errors="ignore") as handle:
                for number, text in enumerate(handle, 1):
                    for name, _ in _find_secrets(text):
                        findings.append(
                            {
                                "type": name,
                                "file": filepath,
                                "line": number,
                                "snippet": text.strip()[:80],
                            }
                        )
                        print(f"[!] Uncommitted finding: {name} in {filepath}:{number}")
        except OSError as exc:
            print(f"[-] Skipped {filepath}: {exc}")
    if not findings:
        print("[✓] Zero uncommitted secrets detected in working tree.")
    return findings


def main():
    """Scan every path given on the command line and exit non-zero on findings."""
    parser = argparse.ArgumentParser(
        description="Deep secret scanner across git commits and working trees"
    )
    parser.add_argument(
        "paths", nargs="*", default=["."], help="Repositories or paths to scan"
    )
    parser.add_argument(
        "--max-commits", type=int, default=None, help="Limit commit depth"
    )
    parser.add_argument(
        "--skip-working-tree", action="store_true", help="Do not scan uncommitted files"
    )
    args = parser.parse_args()

    all_findings = {}
    for path in args.paths:
        commit_findings = scan_repo(path, max_commits=args.max_commits)
        tree_findings = [] if args.skip_working_tree else scan_working_tree(path)
        all_findings[path] = commit_findings + tree_findings

    total = sum(len(items) for items in all_findings.values())
    print(
        f"\n>>> SCAN FINISHED: {total} total actionable finding(s) across {len(args.paths)} target(s)."
    )
    sys.exit(1 if total else 0)


if __name__ == "__main__":
    main()
