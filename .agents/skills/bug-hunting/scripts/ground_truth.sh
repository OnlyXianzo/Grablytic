#!/bin/sh
# Print the ground truth for a bug investigation: ref, tree state, manifests,
# and the test commands detected for the project type.
#
# Usage: sh ground_truth.sh [repo-path]
#
# Read-only. Runs nothing from the project. Exit 0 even when nothing is detected.

set -u
repo=${1:-.}
cd "$repo" 2>/dev/null || { echo "not a directory: $repo"; exit 2; }

echo "=== repository ==="
if [ -d .git ]; then
  printf 'ref:      %s\n' "$(git rev-parse HEAD 2>/dev/null)"
  printf 'short:    %s\n' "$(git rev-parse --short HEAD 2>/dev/null)"
  printf 'branch:   %s\n' "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  printf 'subject:  %s\n' "$(git log -1 --format=%s 2>/dev/null)"
  printf 'remote:   %s\n' "$(git config --get remote.origin.url 2>/dev/null)"
  dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  printf 'dirty:    %s file(s)\n' "$dirty"
  [ "$dirty" != "0" ] && { echo "--- uncommitted ---"; git status --porcelain 2>/dev/null | head -20; }
else
  echo "not a git repository — findings cannot be pinned to a ref"
fi

echo
echo "=== toolchain ==="
for t in python3 python node npm pnpm yarn go cargo rustc java javac gradle flutter dart dotnet ruby php; do
  command -v "$t" >/dev/null 2>&1 && printf '%-8s %s\n' "$t" "$($t --version 2>&1 | head -1)"
done

echo
echo "=== manifests ==="
find . -maxdepth 3 \( -name 'package.json' -o -name 'pyproject.toml' -o -name 'setup.cfg' \
  -o -name 'requirements*.txt' -o -name 'go.mod' -o -name 'Cargo.toml' \
  -o -name 'build.gradle*' -o -name 'pom.xml' -o -name 'pubspec.yaml' \
  -o -name '*.csproj' -o -name 'Gemfile' -o -name 'composer.json' \) \
  -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null | sort | head -20

echo
echo "=== candidate test commands (detected, not run) ==="
# Depth-2 search so monorepos (engine/, backend/) are covered, not just the root.
has() { find . -maxdepth 2 -name "$1" -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null | grep -q .; }
has package.json      && grep -rqs '"test"' --include=package.json . 2>/dev/null && echo "npm test                     (package.json has a test script)"
has pyproject.toml || has pytest.ini || has conftest.py || find . -maxdepth 3 -type d -name tests -not -path '*/node_modules/*' 2>/dev/null | grep -q . && echo "python3 -m pytest -q         (pytest layout detected)"
has go.mod            && echo "go test ./...                (go.mod)"
has Cargo.toml        && echo "cargo test                   (Cargo.toml)"
has build.gradle || has build.gradle.kts && echo "./gradlew test               (gradle)"
has pom.xml           && echo "mvn -q test                  (pom.xml)"
has pubspec.yaml      && echo "flutter test                 (pubspec.yaml)"

cat <<'EOF'

Run the detected command before assuming the failure still exists.
A stale build and an already-fixed bug cost the same hour.
EOF
