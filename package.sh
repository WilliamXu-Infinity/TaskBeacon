#!/bin/bash
# Package TaskBeacon into a distributable a friend can install in one double-click.
#
# Unlike a bare app .dmg, this bundles everything the app actually needs to work
# on someone else's machine: the universal app, the status hook, the companion
# VSCode extension, and an install.command that wires it all into ~/.claude.
# No Apple Developer account / notarization — the installer strips the quarantine
# attribute itself so Gatekeeper won't block the app after install.
set -euo pipefail
cd "$(dirname "$0")"

APP="TaskBeacon.app"
NAME="TaskBeacon"
VERSION="1.0"
DMG="$NAME-$VERSION-installer.dmg"

# 1. Build the universal app bundle (reuses build.sh).
UNIVERSAL=1 ./build.sh
echo "   archs: $(lipo -archs "$APP/Contents/MacOS/$NAME")"

# 1b. Keep the bundled hook in sync with the one in this repo's hooks/ dir.
if [ ! -f hooks/taskbeacon-status.sh ]; then
  echo "✖ hooks/taskbeacon-status.sh missing — can't package a working installer."
  exit 1
fi

# 2. Stage the full payload the installer needs.
STAGE="$(mktemp -d)"
PKG="$STAGE/$NAME"
mkdir -p "$PKG"
cp -R "$APP"            "$PKG/"
cp -R hooks            "$PKG/"
cp -R vscode-extension "$PKG/"
cp installer/install.command   "$PKG/"
cp installer/uninstall.command "$PKG/"
cp installer/先看我.txt         "$PKG/"
chmod +x "$PKG/install.command" "$PKG/uninstall.command"
# Drop the extension's own dev-install script + any junk from the payload copy.
rm -f "$PKG/vscode-extension/install.sh"

# 3. Build the .dmg (preferred). Falls back to a .zip if hdiutil can't mount
#    images (e.g. inside a restricted sandbox).
rm -f "$DMG"
if hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null 2>&1; then
  rm -rf "$STAGE"
  echo "✅ Packaged $DMG  ($(du -h "$DMG" | cut -f1))"
  echo "   把这个 .dmg 发给朋友：打开 → 双击 install.command 即可。"
else
  ZIP="$NAME-$VERSION-installer.zip"
  rm -f "$ZIP"
  ( cd "$STAGE" && ditto -c -k --keepParent "$NAME" "$OLDPWD/$ZIP" )
  rm -rf "$STAGE"
  echo "⚠️  hdiutil 不可用，已改为生成 zip。"
  echo "✅ Packaged $ZIP  ($(du -h "$ZIP" | cut -f1))"
  echo "   把这个 .zip 发给朋友：解压 → 双击 install.command 即可。"
fi
