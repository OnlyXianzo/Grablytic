#!/usr/bin/env python3
"""
Deep Git History & Working Tree Secret Scanner
Part of Grablytic's skills/secret-scan/ pack.
"""

import os
import re
import sys
import json
import argparse
import subprocess

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


def scan_repo(repo_path, max_commits=None):
    repo_path = os.path.abspath(repo_path)
    if not os.path.exists(os.path.join(repo_path, ".git")):
        print(f"[-] Skipped {repo_path} (not a git repository)")
        return []

    print("\n==========================================")
    print(f"Deep scanning Git commit history: {repo_path}")
    print("==========================================")

    cmd = ["git", "-C", repo_path, "log", "--all", "-p", "--unified=0"]
    if max_commits:
        cmd.extend(["-n", str(max_commits)])

    proc = subprocess.Popen(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, errors="replace"
    )

    current_commit = "UNKNOWN"
    current_author = ""
    current_date = ""
    current_file = ""
    findings = []

    for line in proc.stdout:
        if line.startswith("commit "):
            current_commit = line.strip().split()[1]
        elif line.startswith("Author: "):
            current_author = line.strip()
        elif line.startswith("Date: "):
            current_date = line.strip()
        elif line.startswith("+++ b/"):
            current_file = line.strip()[6:]
        elif line.startswith("+") and not line.startswith("+++"):
            content = line[1:].strip()
            for name, pattern in PATTERNS:
                matches = pattern.finditer(content)
                for m in matches:
                    matched_str = m.group(0)
                    if any(allow in matched_str for allow in BENIGN_ALLOWLIST):
                        continue
                    if any(p in content.lower() for p in BENIGN_CODE_PATTERNS):
                        continue

                    finding = {
                        "type": name,
                        "commit": current_commit,
                        "author": current_author,
                        "date": current_date,
                        "file": current_file,
                        "match": matched_str[:25]
                        + ("..." if len(matched_str) > 25 else ""),
                        "snippet": content[:90],
                    }
                    findings.append(finding)
                    print(f"[!] Finding: {name}")
                    print(
                        f"    Commit:  {current_commit[:10]} ({current_author}, {current_date})"
                    )
                    print(f"    File:    {current_file}")
                    print(f"    Snippet: {content[:80]}")
                    print("------------------------------------------")

    proc.wait()
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
    repo_path = os.path.abspath(repo_path)
    print(f"\nScanning uncommitted/working tree files in {repo_path}...")
    findings = []
    # Untracked or staged files
    cmd = ["git", "-C", repo_path, "status", "--porcelain"]
    res = subprocess.run(cmd, capture_output=True, text=True)
    for line in res.stdout.splitlines():
        if len(line) < 3:
            continue
        filepath = os.path.join(repo_path, line[3:].strip())
        if os.path.isfile(filepath):
            try:
                with open(filepath, "r", errors="ignore") as f:
                    for i, fline in enumerate(f, 1):
                        for name, pattern in PATTERNS:
                            matches = pattern.finditer(fline)
                            for m in matches:
                                matched_str = m.group(0)
                                if any(
                                    allow in matched_str for allow in BENIGN_ALLOWLIST
                                ):
                                    continue
                                if any(
                                    p in fline.lower() for p in BENIGN_CODE_PATTERNS
                                ):
                                    continue
                                findings.append(
                                    {
                                        "type": name,
                                        "file": filepath,
                                        "line": i,
                                        "snippet": fline.strip()[:80],
                                    }
                                )
                                print(
                                    f"[!] Uncommitted finding: {name} in {filepath}:{i}"
                                )
            except Exception:
                pass
    if not findings:
        print("[✓] Zero uncommitted secrets detected in working tree.")
    return findings


def main():
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
        "--include-working-tree",
        action="store_true",
        default=True,
        help="Scan working tree",
    )
    args = parser.parse_args()

    all_findings = {}
    for p in args.paths:
        f_commits = scan_repo(p, max_commits=args.max_commits)
        f_tree = scan_working_tree(p) if args.include_working_tree else []
        all_findings[p] = f_commits + f_tree

    total = sum(len(v) for v in all_findings.values())
    print(
        f"\n>>> SCAN FINISHED: {total} total actionable finding(s) across {len(args.paths)} target(s)."
    )
    if total > 0:
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
