#!/bin/zsh
# Baut, notarisiert (über den in Xcode angemeldeten Account) und packt ein Release:
#   build/release/ClaudeUsage.zip
# Voraussetzung: Xcode › Settings › Accounts mit Zugriff auf das Team aus project.yml.
set -euo pipefail
cd "${0:A:h}/.."

TEAM=$(awk '/DEVELOPMENT_TEAM:/{print $2; exit}' project.yml)
ARCHIVE=build/ClaudeUsage.xcarchive

xcodegen generate --quiet
rm -rf "$ARCHIVE" build/notarize-upload build/notarized build/release
xcodebuild archive -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" -quiet \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO

cat > build/ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM</string>
</dict></plist>
EOF

echo "→ Upload zur Notarisierung …"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist build/ExportOptions.plist \
  -exportPath build/notarize-upload -allowProvisioningUpdates -quiet

echo "→ Warte auf Notarisierung …"
for i in {1..60}; do
  if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath build/notarized >/dev/null 2>&1; then
    break
  fi
  (( i == 60 )) && { echo "Notarisierung nicht fertig geworden"; exit 1; }
  sleep 30
done

APP=build/notarized/ClaudeUsage.app
xcrun stapler validate "$APP"
spctl -a -vv "$APP"
mkdir -p build/release
ditto -c -k --keepParent "$APP" build/release/ClaudeUsage.zip
shasum -a 256 build/release/ClaudeUsage.zip
