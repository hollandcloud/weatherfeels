#!/bin/bash
#
# Re-shoot the App Store screenshots for one platform from the simulator.
#
#   Tools/shoot.sh ipad     -> Store/screenshots/ipad,   2064x2752 (13" iPad, portrait)
#   Tools/shoot.sh iphone   -> Store/screenshots/iphone, 2868x1320 (6.9" iPhone, landscape)
#   Tools/shoot.sh tvos     -> Store/screenshots/tvos,   3840x2160 (Apple TV 4K)
#   Tools/shoot.sh duo      -> Store/screenshots/duo-inner,         2853x2007 (iPhone Duo, open)
#                              Store/screenshots/duo-outer,         2034x1398 (closed, sideways)
#                              Store/screenshots/duo-outer-upright, 1398x2034 (closed, upright)
#
# The Duo set is what earns the product page its iPhone Duo badge: App Store Connect shows it
# once screenshots for that device are submitted. The inner display is shot both open flat,
# where the picture fills it, and folded into the book pose, where the set stands on one page
# and its control deck fills the other — the layout no other device has. The laptop pose is
# missing because it needs the device turned on its side, which nothing outside DeviceHub's
# window can do.
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
#   * Every capture is redrawn without its alpha channel. The simulator always writes one,
#     and Apple's specification says screenshots "can't include alpha channels".
#   * The Duo's hinge is set with `Tools/hinge_helper.c`, compiled here and run inside the
#     device: `simctl` has no hinge command. Its shots enable every display and hold the
#     rotation on one with `WS4K_HOLD_DISPLAY`, so the control deck shows its full set of
#     presets rather than the single one a one-display rotation would leave it.
#   * The outer display has a camera hole, and for a few seconds after launch iOS draws a
#     black surround over it. A closed shot is checked for that disc and retaken until it
#     has gone; the capture size and the alpha check would both pass with it in.
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
duo)
    DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"
    # Each display's capture comes out the right way up at Apple's landscape size, the app
    # having turned to landscape inside it, so neither applies.
    KEEP_ORIENTATION=0
    ROTATE=0
    # display:file:screen:hinge degrees. 110 is the book pose, 180 open flat, 0 closed.
    # `radar-map` is the zoomable map over the rotation rather than a display of its own.
    #
    # Open first, then closed sideways, then closed upright. While this was written the
    # simulator was also being driven by hand, which threw several runs off, so treat any
    # wisdom about the order as unproven. If a closed shot comes out wrong, first make sure
    # nothing else is using the device, and check every image either way.
    DUO_SHOTS=(
        "current-weather:01-current-weather-book:inner:110"
        "radar:02-radar:inner:180"
        "radar-map:03-radar-map:inner:180"
        "hourly:04-hourly-book:inner:110"
        "tides:05-tides:inner:180"
        "current-weather:01-current-weather:outer:0"
        "radar:02-radar:outer:0"
        "almanac:03-almanac:outer:0"
        "tides:04-tides:outer:0"
        "hourly:05-hourly:outer:0"
        "current-weather:01-current-weather:outer-upright:0"
        "radar:02-radar:outer-upright:0"
        "hourly:03-hourly:outer-upright:0"
        "tides:04-tides:outer-upright:0"
    )
    ;;
*)
    echo "usage: $0 [ipad|iphone|tvos|duo]" >&2
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
    -project "$ROOT/weatherfeels.xcodeproj" \
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

