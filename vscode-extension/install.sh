#!/bin/bash
# Install the TaskBeacon Focus extension into VSCode (dev install — no Marketplace).
# Copies this folder to ~/.vscode/extensions/taskbeacon.focus-<version>,
# then you reload VSCode once so the UriHandler registers.
set -euo pipefail
cd "$(dirname "$0")"

DEST_BASE="$HOME/.vscode/extensions"
ID="taskbeacon.focus"
VERSION="$(/usr/bin/sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' package.json | head -1)"
DEST="$DEST_BASE/$ID-$VERSION"

mkdir -p "$DEST_BASE"
rm -rf "$DEST_BASE/$ID-"*           # drop any older version
mkdir -p "$DEST"
cp package.json extension.js "$DEST/"

echo "✅ Installed $ID-$VERSION → $DEST"
echo "   Now reload VSCode: Command Palette → 'Developer: Reload Window' (or quit & reopen)."
