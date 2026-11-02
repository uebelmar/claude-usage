#!/bin/zsh
# Baut Claude Usage, installiert nach ~/Applications und startet die App neu.
set -euo pipefail
cd "${0:A:h}/.."

xcodegen generate --quiet
xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/dd -quiet build

APP="build/dd/Build/Products/Release/ClaudeUsage.app"
DEST="$HOME/Applications/ClaudeUsage.app"

pkill -x ClaudeUsage 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
open "$DEST"
echo "Installiert: $DEST"
