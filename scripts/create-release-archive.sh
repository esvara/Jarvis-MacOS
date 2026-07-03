#!/bin/zsh

set -euo pipefail

ROOT_DIR="${1:-$(pwd)}"
APP_DIR="$ROOT_DIR/dist-native/Jarvis.app"
APP_VERSION="${APP_VERSION:-$(node -p "JSON.parse(require('node:fs').readFileSync(process.argv[1], 'utf8')).version" "$ROOT_DIR/package.json")}"
APP_ARCHITECTURE="${APP_ARCHITECTURE:-$(uname -m)}"
DMG_NAME="Jarvis-${APP_VERSION}-macos-${APP_ARCHITECTURE}.dmg"
DMG_PATH="$ROOT_DIR/dist-native/$DMG_NAME"

if [[ ! -d "$APP_DIR" ]]; then
  echo "Missing app bundle at $APP_DIR. Run npm run build:native first." >&2
  exit 1
fi

rm -f "$DMG_PATH"

SPEC_FILE="$(mktemp "${TMPDIR:-/tmp}/jarvis-dmg-spec.XXXXXX.json")"
cleanup() { rm -f "$SPEC_FILE"; }
trap cleanup EXIT

cat > "$SPEC_FILE" <<JSON
{
  "title": "Jarvis",
  "icon": "$APP_DIR/Contents/Resources/JarvisAppIcon.icns",
  "background": "$ROOT_DIR/assets/dmg-background.png",
  "background-color": "#0f0f12",
  "icon-size": 80,
  "window": {
    "position": { "x": 200, "y": 120 },
    "size": { "width": 660, "height": 400 }
  },
  "contents": [
    { "x": 170, "y": 170, "type": "file", "path": "$APP_DIR" },
    { "x": 490, "y": 170, "type": "link", "path": "/Applications" }
  ]
}
JSON

npx appdmg "$SPEC_FILE" "$DMG_PATH"

shasum -a 256 "$DMG_PATH" > "$DMG_PATH.sha256"

echo "$DMG_PATH"
