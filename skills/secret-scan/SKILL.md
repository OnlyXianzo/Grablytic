---
name: secret-scan
description: >-
  Audits repositories and commit history for exposed secrets, tokens, private keys,
  and hardcoded credentials. Use when checking for leaked credentials, reviewing
  recent commits or PRs for sensitive data, inspecting GitHub secret scanning alerts,
  or running TruffleHog, git-secrets, and detect-secrets.
---

# Secret & Credential Scanning Protocol

A deterministic, multi-layered defensive auditing skill to detect, verify, and remediate credentials, tokens, private keys, and sensitive data across local Git trees and remote GitHub repositories.

---

## Architecture & Tooling Stack

| Layer | Primary Tool | Target / Scope |
| :--- | :--- | :--- |
| **Remote Alerts** | `gh api /repos/{owner}/{repo}/secret-scanning/alerts` | GitHub Secret Scanning cloud alerts (public repos free; private requires GHAS) |
| **Working Tree & Staging** | `detect-secrets scan` & `git secrets --scan` | Untracked, staged, or modified files before commit |
| **Commit History** | `trufflehog --regex` & `scripts/deep_git_scan.py` | Full commit history across all branches and tags |
| **Remediation** | `git-filter-repo` & GitHub token rotation | Purging committed secrets and revoking compromised keys |

> [!IMPORTANT]
> **Termux / Android Architecture Note**: Precompiled Go binaries compiled with Go 1.24+ (e.g. TruffleHog v3 Go binaries) fail with `SIGSYS: bad system call` due to Android Bionic seccomp blocking syscall 439 (`faccessat2`). Always use Python-based TruffleHog (`pip install trufflehog`), `detect-secrets`, or the bundled `scripts/deep_git_scan.py`.

---

## Step 1: Remote GitHub Secret Scanning Audit (`gh`)

Query GitHub's native secret scanning service for all repositories owned by the user or organization:

```bash
# Check secret scanning alerts for a specific repo
gh api /repos/{owner}/{repo}/secret-scanning/alerts

# Check all repos under an account (run via python helper)
python3 -c '
import json, subprocess
res = subprocess.run(["gh", "repo", "list", "--limit", "100", "--json", "nameWithOwner,isPrivate"], capture_output=True, text=True)
repos = json.loads(res.stdout)
for r in repos:
    name = r["nameWithOwner"]
    out = subprocess.run(["gh", "api", f"/repos/{name}/secret-scanning/alerts"], capture_output=True, text=True)
    if out.returncode == 0:
        alerts = json.loads(out.stdout)
        print(f"[{name}] Alerts: {len(alerts)}")
    else:
        print(f"[{name}] Secret scanning not active (private repo or permissions restricted)")
'
```

- **Public Repos**: Secret scanning is enabled by default at zero cost.
- **Private Repos**: Returns HTTP 422 unless GitHub Advanced Security (GHAS) is enabled. If private, rely strictly on local deep scans (Steps 2 and 3).

---

## Step 2: Working Tree Pre-Flight (`detect-secrets` & `git-secrets`)

Before pushing or after code generation, scan untracked, modified, and staged files:

### A. AWS Labs `git-secrets`
Configure high-priority patterns:
```bash
git secrets --register-aws
git secrets --add 'AKIA[0-9A-Z]{16}'
git secrets --add 'gh[pousr]_[A-Za-z0-9_]{36,}'
git secrets --add 'BEGIN[A-Za-z_-]*PRIVATE'
git secrets --scan
```

### B. Yelp `detect-secrets`
```bash
detect-secrets scan --all-files > "${TMPDIR:-/tmp}/detect_secrets.json"
python3 -c '
import json, os
path = os.path.join(os.environ.get("TMPDIR", "/tmp"), "detect_secrets.json")
data = json.load(open(path))
results = data.get("results", {})
print(f"Files with findings: {len(results)}")
for path, items in results.items():
    kinds = [item["type"] for item in items]
    print(f"  {path}: {kinds}")
'
```

---

## Step 3: Deep Git Commit History Scan

Audit all commit hunks and refs across branches.

### Option A: Bundled Python Scanner (`scripts/deep_git_scan.py`)
Run the optimized, zero-dependency Git history scanner located in this skill:
```bash
python3 skills/secret-scan/scripts/deep_git_scan.py <repo_path>
```
Scans every unified diff across `--all` refs for:
- AWS Access & Secret Keys
- GitHub Classic and Fine-Grained PATs
- Slack, Google, OpenAI, Stripe, and Telegram API keys
- Private key blocks (`BEGIN RSA/OPENSSH/EC PRIVATE KEY`)
- High-entropy auth/secret assignments

### Option B: TruffleHog (Regex Mode)
```bash
trufflehog --regex --entropy=False --json file://$(pwd) > "${TMPDIR:-/tmp}/trufflehog_results.json"
```

---

## Step 4: Dissect Findings — Real Leaks vs. Benign Hashes

Every finding must be dispositioned into one of three categories before any action is taken:

1. **Benign Hash Digest (Safe)**:
   - SHA-256 release tarball checksums (`0f39d9eeef...`).
   - Maven AAR / Gradle dependency digests.
   - PGP Public Key Blocks (`truestream.asc` / `BEGIN PGP PUBLIC KEY BLOCK`).
   - Action: No remediation needed. Add to scanner allowlist if repeatedly flagged.

2. **Synthetic Mock / Unit Test Fixture (Safe)**:
   - `http://user:pass@h:8080` (used in test fixtures validating credential redaction).
   - `STRIPE_MOCK_SECRET_...` or `api_key="your-api-key"`.
   - Action: Verify that the string does not belong to any real infrastructure.

3. **Active Leaked Credential (CRITICAL)**:
   - Genuine personal access tokens, keystores (`.jks`), `.p12` certificates, `.env` files with production DB passwords, or cloud provider API keys.
   - Action: Proceed immediately to **Step 5**.

---

## Step 5: Incident Remediation Protocol

When an active secret has been pushed to a remote repository:

### 1. Invalidate Immediately
**Never assume Git history rewriting eliminates exposure.**
- Revoke the token or key in the provider console (GitHub Settings -> Developer Settings -> Tokens, AWS IAM, Stripe Dashboard, etc.).
- Issue a new replacement secret and store it in GitHub Repo Secrets (`Settings -> Secrets and variables -> Actions`).

### 2. Purge from Git History with `git-filter-repo`
Do not use `git rm` (leaves the secret in previous commits). Use `git-filter-repo`:

```bash
# If a specific file containing secrets was committed:
git-filter-repo --invert-paths --path path/to/secret.env

# If a secret string is embedded across files:
echo "EXPOSED_SECRET_STRING==>REDACTED" > "${TMPDIR:-/tmp}/replace.txt"
git-filter-repo --replace-text "${TMPDIR:-/tmp}/replace.txt"
```

### 3. Force Push Rewritten Refs
```bash
git push origin --force --all
git push origin --force --tags
```

### 4. Alert Repository Collaborators
Notify repository members to discard existing clones and re-clone fresh copies to avoid accidentally pushing back rewritten historical commits.
