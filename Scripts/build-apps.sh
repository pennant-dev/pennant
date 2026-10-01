#!/bin/sh
# Builds the Mac and iPhone apps without code signing (development).
# Build the host first so it gets embedded: swift build -c release --product pennant-host
set -e
cd "$(dirname "$0")/.."
DERIVED="${DERIVED_DATA:-.build-apps/DerivedData}"
[ -d Pennant.xcodeproj ] || xcodegen generate
xcodebuild -project Pennant.xcodeproj -scheme PennantMac -configuration Debug -derivedDataPath "$DERIVED" build \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO | grep -E "error|warning: |BUILD" || true
xcodebuild -project Pennant.xcodeproj -scheme PennantiOS -configuration Debug -derivedDataPath "$DERIVED" \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO | grep -E "error|warning: |BUILD" || true
echo "Mac app: $DERIVED/Build/Products/Debug/Pennant.app"
