#!/usr/bin/env bash
#
# Grablytic universal Linux installer — one command, zero decisions:
#   curl -fsSL https://raw.githubusercontent.com/OnlyXianzo/Grablytic/main/install.sh | bash
#
# Detects distro (apt/dnf/zypper/pacman) + arch (x64/arm64), fetches the matching
# asset from the latest GitHub release (or --version X.Y.Z), verifies SHA256
# against the release API digest, installs with the native package manager,
# and verifies the `grablytic` binary. Test hooks: OS_RELEASE_FILE, UNAME_M,
# DRY_RUN=1 (print actions without executing).
#
set -euo pipefail

REPO="OnlyXianzo/Grablytic"
VERSION="${VERSION:-latest}"   # or: VERSION=0.0.1 ... | bash
DRY_RUN="${DRY_RUN:-0}"
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
UNAME_M="${UNAME_M:-$(uname -m)}"

log()  { printf '[grablytic] %s\n' "$*"; }
run()  { if [ "$DRY_RUN" = "1" ]; then printf '[dry-run] %s\n' "$*"; else eval "$*"; fi; }
need() { command -v "$1" >/dev/null 2>&1 || { log "missing required tool: $1"; exit 1; }; }

usage() {
  cat <<'EOF'
Usage: install.sh [--version X.Y.Z] [--uninstall] [--dry-run] [--help]
  --version X.Y.Z  install a pinned release (default: latest GitHub release)
  --uninstall      remove grablytic with the native package manager
                   (pre-rename v0.0.1 used package name `truestream` —
                   remove that one manually if present)
  --dry-run        print every action without executing (also: DRY_RUN=1)
  --help           this text
One-liner: curl -fsSL https://raw.githubusercontent.com/OnlyXianzo/Grablytic/main/install.sh | bash
EOF
}

UNINSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --version)   VERSION="${2:?missing version}"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --help|-h)   usage; exit 0 ;;
    *) log "unknown flag: $1"; usage; exit 1 ;;
  esac
done

# --- distro + arch detection -------------------------------------------------
# shellcheck disable=SC1090
[ -r "$OS_RELEASE_FILE" ] && . "$OS_RELEASE_FILE"
ID_LIKE_LOWER="$(printf '%s %s' "${ID_LIKE:-}" "${ID:-}" | tr '[:upper:]' '[:lower:]')"

PM=""; PM_INSTALL=""; PM_REMOVE=""
if command -v apt-get >/dev/null 2>&1 && [[ "$ID_LIKE_LOWER" == *debian* || "$ID_LIKE_LOWER" == *ubuntu* ]]; then
  PM="apt"; PM_INSTALL="sudo apt-get install -y"; PM_REMOVE="sudo apt-get remove -y grablytic"
elif command -v dnf >/dev/null 2>&1; then
  PM="dnf"; PM_INSTALL="sudo dnf install -y"; PM_REMOVE="sudo dnf remove -y grablytic"
elif command -v zypper >/dev/null 2>&1; then
  PM="zypper"; PM_INSTALL="sudo zypper --non-interactive install"; PM_REMOVE="sudo zypper --non-interactive remove grablytic"
elif command -v pacman >/dev/null 2>&1; then
  PM="pacman"; PM_INSTALL="sudo pacman -U --noconfirm"; PM_REMOVE="sudo pacman -Rns --noconfirm grablytic"
else
  log "no supported package manager found (apt/dnf/zypper/pacman). Install manually from https://github.com/${REPO}/releases"
  exit 1
fi

case "$UNAME_M" in
  x86_64|amd64)   DEB_ARCH="amd64"; RPM_ARCH="x86_64"; PKG_ARCH="x86_64" ;;
  aarch64|arm64)  DEB_ARCH="arm64"; RPM_ARCH="aarch64"; PKG_ARCH="aarch64" ;;
  *) log "unsupported architecture: $UNAME_M (need x86_64 or aarch64)"; exit 1 ;;
esac
log "detected: pm=$PM arch=$UNAME_M"

