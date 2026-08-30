#!/bin/bash
#
# Re-shoot the App Store screenshots for one platform from the simulator.
#
#   Tools/shoot.sh ipad     -> Store/screenshots/ipad,   2064x2752 (13" iPad, portrait)
#   Tools/shoot.sh iphone   -> Store/screenshots/iphone, 2868x1320 (6.9" iPhone, landscape)
#   Tools/shoot.sh tvos     -> Store/screenshots/tvos,   3840x2160 (Apple TV 4K)
#
# The two slots deliberately show different things: the iPad set is portrait, where the
# app draws the television, and the iPhone set is landscape, where the picture fills the
# screen. Between them the product page shows both halves of what the app does.
#
# macOS is not covered here — it does not run in a simulator, so its set has to be
# re-shot by hand whenever the on-screen artwork changes.
#
# The App Store wants exact pixel sizes, so the device model matters: an iPad Pro 13-inch
# is natively 2064x2752 and a 6.9" iPhone is 1320x2868, which is why those two are named
# below rather than "whatever iPad is installed".
#
# Why this exists rather than living in someone's shell history: the set has to be
# re-shot whenever the displays change, and getting it right depends on several things
# that are not obvious and were each learned the hard way —
#
#   * One display is enabled at a time and the app relaunched between shots, so each
#     frame is of a known display rather than wherever the rotation happened to be.
#   * Preferences are written with `simctl spawn <device> defaults`, never by editing the
#     plist. Editing the file appears to work and does not: `cfprefsd` holds its own cached
#     copy and writes it back over the edit.
#   * Enum-valued preferences are stored as JSON by `AppSettings`, so they go in as
#     `-data <hex>` of the encoded string, quotes included.
#   * The app needs a good half-minute on a cold launch: it fetches from the NWS, and radar
#     has tiles to pull on top of that. A short wait yields a screenshot of the loading
#     screen, which looks like the shot worked.
#   * It runs on its own simulator, created and deleted here, so it neither disturbs nor is
#     disturbed by whatever device you have open in Simulator.app.
#
set -euo pipefail

PLATFORM="${1:-ipad}"
SHOTS=()
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="net.hlnd.weatherstar"
SCHEME="WeatherStar (iOS)"
RUNTIME_PREFIX="com.apple.CoreSimulator.SimRuntime.iOS"
PRODUCT_DIR="Release-iphonesimulator"
SIM_PLATFORM="iOS Simulator"

case "$PLATFORM" in
ipad)
    DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB"
    EXPECT_W=2064
    EXPECT_H=2752
    # Portrait, so the shots show the television — the thing worth putting on the page.
    # The app turns itself landscape at launch, so it has to be told not to.
    KEEP_ORIENTATION=1
    ROTATE=0
    ;;
tvos)
    DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-4K"
    SCHEME="WeatherStar (tvOS)"
    RUNTIME_PREFIX="com.apple.CoreSimulator.SimRuntime.tvOS"
    PRODUCT_DIR="Release-appletvsimulator"
    SIM_PLATFORM="tvOS Simulator"
    EXPECT_W=3840
    EXPECT_H=2160
    # A television is landscape and does not rotate, so neither applies.
    KEEP_ORIENTATION=0
    ROTATE=0
    # The big screen has room for the whole rotation, so it shows more of it.
    SHOTS=(
        "current-weather:01-current-weather"
        "radar:02-radar"
        "extended-forecast:03-extended-forecast"
        "hourly:04-hourly"
        "regional-forecast:05-regional-forecast"
        "almanac:06-almanac"
        "latest-observations:07-latest-observations"
        "travel:08-travel"
    )
    ;;
iphone)
    DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro-Max"
    EXPECT_W=2868
    EXPECT_H=1320
    # Landscape, filling the screen with the picture. The simulator is physically portrait
    # and the app turns itself to landscape inside it, so the framebuffer comes out portrait
    # with the picture on its side; rotating the capture is lossless and lands exactly on
    # Apple's pixel size.
    KEEP_ORIENTATION=0
    ROTATE=1
    ;;
*)
    echo "usage: $0 [ipad|iphone|tvos]" >&2
    exit 2
    ;;
esac

