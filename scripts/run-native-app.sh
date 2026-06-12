#!/bin/zsh

set -euo pipefail

ROOT_DIR="${1:-$(pwd)}"
APP_BUNDLE="$ROOT_DIR/dist-native/Jarvis.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/JarveyNative"

if [[ ! -x "$APP_BINARY" ]]; then
  echo "Missing native app binary at $APP_BINARY. Run npm run build:native first." >&2
  exit 1
fi

xattr -dr com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true
pgrep -f '[J]arveyNative|[J]arveyNode|[s]idecar\.cjs --port 4818' \
  | xargs -n 1 kill -9 2>/dev/null || true
exec open -n "$APP_BUNDLE" --args --project-root "$ROOT_DIR"