# --- uninstall path -----------------------------------------------------------
if [ "$UNINSTALL" = "1" ]; then
  log "removing grablytic via $PM..."
  run "$PM_REMOVE"
  log "done."
  exit 0
fi

need curl
TMPDIR_WORK="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_WORK"' EXIT

# --- resolve version + asset URLs from the GitHub release API -----------------
need python3
API_URL="https://api.github.com/repos/${REPO}/releases"
[ "$VERSION" = "latest" ] && API_URL="${API_URL}/latest" || API_URL="${API_URL}/tags/v${VERSION}"
log "querying $API_URL ..."
RELEASE_JSON="$(curl -fsSL "$API_URL")"
TAG="$(printf '%s' "$RELEASE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"
VER="${TAG#v}"
log "release: $TAG"

pick_url() { # $1 = filename regex -> browser_download_url or ''
  printf '%s' "$RELEASE_JSON" | python3 -c "
import json, re, sys
assets = json.load(sys.stdin)['assets']
m = [a for a in assets if re.search(r'''$1''', a['name'])]
print(m[0]['browser_download_url'] if m else '')
"
}
pick_digest() { # $1 = exact filename -> 'sha256:...' or ''
  printf '%s' "$RELEASE_JSON" | python3 -c "
import json, sys
assets = json.load(sys.stdin)['assets']
m = [a for a in assets if a['name'] == '''$1''']
print(m[0].get('digest', '') if m else '')
"
}

# Post-rename transition: new releases publish `grablytic-*` assets; releases
# cut before the rename (e.g. v0.0.1) only have `truestream-*` assets.
# Prefer the new name, fall back to the legacy name so pinned old versions
# (e.g. --version 0.0.1) keep installing.
case "$PM" in
  apt)    FILES=("grablytic_${VER}_${DEB_ARCH}.deb" "truestream_${VER}_${DEB_ARCH}.deb") ;;
  dnf|zypper) FILES=("grablytic-${VER}-1.${RPM_ARCH}.rpm" "truestream-${VER}-1.${RPM_ARCH}.rpm") ;;
  pacman) FILES=("grablytic-${VER}-1-${PKG_ARCH}.pkg.tar.zst" "truestream-${VER}-1-${PKG_ARCH}.pkg.tar.zst") ;;
esac
URL=""; FILE=""
for candidate in "${FILES[@]}"; do
  URL="$(pick_url "^${candidate//./\\.}\$")"
  if [ -n "$URL" ]; then FILE="$candidate"; break; fi
done
[ -n "$URL" ] || { log "no $PM asset named ${FILES[0]} (or legacy ${FILES[1]}) in $TAG"; exit 1; }
log "asset: $FILE"

# --- download + verify + install ----------------------------------------------
cd "$TMPDIR_WORK"
run "curl -fsSL -o '$FILE' '$URL'"
DIGEST="$(pick_digest "$FILE")"
if [ -n "$DIGEST" ] && [ "$DRY_RUN" != "1" ]; then
  EXPECT="${DIGEST#sha256:}"; ACTUAL="$(sha256sum "$FILE" | awk '{print $1}')"
  [ "$EXPECT" = "$ACTUAL" ] || { log "SHA256 MISMATCH (expected $EXPECT, got $ACTUAL)"; exit 1; }
  log "SHA256 verified."
elif [ "$DRY_RUN" = "1" ]; then
  log "dry-run: skipping hash check + install"
else
  log "warning: no digest published for $FILE, installing unverified (TLS only)."
fi

if [ "$PM" = "apt" ]; then
  run "$PM_INSTALL './$FILE'"   # local path: apt resolves dependencies
else
  run "$PM_INSTALL './$FILE'"
fi

if [ "$DRY_RUN" = "1" ]; then log "dry-run complete."; exit 0; fi
command -v grablytic >/dev/null 2>&1 && log "installed: $(command -v grablytic)" || { log "install finished but 'grablytic' not on PATH"; exit 1; }
