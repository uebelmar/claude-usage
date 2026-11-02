#!/bin/zsh
# Baut ein mit Developer ID signiertes Release-ZIP: build/release/ClaudeUsage.zip
set -euo pipefail
cd "${0:A:h}/.."

xcodegen generate --quiet
rm -rf build/release
xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/dd-release -quiet \
  CODE_SIGN_IDENTITY="Developer ID Application" ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build

APP="build/dd-release/Build/Products/Release/ClaudeUsage.app"
codesign --verify --deep --strict "$APP"
mkdir -p build/release
ditto -c -k --keepParent "$APP" build/release/ClaudeUsage.zip
shasum -a 256 build/release/ClaudeUsage.zip
