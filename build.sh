#!/bin/bash
# Build TaskBeacon.app — a single-binary menu bar app, no Xcode needed.
set -euo pipefail
cd "$(dirname "$0")"

APP="TaskBeacon.app"
BIN_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"
NAME="TaskBeacon"

rm -rf "$APP"
mkdir -p "$BIN_DIR" "$RES_DIR"

# Default: single-arch build for the host (fast local iteration).
# UNIVERSAL=1 (used by package.sh): build a fat binary that runs on both
# Apple Silicon (arm64) and Intel (x86_64) Macs.
if [ "${UNIVERSAL:-0}" = "1" ]; then
  TMP="$(mktemp -d)"
  swiftc -O *.swift -o "$TMP/$NAME-arm64"  -framework Cocoa -target arm64-apple-macosx13.0
  swiftc -O *.swift -o "$TMP/$NAME-x86_64" -framework Cocoa -target x86_64-apple-macosx13.0
  lipo -create "$TMP/$NAME-arm64" "$TMP/$NAME-x86_64" -output "$BIN_DIR/$NAME"
  rm -rf "$TMP"
else
  swiftc -O *.swift -o "$BIN_DIR/$NAME" -framework Cocoa
fi

# App icon: regenerate the iconset from the Core Graphics script, pack to .icns.
swift tools/make-icon.swift >/dev/null
iconutil -c icns TaskBeacon.iconset -o "$RES_DIR/AppIcon.icns"
rm -rf TaskBeacon.iconset

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>TaskBeacon</string>
    <key>CFBundleDisplayName</key><string>TaskBeacon</string>
    <key>CFBundleIdentifier</key><string>com.tingchao.taskbeacon</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleExecutable</key><string>TaskBeacon</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
PLIST

# Sign with a stable self-signed identity so TCC permissions (Accessibility,
# etc.) survive rebuilds — ad-hoc signing changes the cdhash every compile,
# which makes macOS forget the grant and re-prompt. Run tools/setup-signing-cert.sh
# once to create the "TaskBeacon Dev" identity; fall back to ad-hoc if it's absent.
SIGN_ID="TaskBeacon Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  codesign --force -s "$SIGN_ID" "$APP" >/dev/null 2>&1 || true
else
  echo "⚠️  '$SIGN_ID' identity not found — using ad-hoc (TCC will re-prompt on every rebuild)."
  echo "    Run ./tools/setup-signing-cert.sh once to fix."
  codesign --force -s - "$APP" >/dev/null 2>&1 || true
fi

echo "✅ Built $APP"
echo "   Run:  open $(pwd)/$APP"
