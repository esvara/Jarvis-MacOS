#!/bin/zsh

set -euo pipefail

SOURCE_PNG="${1:?Missing source PNG path.}"
OUTPUT_ICNS="${2:?Missing output .icns path.}"
ICONSET_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/jarvey-iconset.XXXXXX")"
ICONSET_DIR="$ICONSET_ROOT/JarveyAppIcon.iconset"

cleanup() {
  rm -rf "$ICONSET_ROOT"
}

trap cleanup EXIT

mkdir -p "$ICONSET_DIR"
mkdir -p "$(dirname "$OUTPUT_ICNS")"

render_icon() {
  local size="$1"
  local filename="$2"
  sips -z "$size" "$size" "$SOURCE_PNG" --out "$ICONSET_DIR/$filename" >/dev/null
}

render_icon 16 "icon_16x16.png"
render_icon 32 "icon_16x16@2x.png"
render_icon 32 "icon_32x32.png"
render_icon 64 "icon_32x32@2x.png"
render_icon 128 "icon_128x128.png"
render_icon 256 "icon_128x128@2x.png"
render_icon 256 "icon_256x256.png"
render_icon 512 "icon_256x256@2x.png"
render_icon 512 "icon_512x512.png"
render_icon 1024 "icon_512x512@2x.png"

iconutil -c icns "$ICONSET_DIR" -o "$OUTPUT_ICNS"