OUT="$ROOT/Store/screenshots/$PLATFORM"
# The displays to shoot, and the filename each one lands in. Order is the order they
# appear on the product page, so the strongest shot goes first. tvOS sets its own longer
# list above.
if [ "${#SHOTS[@]}" -eq 0 ]; then
    SHOTS=(
        "current-weather:01-current-weather"
        "radar:02-radar"
        "extended-forecast:03-extended-forecast"
        "hourly:04-hourly"
        "regional-forecast:05-regional-forecast"
    )
fi

RUNTIME=$(xcrun simctl list runtimes --json | RUNTIME_PREFIX="$RUNTIME_PREFIX" python3 -c '
import json, os, sys
prefix = os.environ["RUNTIME_PREFIX"]
runtimes = [r for r in json.load(sys.stdin)["runtimes"]
            if r["isAvailable"] and r["identifier"].startswith(prefix)]
if not runtimes:
    sys.exit(f"no available runtime for {prefix}")
# Highest version available.
runtimes.sort(key=lambda r: [int(p) for p in r["version"].split(".")])
print(runtimes[-1]["identifier"])
')
echo "runtime: $RUNTIME"

DERIVED="$(mktemp -d)"
DEVICE=$(xcrun simctl create "ws4k-shoot-$PLATFORM-$$" "$DEVICE_TYPE" "$RUNTIME")
echo "device:  $DEVICE"

cleanup() {
    xcrun simctl delete "$DEVICE" >/dev/null 2>&1 || true
    rm -rf "$DERIVED"
}
trap cleanup EXIT

xcrun simctl bootstatus "$DEVICE" -b >/dev/null

echo "building..."
xcodebuild \
    -project "$ROOT/WeatherStar.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "platform=$SIM_PLATFORM,id=$DEVICE" \
    -derivedDataPath "$DERIVED" \
    build >/dev/null

APP="$DERIVED/Build/Products/$PRODUCT_DIR/weatherfeels.app"
xcrun simctl install "$DEVICE" "$APP"

# `AppSettings` stores Codable values as JSON, so these go in as raw data.
json_data() { printf '%s' "$1" | xxd -p | tr -d '\n'; }

write_prefs() {
    xcrun simctl spawn "$DEVICE" defaults write "$BUNDLE_ID" "$1" "${@:2}"
}

write_prefs ws4k.hasCompletedOnboarding -bool true
write_prefs ws4k.musicEnabled -bool false
# Tampa: coastal radar has weather on it most days, and the name is short enough that the
# ticker does not truncate it.
write_prefs ws4k.savedLocation -data "$(json_data '{"name":"Tampa, FL","latitude":27.95,"longitude":-82.46}')"
write_prefs ws4k.locationMode -data "$(json_data '"manual"')"

mkdir -p "$OUT"

for shot in "${SHOTS[@]}"; do
    display="${shot%%:*}"
    name="${shot##*:}"

    xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
    write_prefs ws4k.enabledDisplays -array "$display"
    if [ "$KEEP_ORIENTATION" = "1" ]; then
        SIMCTL_CHILD_WS4K_KEEP_DEVICE_ORIENTATION=1 \
            xcrun simctl launch "$DEVICE" "$BUNDLE_ID" >/dev/null
    else
        xcrun simctl launch "$DEVICE" "$BUNDLE_ID" >/dev/null
    fi

    # Long enough for the NWS fetch and, for radar, its tiles.
    sleep 35

    raw="$OUT/$name.png"
    xcrun simctl io "$DEVICE" screenshot --type=png "$raw" >/dev/null 2>&1

    if [ "$ROTATE" = "1" ]; then
        # 270, not 90: the app turns to landscape-left inside a portrait framebuffer, so a
        # 90-degree turn lands the picture upside down. Verified against a capture rather
        # than reasoned about — it is a coin flip either way and the wrong one is not
        # subtle.
        sips -r 270 "$raw" >/dev/null
    fi

    width=$(sips -g pixelWidth "$raw" | awk '/pixelWidth/ {print $2}')
    height=$(sips -g pixelHeight "$raw" | awk '/pixelHeight/ {print $2}')
    if [ "$width" != "$EXPECT_W" ] || [ "$height" != "$EXPECT_H" ]; then
        echo "  $name: FAILED — got ${width}x${height}, App Store needs ${EXPECT_W}x${EXPECT_H}" >&2
        exit 1
    fi
    echo "  $name  ${width}x${height}"
done

echo "wrote $(ls -1 "$OUT" | wc -l | tr -d ' ') screenshots to $OUT"
