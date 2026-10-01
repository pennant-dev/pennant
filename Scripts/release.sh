#!/bin/zsh
# Builds Pennant for distribution: signed with Developer ID, hardened runtime, notarized by Apple, stapled, and packed
# into a DMG (plus a zip and a tarball) that installs on any Mac with macOS 15 or later, Apple silicon or Intel. Also
# writes the signed update feed and moves the site's download button to the new version. See docs/RELEASE.md.
#
# Two routes, picked automatically:
#   xcode  (default) Xcode's signed-in account signs with a cloud-managed Developer ID certificate and uploads to the
#          notary service. Needs nothing in the keychain; Xcode › Settings › Accounts must be signed in.
#   local  A "Developer ID Application" certificate in the keychain plus notarytool credentials stored as the profile
#          "pennant-notary". This route also signs and notarizes the disk image itself.
#
#   Scripts/release.sh                  # auto
#   PENNANT_RELEASE_MODE=local Scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*static let string = "\(.*\)"/\1/p' Sources/PennantCore/Version.swift)
MARKETING=$(awk '/^  PennantMac:/{m=1} m && /MARKETING_VERSION:/{print $2; exit}' project.yml)
BUILD=$(awk '/^  PennantMac:/{m=1} m && /CURRENT_PROJECT_VERSION:/{print $2; exit}' project.yml)
[[ "$VERSION" == "$MARKETING" ]] || { echo "✗ PennantVersion.string ($VERSION) and the Mac app's MARKETING_VERSION ($MARKETING) differ."; exit 1; }
TEAM="${PENNANT_TEAM:-$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Apps/Signing.local.xcconfig 2>/dev/null)}"
[[ -n "$TEAM" ]] || { echo "✗ No team: put DEVELOPMENT_TEAM = <team id> in Apps/Signing.local.xcconfig, or set PENNANT_TEAM."; exit 1; }
PROFILE="${PENNANT_NOTARY_PROFILE:-pennant-notary}"
FOUND=$( (security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"') || true)
IDENTITY="${PENNANT_SIGNING_IDENTITY:-$FOUND}"
MODE="${PENNANT_RELEASE_MODE:-}"
if [[ -z "$MODE" ]]; then
  if [[ -n "$IDENTITY" ]] && xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then MODE=local; else MODE=xcode; fi
fi
command -v xcodegen >/dev/null || { echo "✗ xcodegen is required: brew install xcodegen"; exit 1; }
if [[ -f dist/updates/appcast.xml ]] && grep -q "<sparkle:version>$BUILD</sparkle:version>" dist/updates/appcast.xml; then
  echo "✗ Build $BUILD is already in the update feed. Raise the Mac app's CURRENT_PROJECT_VERSION in project.yml: the updater only offers higher build numbers."; exit 1
fi
[[ -f "docs/release-notes/$VERSION.md" ]] || { echo "✗ Write docs/release-notes/$VERSION.md first: the release and the update feed carry it."; exit 1; }

WORK=.build-release
ARCHIVE=$WORK/Pennant.xcarchive
OUT=dist/Pennant-$VERSION
mkdir -p "$WORK" dist
# PENNANT_RELEASE_RESUME=1 picks up an app that was already notarized in a previous run (packaging or the feed failed afterwards).
RESUME=
if [[ -n "${PENNANT_RELEASE_RESUME:-}" && -d "$WORK/notarized/Pennant.app" ]]; then RESUME=1; fi
rm -f "$OUT.dmg" "$OUT.zip" "$OUT.tar.gz"
[[ -n "$RESUME" ]] || rm -rf "$ARCHIVE" "$WORK/notarized" "$WORK/export" "$WORK/upload"

if [[ -n "$RESUME" ]]; then
  echo "→ Resuming with the app notarized earlier"
  APP=$WORK/notarized/Pennant.app
else
echo "→ Tests"
TESTS=$(swift test --skip LiveInferenceTests 2>&1 || true)
FAILED=$(print -r -- "$TESTS" | grep -cE "with [1-9][0-9]* failures|error:" || true)
[[ "$FAILED" == 0 ]] || { print -r -- "$TESTS" | grep -E "failed|error:" | head -10; echo "✗ The tests failed"; exit 1; }
print -r -- "$TESTS" | grep -A1 -E "Test Suite '.*\.xctest' passed" | grep -E "Executed [0-9]+ tests" | awk '{n += $2} END {print "  " n " tests passed"}'

echo "→ Host, for Apple silicon and Intel"
swift build -c release --product pennant-host --arch arm64 --arch x86_64 >"$WORK/host.log" 2>&1 \
  || { grep -E "error:" "$WORK/host.log" | head -10; echo "✗ The host did not build ($WORK/host.log)"; exit 1; }
HOST_BINARY="$(swift build -c release --product pennant-host --arch arm64 --arch x86_64 --show-bin-path)/pennant-host"

echo "→ Archiving $VERSION ($BUILD), route: $MODE"
xcodegen generate >/dev/null
xcodebuild archive -project Pennant.xcodeproj -scheme PennantMac -configuration Release -archivePath "$ARCHIVE" \
  -derivedDataPath "$WORK" -skipPackagePluginValidation -skipMacroValidation -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" ENABLE_HARDENED_RUNTIME=YES PENNANT_HOST_BINARY="$HOST_BINARY" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" >"$WORK/archive.log" 2>&1 \
  || { grep -E "error:" "$WORK/archive.log" | grep -v SourcePackages | head -10; echo "✗ Archive failed ($WORK/archive.log)"; exit 1; }

options() {   # $1 = destination (export | upload), $2 = signing style
  cat > "$WORK/options-$1.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>$2</string>
  <key>teamID</key><string>$TEAM</string>
  <key>destination</key><string>$1</string>
</dict></plist>
PLIST
}

if [[ "$MODE" == "xcode" ]]; then
  echo "→ Signing with the cloud-managed Developer ID certificate and uploading to Apple's notary service"
  options upload automatic
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$WORK/upload" -exportOptionsPlist "$WORK/options-upload.plist" \
    -allowProvisioningUpdates >"$WORK/upload.log" 2>&1 \
    || { grep -vE "Progress" "$WORK/upload.log" | tail -8; echo "✗ Upload failed. Is Xcode signed in (Settings › Accounts) and the team in the paid program?"; exit 1; }
  echo "→ Waiting for Apple (usually a few minutes)"
  DONE=
  for attempt in $(seq 1 60); do
    if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$WORK/notarized" >"$WORK/notarized.log" 2>&1; then DONE=1; break; fi
    sleep 30
  done
  [[ -n "$DONE" ]] || { grep -vE "Progress" "$WORK/notarized.log" | tail -6; echo "✗ Apple has not approved the build after 30 minutes. Run again with PENNANT_RELEASE_RESUME unset later; the upload is kept."; exit 1; }
  APP=$WORK/notarized/Pennant.app
else
  [[ -n "$IDENTITY" ]] || { echo "✗ No 'Developer ID Application' certificate in the keychain. See docs/RELEASE.md."; exit 1; }
  echo "→ Signing with: $IDENTITY"
  options export manual
  /usr/libexec/PlistBuddy -c "Add :signingCertificate string Developer ID Application" "$WORK/options-export.plist"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$WORK/export" -exportOptionsPlist "$WORK/options-export.plist" >"$WORK/export.log" 2>&1 \
    || { grep -E "error" "$WORK/export.log" | head -8; echo "✗ Export failed ($WORK/export.log)"; exit 1; }
  APP=$WORK/export/Pennant.app
  echo "→ Notarizing (usually a few minutes)"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/notarize.zip"
  xcrun notarytool submit "$WORK/notarize.zip" --keychain-profile "$PROFILE" --wait >"$WORK/notary.log" 2>&1 || true
  grep -q "status: Accepted" "$WORK/notary.log" || { tail -8 "$WORK/notary.log"; echo "✗ Notarization was not accepted"; exit 1; }
  xcrun stapler staple "$APP" >/dev/null
fi

fi

echo "→ Checking the result"
HELPER="$APP/Contents/Helpers/Pennant Host.app"
[[ -x "$HELPER/Contents/MacOS/pennant-host" ]] || { echo "✗ The app has no Pennant Host inside"; exit 1; }
codesign --verify --deep --strict "$APP"
# Captured first: with pipefail, `codesign | grep -q` fails falsely when grep exits early and codesign gets SIGPIPE.
for BUNDLE in "$APP" "$HELPER"; do
  SIGNATURE=$(codesign -dvv "$BUNDLE" 2>&1)
  [[ "$SIGNATURE" == *"Authority=Developer ID Application"* ]] || { echo "✗ $(basename "$BUNDLE") is not signed with Developer ID"; exit 1; }
  [[ "$SIGNATURE" == *"(runtime)"* ]] || { echo "✗ $(basename "$BUNDLE") does not have the hardened runtime"; exit 1; }
done
ENTITLEMENTS=$(codesign -d --entitlements - --xml "$HELPER" 2>/dev/null)
[[ "$ENTITLEMENTS" == *"com.apple.security.automation.apple-events"* ]] || { echo "✗ Pennant Host lost its Apple events entitlement"; exit 1; }
[[ "$(lipo -archs "$HELPER/Contents/MacOS/pennant-host")" == *x86_64*arm64* || "$(lipo -archs "$HELPER/Contents/MacOS/pennant-host")" == *arm64*x86_64* ]] \
  || { echo "✗ Pennant Host is not built for both Apple silicon and Intel"; exit 1; }
for PLIST in "$APP/Contents/Info.plist" "$HELPER/Contents/Info.plist"; do
  BUILT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
  [[ "$BUILT" == "$BUILD" ]] || { echo "✗ $PLIST says build $BUILT, but project.yml says $BUILD."; exit 1; }
done
xcrun stapler validate "$APP" | tail -1
spctl --assess --type execute -v "$APP" 2>&1 | tail -2

echo "→ Packaging"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT.zip"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Pennant" -srcfolder "$STAGE" -ov -format UDZO "$OUT.dmg" >/dev/null 2>&1
rm -rf "$STAGE"
if [[ "$MODE" == "local" ]]; then
  codesign --sign "$IDENTITY" --timestamp "$OUT.dmg"
  xcrun notarytool submit "$OUT.dmg" --keychain-profile "$PROFILE" --wait >"$WORK/notary-dmg.log" 2>&1 || true
  grep -q "status: Accepted" "$WORK/notary-dmg.log" && xcrun stapler staple "$OUT.dmg" >/dev/null
fi
tar -czf "$OUT.tar.gz" -C "$(dirname "$APP")" "$(basename "$APP")"
(cd dist && shasum -a 256 "Pennant-$VERSION.dmg" "Pennant-$VERSION.zip" "Pennant-$VERSION.tar.gz" > SHA256SUMS.txt)

echo "→ Update feed"
SPARKLE_BIN=$(find "$WORK/SourcePackages/artifacts" -type d -path "*Sparkle/bin" | head -1)
[[ -x "$SPARKLE_BIN/generate_appcast" ]] || { echo "✗ Sparkle's tools were not found under $WORK/SourcePackages"; exit 1; }
mkdir -p dist/updates
cp "$OUT.zip" "dist/updates/Pennant-$VERSION.zip"
cp "docs/release-notes/$VERSION.md" "dist/updates/Pennant-$VERSION.md"
# The EdDSA key lives in the login keychain (account "pennant"). It passes to generate_appcast through a private
# temporary file, so neither tool has to ask the keychain for the other's item; the file is gone right after.
KEYDIR=$(mktemp -d); KEYFILE="$KEYDIR/pennant.key"   # generate_keys -x won't write over an existing file
"$SPARKLE_BIN/generate_keys" --account pennant -x "$KEYFILE" >/dev/null 2>&1 \
  || { rm -rf "$KEYDIR"; echo "✗ The 'pennant' update key is not in this keychain. See docs/RELEASE.md to restore it."; exit 1; }
"$SPARKLE_BIN/generate_appcast" --ed-key-file "$KEYFILE" --download-url-prefix "https://pennant.dev/download/" --link "https://pennant.dev" \
  --embed-release-notes --maximum-versions 5 --maximum-deltas 0 dist/updates || { rm -rf "$KEYDIR"; exit 1; }
rm -rf "$KEYDIR"
grep -q "sparkle:edSignature" dist/updates/appcast.xml || { echo "✗ The update feed is not signed."; exit 1; }
# Each archive is served from the GitHub release for its version, where every download is counted. The feed itself
# stays on pennant.dev; the signature is on the file, so where it is fetched from changes nothing for the updater.
perl -pi -e 's#https://pennant\.dev/download/Pennant-([0-9][0-9.]*)\.zip#https://github.com/pennant-dev/pennant/releases/download/v$1/Pennant-$1.zip#g' dist/updates/appcast.xml

echo "→ Site"
SUM=$(shasum -a 256 "$OUT.dmg" | cut -d' ' -f1)
perl -pi -e "s#https://github\.com/pennant-dev/pennant/releases/download/v[0-9.]+/Pennant-[0-9.]+\.dmg#https://github.com/pennant-dev/pennant/releases/download/v$VERSION/Pennant-$VERSION.dmg#g; s#Version [0-9.]+, a preview#Version $VERSION, a preview#g; s#SHA-256 <code>[0-9a-f]{64}</code>#SHA-256 <code>$SUM</code>#g" www/index.html

echo "✓ Pennant $VERSION (build $BUILD) is ready. Next, in this order:"
echo "   1. gh release create v$VERSION --repo pennant-dev/pennant --target main --title \"Pennant $VERSION\" --notes-file docs/release-notes/$VERSION.md --latest \\"
echo "        $OUT.dmg $OUT.zip $OUT.tar.gz dist/SHA256SUMS.txt"
echo "   2. commit www/ (the download button, version and checksum were updated) and push"
echo "   3. Scripts/deploy-site.sh   # the site, then the update feed, once the release's archive is reachable"
