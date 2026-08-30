#!/bin/bash
#
# Re-shoot the macOS App Store screenshots.
#
#   Tools/shoot-mac.sh   -> Store/screenshots/mac, 2880x1800
#
# Separate from `Tools/shoot.sh` because macOS has no simulator: this drives the real app
# on the real desktop, which brings two problems that script never has.
#
#   1. Preferences. The Mac app reads the same `net.hlnd.weatherstar` domain as whatever
#      copy the person running this already uses, so the settings needed for a clean shot
#      would overwrite theirs. The domain is exported first and restored at the end,
#      whether or not the run succeeds.
#   2. Window size. Apple wants exact pixels, so the window is placed at a known size with
#      System Events and the region captured directly. On a Retina display 1440x810 points
#      comes back as 2880x1620 pixels, which is then padded to the 2880x1800 Apple accepts
#      for this slot.
#
# A window will appear and move around while this runs. That is expected.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="net.hlnd.weatherstar"
OUT="$ROOT/Store/screenshots/mac"
DERIVED="$(mktemp -d)"
BACKUP="$(mktemp -t ws4k-prefs).plist"

# Points; the capture comes back at 2x on a Retina panel.
WIDTH=1440
HEIGHT=810
EXPECT_W=2880
EXPECT_H=1800

SHOTS=(
    "current-weather:01-current-weather"
    "radar:02-radar"
    "extended-forecast:03-extended-forecast"
    "hourly:04-hourly"
    "regional-forecast:05-regional-forecast"
)

HAD_PREFS=0
if defaults export "$BUNDLE_ID" "$BACKUP" 2>/dev/null; then
    HAD_PREFS=1
    echo "saved existing preferences to $BACKUP"
fi

cleanup() {
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    if [ "$HAD_PREFS" = "1" ]; then
        defaults import "$BUNDLE_ID" "$BACKUP" 2>/dev/null || true
        echo "restored your preferences"
    else
        defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
    fi
    rm -rf "$DERIVED"
}
trap cleanup EXIT

echo "building..."
xcodebuild \
    -project "$ROOT/WeatherStar.xcodeproj" \
    -scheme "WeatherStar (macOS)" \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    build >/dev/null

APP="$DERIVED/Build/Products/Release/weatherfeels.app"
[ -d "$APP" ] || { echo "no app at $APP" >&2; exit 1; }

json_data() { printf '%s' "$1" | xxd -p | tr -d '\n'; }

defaults write "$BUNDLE_ID" ws4k.hasCompletedOnboarding -bool true
defaults write "$BUNDLE_ID" ws4k.musicEnabled -bool false
defaults write "$BUNDLE_ID" ws4k.savedLocation -data \
    "$(json_data '{"name":"Tampa, FL","latitude":27.95,"longitude":-82.46}')"
defaults write "$BUNDLE_ID" ws4k.locationMode -data "$(json_data '"manual"')"

mkdir -p "$OUT"

for shot in "${SHOTS[@]}"; do
    display="${shot%%:*}"
    name="${shot##*:}"

    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    sleep 2
    defaults write "$BUNDLE_ID" ws4k.enabledDisplays -array "$display"

    open -a "$APP"
    # The NWS fetch, plus radar tiles.
    sleep 30

    # Place the window at a known origin and size. 0,0 is under the menu bar, so it is
    # offset far enough down to clear it and still fit on a laptop panel.
    osascript <<OSA >/dev/null
tell application "System Events"
    set procs to (every process whose bundle identifier is "$BUNDLE_ID")
    if (count of procs) is 0 then error "app is not running"
    tell item 1 of procs
        set frontmost to true
        tell window 1
            set position to {0, 40}
            set size to {$WIDTH, $HEIGHT}
        end tell
    end tell
end tell
OSA
    sleep 3

    raw="$OUT/$name.png"
    screencapture -x -R "0,40,$WIDTH,$HEIGHT" "$raw"

    # Pad to the slot Apple accepts, centring the picture on black — the same black the
    # app letterboxes with, so the join is invisible.
    python3 - "$raw" "$EXPECT_W" "$EXPECT_H" <<'PY'
import subprocess, sys
path, want_w, want_h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", path],
                     capture_output=True, text=True).stdout
have = {}
for line in out.splitlines():
    line = line.strip()
    if line.startswith("pixel") and ":" in line:
        key, value = line.split(":", 1)
        have[key.strip()] = int(value.strip())
w, h = have["pixelWidth"], have["pixelHeight"]
if (w, h) != (want_w, want_h):
    # `sips -p` pads to the requested size, centring and filling with the given colour.
    subprocess.run(["sips", "-p", str(want_h), str(want_w), "--padColor", "000000", path],
                   check=True, capture_output=True)
PY

    width=$(sips -g pixelWidth "$raw" | awk '/pixelWidth/ {print $2}')
    height=$(sips -g pixelHeight "$raw" | awk '/pixelHeight/ {print $2}')
    if [ "$width" != "$EXPECT_W" ] || [ "$height" != "$EXPECT_H" ]; then
        echo "  $name: FAILED — got ${width}x${height}, wanted ${EXPECT_W}x${EXPECT_H}" >&2
        exit 1
    fi
    echo "  $name  ${width}x${height}"
done

echo "wrote $(ls -1 "$OUT" | wc -l | tr -d ' ') screenshots to $OUT"
