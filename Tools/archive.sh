#!/bin/bash
#
# Archive, export and optionally upload all three apps in one pass.
#
# Xcode's Organizer archives one scheme at a time, so shipping a release means three
# separate trips through the UI. The three archives are independent, so this runs them
# concurrently and reports at the end.
#
#   Tools/archive.sh                 archive + export all three
#   Tools/archive.sh --upload        also upload to App Store Connect
#   Tools/archive.sh tvOS macOS      only the platforms named
#
# Uploading needs an App Store Connect API key, since altool no longer accepts an Apple
# ID password. Create one under Users and Access → Integrations → App Store Connect API,
# save the .p8 in ~/.appstoreconnect/private_keys/, then export:
#
#   export ASC_KEY_ID=XXXXXXXXXX
#   export ASC_ISSUER_ID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

PROJECT=WeatherStar.xcodeproj
BUILD_DIR=build
UPLOAD=false
PLATFORMS=()

for arg in "$@"; do
  case "$arg" in
    --upload) UPLOAD=true ;;
    iOS|tvOS|macOS) PLATFORMS+=("$arg") ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[ ${#PLATFORMS[@]} -eq 0 ] && PLATFORMS=(iOS tvOS macOS)

# The destination for an archive is the generic *device* platform, not a simulator.
destination_for() {
  case "$1" in
    iOS)   echo "generic/platform=iOS" ;;
    tvOS)  echo "generic/platform=tvOS" ;;
    macOS) echo "generic/platform=macOS" ;;
  esac
}

# Automatic signing needs an authenticated account to create or refresh a profile.
# Xcode's own Accounts pane is one way; the other is the same App Store Connect API key
# used for uploading, which is what a machine with no Xcode sign-in has. Without it,
# `-allowProvisioningUpdates` fails with "No Accounts: Add a new account in Accounts
# settings" — which reads like a project problem and is not one.
AUTH_ARGS=()
KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID:-}.p8"
if [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] && [ -f "$KEY_PATH" ]; then
  AUTH_ARGS=(
    -authenticationKeyPath "$KEY_PATH"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  )
  echo "Signing with App Store Connect key $ASC_KEY_ID"
else
  echo "No ASC API key in the environment; relying on Xcode's Accounts pane for signing."
fi

mkdir -p "$BUILD_DIR"

# App Store distribution for all three. macOS goes to the Mac App Store rather than
# being notarised for direct download; switch `method` to `developer-id` if you want a
# standalone .app or .dmg instead.
# The team the export signs for.
#
# Not optional, and its absence is invisible on a developer's Mac: with `signingStyle`
# automatic and no `teamID`, xcodebuild infers the team from whatever account Xcode is
# signed in as. A CI runner is signed in as nobody, so the export has no team to request a
# distribution profile for and fails with
#
#     error: exportArchive Cloud signing permission error
#     error: exportArchive No profiles for 'net.hlnd.weatherstar' were found
#
# which reads like the key lacking permission, and is not — the archive immediately before
# it succeeded using the same key. Read from project.yml so there is one definition, with
# an environment override for CI.
TEAM_ID="${IOS_TEAM_ID:-$(grep -m1 'WS4K_TEAM_ID:' project.yml | tr -d ' "' | cut -d: -f2)}"
[ -n "$TEAM_ID" ] || { echo "no team id: set IOS_TEAM_ID or WS4K_TEAM_ID in project.yml" >&2; exit 1; }

cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>destination</key>
	<string>export</string>
	<key>method</key>
	<string>app-store-connect</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
PLIST

# Xcode's Organizer only lists archives found under its own Archives directory, so put
# them there rather than in build/. That keeps the no-API-key upload path available:
# Window → Organizer → pick the archive → Distribute App.
ORGANIZER_DIR="$HOME/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)"
STAMP=$(date "+%d-%m-%Y, %H.%M")
mkdir -p "$ORGANIZER_DIR"

archive_one() {
  local platform="$1"
  local log="$BUILD_DIR/$platform.log"
  local archive="$ORGANIZER_DIR/WeatherStar $platform $STAMP.xcarchive"
  local export_dir="$BUILD_DIR/export-$platform"

  rm -rf "$archive" "$export_dir"

  # -allowProvisioningUpdates lets automatic signing create or refresh the profile;
  # without it a first archive on a new machine fails on a missing profile.
  if ! xcodebuild archive \
      -project "$PROJECT" \
      -scheme "WeatherStar ($platform)" \
      -destination "$(destination_for "$platform")" \
      -configuration Release \
      -archivePath "$archive" \
      -allowProvisioningUpdates \
      "${AUTH_ARGS[@]}" \
      >"$log" 2>&1; then
    echo "FAIL archive $platform (see $log)"
    return 1
  fi

  if ! xcodebuild -exportArchive \
      -archivePath "$archive" \
      -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
      -exportPath "$export_dir" \
      -allowProvisioningUpdates \
      "${AUTH_ARGS[@]}" \
      >>"$log" 2>&1; then
    echo "FAIL export $platform (see $log)"
    return 1
  fi

  echo "OK $platform -> $export_dir"
  echo "   archive: $archive"
}

echo "Archiving: ${PLATFORMS[*]}"
pids=()
for platform in "${PLATFORMS[@]}"; do
  archive_one "$platform" &
  pids+=("$!")
done

status=0
for pid in "${pids[@]}"; do
  wait "$pid" || status=1
done

if [ "$status" -ne 0 ]; then
  echo
  echo "One or more archives failed; nothing was uploaded."
  exit 1
fi

echo
find "$BUILD_DIR" -maxdepth 2 \( -name '*.ipa' -o -name '*.pkg' \) -print

if [ "$UPLOAD" != true ]; then
  echo
  echo "Not uploading. Re-run with --upload, or drag the archives from Xcode's Organizer."
  exit 0
fi

if [ -z "${ASC_KEY_ID:-}" ] || [ -z "${ASC_ISSUER_ID:-}" ]; then
  echo "ASC_KEY_ID and ASC_ISSUER_ID must be set to upload. See the header of this script."
  exit 1
fi

for platform in "${PLATFORMS[@]}"; do
  package=$(find "$BUILD_DIR/export-$platform" -maxdepth 1 \
    \( -name '*.ipa' -o -name '*.pkg' \) | head -1)
  if [ -z "$package" ]; then
    echo "SKIP upload $platform: no package found"
    status=1
    continue
  fi

  type=$([ "$platform" = macOS ] && echo osx || echo "$([ "$platform" = iOS ] && echo ios || echo appletvos)")
  echo "Uploading $platform ($package)"
  if xcrun altool --upload-app \
      --type "$type" \
      --file "$package" \
      --apiKey "$ASC_KEY_ID" \
      --apiIssuer "$ASC_ISSUER_ID" \
      >>"$BUILD_DIR/$platform.log" 2>&1; then
    echo "OK upload $platform"
  else
    echo "FAIL upload $platform (see $BUILD_DIR/$platform.log)"
    status=1
  fi
done

exit "$status"
