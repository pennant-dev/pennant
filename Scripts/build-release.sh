#!/bin/zsh
# Builds a release Pennant.app with the host embedded, signs it with a stable identity, and puts it in dist/.
# Usage: Scripts/build-release.sh [--identity "Apple Development: Name (TEAM)"] [--open]
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY=""
OPEN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity) IDENTITY="$2"; shift 2 ;;
    --open) OPEN=1; shift ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
done
if [[ -z "$IDENTITY" ]]; then
  # Prefer a real identity so TCC permissions survive rebuilds; fall back to ad-hoc.
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -oE '"(Developer ID Application|Apple Development)[^"]*"' | head -1 | tr -d '"')
  [[ -z "$IDENTITY" ]] && IDENTITY="-"
fi
echo "Signing identity: $IDENTITY"

DERIVED=".build-apps/DerivedData"
echo "== Building pennant-host (release)"
swift build -c release --product pennant-host 2>&1 | grep -E "error:|Compiling|Build complete" | tail -3

echo "== Generating project"
xcodegen generate > /dev/null

echo "== Building Pennant.app (Release)"
# A fresh bundle version per build so LaunchServices and the Dock drop their cached (possibly blank) icon.
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
xcodebuild -project Pennant.xcodeproj -scheme PennantMac -configuration Release -derivedDataPath "$DERIVED" build CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES \
  -skipPackagePluginValidation -skipMacroValidation 2>&1 | grep -E "error:|\*\* BUILD|Embedded pennant-host|Embedded Pennant Voice" | head -10

APP="$DERIVED/Build/Products/Release/Pennant.app"
[[ -d "$APP" ]] || { echo "build failed: $APP missing"; exit 1; }

echo "== Signing nested helpers and re-sealing the bundle"
HELPER="$APP/Contents/Helpers/Pennant Host.app"
[[ -d "$HELPER" ]] || { echo "helper bundle missing: $HELPER"; exit 1; }
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none --entitlements Sources/PennantHost/PennantHost.entitlements "$HELPER" 2>&1 | grep -v "replacing existing signature" || true
VOICE="$APP/Contents/Helpers/Pennant Voice.app"
[[ -d "$VOICE" ]] || { echo "voice helper missing: $VOICE"; exit 1; }
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$VOICE" 2>&1 | grep -v "replacing existing signature" || true
codesign --force --sign "$IDENTITY" --timestamp=none --entitlements Apps/PennantMac/PennantMac.entitlements "$APP" 2>&1 | grep -v "replacing existing signature" || true
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2

# Stop any running copy first: a live app respawns its host from the old files while they are being replaced.
pkill -KILL -f "dist/Pennant.app/Contents/MacOS/Pennant( |$)" 2>/dev/null || true
pkill -KILL -f "dist/Pennant.app/.*pennant-host$" 2>/dev/null || true
sleep 1
mkdir -p dist
rm -rf dist/Pennant.app
ditto "$APP" dist/Pennant.app
touch dist/Pennant.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f dist/Pennant.app >/dev/null 2>&1 || true
echo "== Done: $(pwd)/dist/Pennant.app"
codesign -dv dist/Pennant.app 2>&1 | grep -E "Identifier|TeamIdentifier" | head -2
codesign -dv "dist/Pennant.app/Contents/Helpers/Pennant Host.app" 2>&1 | grep -E "Identifier" | head -1
[[ $OPEN -eq 1 ]] && open dist/Pennant.app
exit 0
