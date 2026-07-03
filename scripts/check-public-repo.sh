#!/bin/zsh

set -euo pipefail

ROOT_DIR="${1:-$(pwd)}"
issues=0

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "Missing required public-release file: $path" >&2
    issues=1
  fi
}

report_blocker() {
  local message="$1"
  local details="${2:-}"
  echo "$message" >&2
  if [[ -n "$details" ]]; then
    echo "$details" >&2
  fi
  issues=1
}

require_file "$ROOT_DIR/.gitignore"
require_file "$ROOT_DIR/.env.example"
require_file "$ROOT_DIR/README.md"

# Uses grep (always available on macOS) instead of rg: an optional tool would
# turn this scan into a silent no-op on machines where it is not installed.
# NOTE: hyphens must sit at the END of bracket expressions — in POSIX ERE a
# mid-class `\-` parses as a character RANGE from `\`, silently dropping the
# literal hyphen from the class.
SECRET_PATTERN='(sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AIza[0-9A-Za-z_-]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|BEGIN RSA PRIVATE KEY|BEGIN OPENSSH PRIVATE KEY|BEGIN PRIVATE KEY|aws_access_key_id|aws_secret_access_key)'

secret_scan_status=0
secret_hits="$(
  cd "$ROOT_DIR" && grep -rEn \
    --exclude-dir=node_modules \
    --exclude-dir=.git \
    --exclude-dir='dist-*' \
    --exclude-dir=.build \
    --exclude='check-public-repo.sh' \
    --exclude='package-lock.json' \
    -e "$SECRET_PATTERN" \
    .
)" || secret_scan_status=$?

# grep exits 1 when nothing matches (good); anything above 1 means the scan
# itself failed and must block the release rather than pass silently.
if (( secret_scan_status > 1 )); then
  report_blocker "Secret scan failed to run (grep exit $secret_scan_status). Refusing to pass without scanning."
fi

if [[ -n "$secret_hits" ]]; then
  report_blocker "Potential secret-like content found in the repository tree:" "$secret_hits"
fi

env_hits="$(
  find "$ROOT_DIR" \
    -type f \
    \( -name '.env' -o -name '.env.*' \) \
    ! -name '.env.example' \
    ! -path '*/node_modules/*' \
    ! -path '*/.git/*' \
    | sort
)"

if [[ -n "$env_hits" ]]; then
  report_blocker "Local environment files are present and should not be published:" "$env_hits"
fi

artifact_hits="$(
  find "$ROOT_DIR" \
    -maxdepth 2 \
    \( -name '.DS_Store' -o -name '*.log' -o -name '*.sqlite*' -o -name '*.db' -o -name '*.local' -o -name '*.pem' -o -name '*.key' -o -name '*.p12' -o -name '*.mobileprovision' -o -name '*.cer' -o -name '*.crt' \) \
    ! -path '*/node_modules/*' \
    ! -path '*/.git/*' \
    ! -path "$ROOT_DIR/.build/*" \
    ! -path "$ROOT_DIR/dist/*" \
    ! -path "$ROOT_DIR/dist-native/*" \
    ! -path "$ROOT_DIR/dist-sidecar/*" \
    ! -path "$ROOT_DIR/dist-voice/*" \
    | sort
)"

if [[ -n "$artifact_hits" ]]; then
  report_blocker "Local-only artifacts or credentials were found near the repository root:" "$artifact_hits"
fi

if (( issues != 0 )); then
  exit 1
fi

echo "Public repository checks passed."