# Two small jobs on a capture, in Swift because `sips` can do neither:
#   image flatten <file>         redraw it onto an opaque bitmap, in place, keeping its colour
#                                space
#   image hole <file> <x> <y>    exit 2 if the disc of radius 40 around (x, y) is black — the
#                                surround iOS briefly draws over the Duo's outer camera hole
IMAGE="$DERIVED/image"
cat > "$DERIVED/image.swift" <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
let url = URL(fileURLWithPath: arguments[2]) as CFURL
guard let source = CGImageSourceCreateWithURL(url, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else { fatalError("cannot read \(arguments[2])") }

// An opaque sRGB bitmap of the capture, readable byte by byte.
func opaque(space: CGColorSpace) -> (CGContext, UnsafeMutablePointer<UInt8>) {
    let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: image.width * image.height * 4)
    let context = CGContext(
        data: bytes, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return (context, bytes)
}

switch arguments[1] {
case "flatten":
    let (context, _) = opaque(space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!)
    guard let flat = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("cannot write \(arguments[2])") }
    CGImageDestinationAddImage(destination, flat, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("cannot write \(arguments[2])") }
case "hole":
    let (_, bytes) = opaque(space: CGColorSpace(name: CGColorSpace.sRGB)!)
    let (cx, cy, r) = (Int(arguments[3])!, Int(arguments[4])!, 40)
    var black = 0
    for y in max(0, cy - r)..<min(image.height, cy + r) {
        for x in max(0, cx - r)..<min(image.width, cx + r) where (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r {
            let i = (y * image.width + x) * 4
            if bytes[i] <= 5, bytes[i + 1] <= 5, bytes[i + 2] <= 5 { black += 1 }
        }
    }
    // A full disc is about 5,000 pixels; the app's own darkest edges give a few dozen.
    exit(black > 2_000 ? 2 : 0)
default:
    fatalError("unknown command \(arguments[1])")
}
SWIFT
xcrun swiftc -O -o "$IMAGE" "$DERIVED/image.swift"

# Fails the run on a capture Apple would refuse, rather than leaving it to be found at upload.
check_size() {
    local raw="$1" expect_w="$2" expect_h="$3" width height
    width=$(sips -g pixelWidth "$raw" | awk '/pixelWidth/ {print $2}')
    height=$(sips -g pixelHeight "$raw" | awk '/pixelHeight/ {print $2}')
    if [ "$width" != "$expect_w" ] || [ "$height" != "$expect_h" ]; then
        echo "  $(basename "$raw"): FAILED — got ${width}x${height}, App Store needs ${expect_w}x${expect_h}" >&2
        exit 1
    fi
    if [ "$(sips -g hasAlpha "$raw" | awk '/hasAlpha/ {print $2}')" != "no" ]; then
        echo "  $(basename "$raw"): FAILED — still has an alpha channel" >&2
        exit 1
    fi
    echo "  $(basename "$raw")  ${width}x${height}"
}

if [ "$PLATFORM" = "duo" ]; then
    # The radar map leaves the status bar showing; give it Apple's own tidy one.
    xcrun simctl status_bar "$DEVICE" override --time 9:41 --batteryState charged \
        --batteryLevel 100 --cellularBars 4 --wifiBars 3 --dataNetwork wifi

    HINGE="$DERIVED/hinge_helper"
    xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -O2 \
        -o "$HINGE" "$ROOT/Tools/hinge_helper.c" -framework IOKit -framework CoreFoundation
    codesign -f -s - "$HINGE" >/dev/null 2>&1

    # Every display enabled — the default — so the deck has all of its presets.
    xcrun simctl spawn "$DEVICE" defaults delete "$BUNDLE_ID" ws4k.enabledDisplays >/dev/null 2>&1 || true

    for shot in "${DUO_SHOTS[@]}"; do
        IFS=: read -r display name screen angle <<<"$shot"
        # Which display to capture, the size Apple wants from it, and where its camera hole is.
        keep=""
        case "$screen" in
        inner)         capture=3 expect_w=2853 expect_h=2007 hole="" ;;
        outer)         capture=1 expect_w=2034 expect_h=1398 hole="139 141" ;;
        outer-upright) capture=1 expect_w=1398 expect_h=2034 hole="1257 139" keep=1 ;;
        esac
        dir="$ROOT/Store/screenshots/duo-$screen"
        mkdir -p "$dir"

        xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
        xcrun simctl spawn "$DEVICE" "$HINGE" set "$angle"
        sleep 3
        # The app tests these for presence, not value, so an empty one would still switch its
        # behaviour on: each goes in only when wanted.
        launch=(SIMCTL_CHILD_WS4K_HOLD_DISPLAY="$display")
        if [ "$display" = "radar-map" ]; then
            launch=(SIMCTL_CHILD_WS4K_HOLD_DISPLAY=current-weather SIMCTL_CHILD_WS4K_OPEN_RADAR_MAP=1)
        fi
        if [ -n "$keep" ]; then launch+=(SIMCTL_CHILD_WS4K_KEEP_DEVICE_ORIENTATION=1); fi

        # A disc that never clears is the home screen, whose status bar keeps the surround
        # drawn: the app is not in front. Launch it again before giving up.
        raw="$dir/$name.png"
        captured=""
        for launch_attempt in 1 2 3; do
            xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
            sleep 2
            env "${launch[@]}" xcrun simctl launch "$DEVICE" "$BUNDLE_ID" >/dev/null

            # The hold waits for the display's data, so this is the NWS fetch plus radar frames.
            sleep 40

            for attempt in 1 2 3 4 5 6; do
                xcrun simctl io "$DEVICE" screenshot --display="$capture" --type=png "$raw" >/dev/null 2>&1
                # shellcheck disable=SC2086 # $hole is two numbers
                if [ -z "$hole" ] || "$IMAGE" hole "$raw" $hole; then captured=1; break; fi
                sleep 4
            done
            if [ -n "$captured" ]; then break; fi
            echo "  $name: the app is not on screen; launching it again" >&2
        done
        if [ -z "$captured" ]; then
            echo "  $name: FAILED — the camera surround never cleared" >&2
            exit 1
        fi
        "$IMAGE" flatten "$raw"
        check_size "$raw" "$expect_w" "$expect_h"
    done

    for screen in inner outer outer-upright; do
        echo "wrote $(ls -1 "$ROOT/Store/screenshots/duo-$screen" | wc -l | tr -d ' ') to duo-$screen"
    done
    exit 0
fi

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

    "$IMAGE" flatten "$raw"
    check_size "$raw" "$EXPECT_W" "$EXPECT_H"
done

echo "wrote $(ls -1 "$OUT" | wc -l | tr -d ' ') screenshots to $OUT"
