#!/bin/zsh

set -euo pipefail

ROOT_DIR="${1:-$(pwd)}"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-debug}"
PRODUCT_NAME="JarvisNative"
APP_NAME="Jarvis.app"
BUILD_DIR="$ROOT_DIR/.build/$BUILD_CONFIGURATION"
EXECUTABLE_PATH="$BUILD_DIR/$PRODUCT_NAME"
APP_DIR="$ROOT_DIR/dist-native/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
RUNTIME_DIR="$RESOURCES_DIR/runtime"
INFO_PLIST="$CONTENTS_DIR/Info.plist"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.jarvis.local}"
APP_VERSION="${APP_VERSION:-$(node -p "JSON.parse(require('node:fs').readFileSync(process.argv[1], 'utf8')).version" "$ROOT_DIR/package.json")}"
APP_BUILD="${APP_BUILD:-$APP_VERSION}"
SIDECAR_DIST_DIR="$ROOT_DIR/dist-sidecar"
VOICE_DIST_DIR="$ROOT_DIR/dist-voice"
APP_ICON_SOURCE="$ROOT_DIR/assets/branding/jarvis-icon.png"
STATUS_BAR_ICON_SOURCE="$ROOT_DIR/assets/branding/jarvis-menubar.png"
APP_ICON_NAME="JarvisAppIcon.icns"
STATUS_BAR_ICON_NAME="JarvisStatusBarIcon.png"
# Prefer a pinned Node next to the repo (keeps better-sqlite3's ABI stable);
# fall back to whatever node is on PATH. Override with HOST_NODE_BIN.
PINNED_NODE_BIN="$ROOT_DIR/../tools/node-v22.22.2-darwin-arm64/bin/node"
HOST_NODE_BIN="${HOST_NODE_BIN:-$PINNED_NODE_BIN}"
if [[ ! -x "$HOST_NODE_BIN" ]]; then
  HOST_NODE_BIN="$(command -v node 2>/dev/null || true)"
fi

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  echo "Missing native executable at $EXECUTABLE_PATH. Run swift build first." >&2
  exit 1
fi

if [[ ! -f "$SIDECAR_DIST_DIR/sidecar.cjs" ]]; then
  echo "Missing sidecar bundle at $SIDECAR_DIST_DIR/sidecar.cjs. Run npm run build:sidecar first." >&2
  exit 1
fi

if [[ ! -f "$VOICE_DIST_DIR/voice-runtime.js" ]]; then
  echo "Missing voice runtime bundle at $VOICE_DIST_DIR/voice-runtime.js. Run npm run build:voice first." >&2
  exit 1
fi

if [[ -z "$HOST_NODE_BIN" || ! -x "$HOST_NODE_BIN" ]]; then
  echo "Unable to locate a usable node executable for packaging." >&2
  exit 1
fi

if [[ ! -f "$APP_ICON_SOURCE" ]]; then
  echo "Missing app icon source at $APP_ICON_SOURCE." >&2
  exit 1
fi

if [[ ! -f "$STATUS_BAR_ICON_SOURCE" ]]; then
  echo "Missing status bar icon source at $STATUS_BAR_ICON_SOURCE." >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR" "$RUNTIME_DIR"
cp "$EXECUTABLE_PATH" "$MACOS_DIR/$PRODUCT_NAME"
chmod +x "$MACOS_DIR/$PRODUCT_NAME"
cp -R "$SIDECAR_DIST_DIR" "$RUNTIME_DIR/"
cp -R "$VOICE_DIST_DIR" "$RUNTIME_DIR/"
cp "$STATUS_BAR_ICON_SOURCE" "$RESOURCES_DIR/$STATUS_BAR_ICON_NAME"
LOGO_SOURCE="$ROOT_DIR/Sources/JarvisNative/Resources/JarvisLogoTransparent.png"
if [[ -f "$LOGO_SOURCE" ]]; then
  cp "$LOGO_SOURCE" "$RESOURCES_DIR/JarvisLogoTransparent.png"
fi

zsh "$ROOT_DIR/scripts/generate-app-icon.sh" "$APP_ICON_SOURCE" "$RESOURCES_DIR/$APP_ICON_NAME"
zsh "$ROOT_DIR/scripts/embed-node-runtime.sh" "$HOST_NODE_BIN" "$MACOS_DIR/JarvisNode" "$FRAMEWORKS_DIR"

# Native modules must match the embedded Node ABI (npm installs may silently
# swap in prebuilds for whatever node is on PATH).
if ! "$APP_DIR/Contents/MacOS/JarvisNode" -e "require('better-sqlite3')" >/dev/null 2>&1; then
  echo "better-sqlite3 ABI mismatch with embedded Node - rebuilding..." >&2
  (cd "$ROOT_DIR" && PATH="$(dirname "$HOST_NODE_BIN"):$PATH" npm rebuild better-sqlite3 >/dev/null 2>&1) || true
  if ! "$APP_DIR/Contents/MacOS/JarvisNode" -e "require('better-sqlite3')" >/dev/null 2>&1; then
    echo "ERROR: better-sqlite3 still does not load under the embedded Node runtime." >&2
    exit 1
  fi
fi


cat > "$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>JarvisNative</string>
  <key>CFBundleIdentifier</key>
  <string>${APP_BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleIconFile</key>
  <string>${APP_ICON_NAME}</string>
  <key>CFBundleName</key>
  <string>Jarvis</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${APP_BUILD}</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Jarvis needs microphone access for realtime voice conversations.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Jarvis uses on-device speech recognition for the local voice provider.</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>Jarvis needs screen recording access to see your screen and help with desktop tasks.</string>
  <key>NSAccessibilityUsageDescription</key>
  <string>Jarvis needs accessibility access to control your mouse, keyboard, and interact with applications on your behalf.</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>Jarvis opens the files your agents produce in Documents and shows them to you.</string>
  <key>NSDesktopFolderUsageDescription</key>
  <string>Jarvis can open files saved on your Desktop when you ask for them.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>Jarvis can open files from Downloads when you ask for them.</string>
</dict>
</plist>
PLIST

xattr -dr com.apple.quarantine "$APP_DIR" 2>/dev/null || true

# Use a stable signing identity so TCC permissions persist across rebuilds.
# The default identity is a local self-signed certificate in the login
# keychain. It intentionally keeps the legacy "Samantha Dev Stable" name:
# macOS TCC permissions (Accessibility, Screen Recording, Documents) are tied
# to bundle id + signing identity, so switching to a differently-named
# certificate resets every permission grant. Override with SIGN_IDENTITY when
# building your own distribution. Falls back to ad-hoc if not installed.
# A self-signed identity signs fine even when find-identity does not list it
# as "valid" (that requires trust settings), so attempt the real identity
# first and only fall back to ad-hoc when codesign itself refuses.
SIGN_IDENTITY="${SIGN_IDENTITY:-Samantha Dev Stable}"
if codesign --force --deep --sign "$SIGN_IDENTITY" --timestamp=none "$APP_DIR" 2>/dev/null; then
  echo "Signed with '$SIGN_IDENTITY'." >&2
else
  echo "WARNING: '$SIGN_IDENTITY' certificate not found - falling back to ad-hoc signing." >&2
  echo "         TCC permissions will reset on every rebuild." >&2
  codesign --force --deep --sign - --timestamp=none "$APP_DIR"
fi

echo "$APP_DIR"
