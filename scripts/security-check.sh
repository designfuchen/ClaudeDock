#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "==> Running ClaudeDock security & hygiene audit..."

# Scan only folders that exist, so a missing folder can't turn the scan into a silent no-op.
existing() { for d in "$@"; do [ -e "$d" ] && printf '%s\n' "$d"; done; }

# grep exits 1 for "no match" and 2 for an error; treat errors as failures, not as "clean".
scan() {
  local pattern="$1"; shift
  local targets; targets=$(existing "$@")
  [ -z "$targets" ] && return 1
  set +e
  # shellcheck disable=SC2086
  # -l: list file names only, so a found secret is never echoed into CI logs.
  grep -rlE --exclude="security-check.sh" "$pattern" $targets
  local rc=$?
  set -e
  if [ "$rc" -eq 2 ]; then echo "ERROR: security scan failed to read files" >&2; exit 2; fi
  return $rc
}

# 1. Fail if any secret-like API token exists in source/docs/packaging
if scan "(sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AIza[0-9A-Za-z_-]{30,}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN ([A-Z]+ )?PRIVATE KEY-----)" Sources Tests scripts plugins Packaging docs .github README.md README_ZH.md CHANGELOG.md CONTRIBUTING.md SECURITY.md; then
  echo "ERROR: Potential secret or private key detected!" >&2
  exit 1
fi

# 2. Ensure no personal home paths are hardcoded in source/scripts/plugins
if scan "/Users/[A-Za-z0-9._-]+" Sources scripts plugins Packaging .github README.md README_ZH.md; then
  echo "ERROR: Hardcoded user home directory found in source!" >&2
  exit 1
fi

# 3. Release builds must not ship template placeholders
if [ "${CLAUDEDOCK_RELEASE:-0}" = "1" ] && scan "YOUR_GITHUB_USER" README.md README_ZH.md Packaging; then
  echo "ERROR: Replace YOUR_GITHUB_USER before releasing!" >&2
  exit 1
fi

# 4. Check shell scripts syntax
for shfile in scripts/*.sh; do
  bash -n "$shfile"
done

echo "✅ Security & hygiene checks passed."
