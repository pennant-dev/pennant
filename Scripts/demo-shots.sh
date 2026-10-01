#!/bin/zsh
# Re-makes the site's screenshots from the fictional demo host (pennant-host --seed-demo: Pennant and its jobs for the
# Harbor launch): the Mac app's main screens in light and dark, and the iPhone's Home tab and a card when a simulator
# is booted. Nothing here touches your own host or data: the demo host runs from a temporary folder on 127.0.0.1:7431,
# and the apps are debug builds pointed at it.
#
#   Scripts/demo-shots.sh [output folder]      default: www/assets/shots (AVIF, plus the PNGs in the work folder)
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"
WORK=${TMPDIR:-/tmp}/pennant-demo-shots
OUT=${1:-$ROOT/www/assets/shots}
PORT=7431
rm -rf "$WORK"
mkdir -p "$WORK" "$OUT"

if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port $PORT is taken (another demo host?): stop it first, or the apps would photograph that one." >&2
  exit 1
fi

echo "== Seeding the demo host"
swift build --product pennant-host >/dev/null
.build/debug/pennant-host --root "$WORK/data" --seed-demo
PENNANT_HOST_NAME="Studio Mac" .build/debug/pennant-host --root "$WORK/data" >"$WORK/host.log" 2>&1 &
HOST_PID=$!
trap 'kill $HOST_PID 2>/dev/null || true' EXIT
until lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; do sleep 0.5; done

# The iPhone first: the Mac run ends by approving the launch post (for the "approved" picture).
SIM=$(xcrun simctl list devices booted | grep -m1 -oE '\(([0-9A-F-]{36})\) \(Booted\)' | grep -oE '[0-9A-F-]{36}' || true)
if [[ -n "$SIM" ]]; then
  echo "== iPhone screens ($SIM)"
  xcodebuild -project Pennant.xcodeproj -scheme PennantiOS -configuration Debug -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$WORK/ios-dd" build >"$WORK/ios-build.log" 2>&1
  xcrun simctl install "$SIM" "$WORK/ios-dd/Build/Products/Debug-iphonesimulator/Pennant.app"
  mkdir -p "$WORK/phone"
  for look in light dark; do
    xcrun simctl ui "$SIM" appearance $look
    for screen in home "approval:Company post"; do
      xcrun simctl terminate "$SIM" dev.pennant.ios 2>/dev/null || true
      SIMCTL_CHILD_PENNANT_DEBUG_HOST=127.0.0.1:$PORT SIMCTL_CHILD_PENNANT_DEBUG_TOKEN_FILE="$WORK/data/client-token" \
        SIMCTL_CHILD_PENNANT_DEBUG_SCREEN=$screen xcrun simctl launch "$SIM" dev.pennant.ios >/dev/null
      sleep 7
      name=phone-${screen%%:*}; [[ $look == dark ]] && name=$name-dark
      xcrun simctl io "$SIM" screenshot "$WORK/phone/$name.png" >/dev/null 2>&1
    done
  done
  xcrun simctl ui "$SIM" appearance light
fi

echo "== Mac screens"
xcodebuild -project Pennant.xcodeproj -scheme PennantMac -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$WORK/mac-dd" build >"$WORK/mac-build.log" 2>&1
# The debug build shares the Mac app's preferences (same bundle id), and saves its window there as it goes: put your
# own window's frame and columns back afterwards. It also opens at the shot size rather than your saved frame: at
# 1180×760 (the default size) AppKit runs into a layout loop at launch ("more Update Constraints in Window passes than
# there are views in the window"), the crash the Mac app has had since Sep 29.
FRAME_KEYS=("NSWindow Frame main" "NSSplitView Subview Frames main, SidebarNavigationSplitView")
defaults export dev.pennant.mac "$WORK/mac-prefs.plist" 2>/dev/null || true
restore_prefs() {
  [[ -f "$WORK/mac-prefs.plist" ]] || return 0
  python3 - "$WORK/mac-prefs.plist" "${FRAME_KEYS[@]}" <<'PY'
import plistlib, subprocess, sys
saved = plistlib.load(open(sys.argv[1], "rb"))
for key in sys.argv[2:]:
    if key not in saved:
        subprocess.run(["defaults", "delete", "dev.pennant.mac", key], capture_output=True)
        continue
    value = plistlib.dumps(saved[key], fmt=plistlib.FMT_XML).decode()
    fragment = value.split("<plist version=\"1.0\">", 1)[1].rsplit("</plist>", 1)[0].strip()
    subprocess.run(["defaults", "write", "dev.pennant.mac", key, fragment], check=True)
PY
}
trap 'kill $HOST_PID 2>/dev/null; restore_prefs || true' EXIT
SCREEN=$(defaults read dev.pennant.mac "${FRAME_KEYS[1]}" 2>/dev/null | awk '{print $5, $6, $7, $8}')
SIZE=${PENNANT_DEBUG_SHOT_SIZE:-1440x900}
PENNANT_DEBUG_HOST=127.0.0.1:$PORT PENNANT_DEBUG_TOKEN_FILE="$WORK/data/client-token" PENNANT_DEBUG_SHOTS="$WORK/mac" \
  "$WORK/mac-dd/Build/Products/Debug/Pennant.app/Contents/MacOS/Pennant" -ApplePersistenceIgnoreState YES \
  -"${FRAME_KEYS[1]}" "40 40 ${SIZE%x*} ${SIZE#*x} ${SCREEN:-0 0 1728 1117}" >"$WORK/mac.log" 2>&1 || echo "The Mac app stopped early (exit $?); see $WORK/mac.log"

echo "== Panes (the conversation side, without the sidebar, so it reads larger on the site)"
for f in lead coding approval approved inbox helpers memory reports usage; do
  for v in "" -dark; do
    src="$WORK/mac/$f$v.png"
    [[ -f "$src" ]] || continue
    w=$(sips -g pixelWidth "$src" | awk '/pixelWidth/ {print $2}'); h=$(sips -g pixelHeight "$src" | awk '/pixelHeight/ {print $2}')
    side=$(( w * 262 / 1440 ))
    sips -c $((h - 2)) $((w - side)) --cropOffset 1 $side "$src" --out "$WORK/mac/$f-pane$v.png" >/dev/null
  done
done

echo "== AVIF"
for png in "$WORK"/mac/*.png(N) "$WORK"/phone/*.png(N); do
  sips -s format avif -s formatOptions 72 "$png" --out "$OUT/${png:t:r}.avif" >/dev/null
done
ls -la "$OUT"
echo "PNGs are in $WORK"
