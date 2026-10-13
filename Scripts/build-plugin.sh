#!/bin/zsh
# Builds a plugin from Plugins/<Name> into dist/plugins/<Name>.plugin, signed.
#   Scripts/build-plugin.sh Azure [--identity "Developer ID Application: …"] [--debug]
# Install it with: pennant plugin install dist/plugins/<Name>.plugin
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="${1:?Usage: Scripts/build-plugin.sh <Name> [--identity ID] [--debug]}"; shift
IDENTITY=""
CONFIG=release
while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity) IDENTITY="$2"; shift 2 ;;
    --debug) CONFIG=debug; shift ;;
    *) echo "Unknown option $1"; exit 1 ;;
  esac
done
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -oE '"(Developer ID Application|Apple Development)[^"]*"' | head -1 | tr -d '"')
  [[ -z "$IDENTITY" ]] && IDENTITY="-"
fi

PRODUCT="pennant-${(L)NAME}-plugin"
MANIFEST="Plugins/$NAME/Resources/plugin.json"
[[ -f "$MANIFEST" ]] || { echo "No $MANIFEST"; exit 1; }
ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$MANIFEST")
VERSION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$MANIFEST")

swift build -c "$CONFIG" --product "$PRODUCT"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/$PRODUCT"
# Builds rewrite Package.resolved; keep the checked-in one.
git checkout -q Package.resolved 2>/dev/null || true

OUT="dist/plugins/$NAME.plugin"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/$NAME"
cp "$MANIFEST" "$OUT/Contents/Resources/plugin.json"
cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
</dict>
</plist>
PLIST
codesign --force --options runtime --timestamp=none --identifier "$ID" --sign "$IDENTITY" "$OUT/Contents/MacOS/$NAME"
codesign --force --timestamp=none --sign "$IDENTITY" "$OUT"
echo "Built $OUT ($ID $VERSION), signed by $IDENTITY"
