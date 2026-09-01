# WeatherFeels
## a WeatherStar 4000+ port for Apple platforms

A native SwiftUI recreation of [netbymatt/ws4kp](https://github.com/netbymatt/ws4kp) —
The Weather Channel's WeatherStar 4000 local forecast unit — running on **tvOS,
iOS, iPadOS and macOS**, with support for your own background music.

It ships on the App Store as **weatherfeels**. The Xcode project, the Swift package
and most of the type names still read `WeatherStar`, which is deliberate: renaming an
app is about what the store and the user see, and churning every internal symbol would
be a large diff for no benefit. References below to the WeatherStar 4000 describe the
original hardware and the upstream project, not this app.

Live data comes from the US National Weather Service. No accounts, no API keys,
no analytics, no tracking.

---

## Why a native port rather than a web view

tvOS has no WebKit at all — there is no `WKWebView` to wrap. Getting WeatherStar
onto an Apple TV therefore meant rebuilding the displays in SwiftUI rather than
bundling the web app. Everything else follows from that decision, including the
resolution independence below, which a fixed 640×480 canvas in a web view could
not have delivered.

## Resolution independence

Upstream draws to a fixed 640×480 canvas. That canvas is preserved here as a
*design coordinate space* — all the ported layout math still reads in 640×480
points — but nothing is rendered at that size:

| Element | How it scales |
|---|---|
| Backgrounds | Redrawn procedurally as SwiftUI `Canvas` gradients, shapes and rules. Colors and geometry were measured from the original PNGs. Sharp at any size. |
| Text | Real `glyf` outline fonts at scaled point sizes, so Core Text rasterizes at the output resolution. Apple TV 4K rasterizes vector content at native 2160p even though UIKit reports 1080p logical. |
| Weather icons | Hand-drawn pixel art, upscaled with `.interpolation(.none)` (nearest neighbor) so it stays crisp pixel art instead of turning to mush. |
| Scanlines | Spaced in design space — 480 lines down the canvas, matching the original raster — then scaled. Deriving spacing from the design height rather than output pixels avoids moiré at arbitrary screen sizes. |

Three design spaces are chosen by container aspect ratio (or pinned in Settings):

- **Standard** 640×480 (4:3) — authentic, pillarboxed on a widescreen display
- **Wide** 854×480 (16:9) — fills a TV edge to edge; a 4K panel scales this 4.5×
- **Portrait** 640×1137 — phones held upright

Layout is scaled at *layout* time (font sizes, frames, offsets), not with
`.scaleEffect`. A transform would rasterize text at 1× and upscale the bitmap,
which visibly softens on a 4K TV.

## Displays

All twelve, matching upstream's rotation order and per-display timing:

Hazards · Current Conditions · Latest Observations · Hourly Forecast ·
Hourly Graph · Travel Forecast · Regional Observations · Local Forecast ·
Extended Forecast · Almanac · SPC Outlook · Radar

Plus the startup progress screen and the bottom conditions ticker. Each display
loads independently and reports its own status, so one unavailable source (a
station with no barometer, a radar host that is down) drops just that display
from the rotation rather than blanking the screen.

Hourly, Travel, Hourly Graph and SPC Outlook are off by default, as upstream has
them. Toggle any of them in Settings.

### Radar is centred on you, unlike upstream

Upstream's `RADAR_OFFSET` is a literal `{x: 240, y: 138}` against a 240×163 crop, which
places your location at 100% across and 85% down — the bottom-right corner — so the
window actually shows the area to your north-west. (Its `* 2` in
`getXYFromLatitudeLongitudeDoppler` is undone by the `/ 2` in `radar-processor.mjs`, so
the offset really is applied at that scale.) Upstream centres its *base map* via
`- TILE_SIZE.y / 2` but never the radar window.

Here the offset is half the crop, so "Local Radar" means what it says. `RadarFramingTests`
asserts a spread of locations land near the middle of their own window — with eastern
Maine flagged as a legitimate exception, since the projection only reaches longitude
−68.68 and the crop has to clamp inside the composite.

## Screen care on a television

Two options under **Settings → Display**, both aimed at an Apple TV left running for
hours:

**Shift image to protect the screen** — on by default on tvOS only. The header plate, logo
and clock never move, which is the worst case for an OLED panel. `BurnInShift` walks the
whole canvas around a nine-position ring, three points from centre, one step every 90
seconds. Offsets are whole points, never fractional: a sub-point translation would
resample the pixel-art glyphs and undo the nearest-neighbour scaling everything else
preserves. The ring sums to zero in both axes, so no pixel accumulates more exposure than
another. Driven by a 90-second loop rather than a `TimelineView`, so it invalidates the
canvas only when it actually moves.

**Screen effect** — `Static` (default), `Animated`, or `CRT tube`.

*Animated* drifts the scanlines and creeps a soft roll bar down the screen. It is a
`colorEffect` — the cheapest shader shape there is, because it only ever needs the pixel it
is writing, so it does no texture reads and SwiftUI never rasterises an offscreen layer.

It started life as a `Canvas` overlay, on the reasoning that two fills a frame would get the
same look more simply. On a real Apple TV at 4K that was severely slow, and the reason is
worth recording: the `Canvas` closure re-ran every frame, rebuilding a path of several
hundred rectangles and rasterising it on the CPU at output resolution. The Mac's CPU hid it
completely in the simulator. Translating a cached drawing instead of redrawing helped, but a
shader is the right tool and is now the default whenever the metallib is present.

*CRT tube* is [`Shaders/StarCRT.metal`](Shaders/StarCRT.metal): barrel curvature, phosphor
bloom, convergence fringing that grows towards the edges, the scanline mask and corner
falloff, in one `layerEffect` pass at 30fps. The order matters and mirrors the physics —
geometry first, because the glass bends the picture; then the beam; then the mask, which
belongs to the *face* of the tube and so is keyed off the destination pixel rather than the
warped source, or the lines would bend along with the image.

The `Scanlines` setting still sets how heavy the mask is, and `Off` gives a clean tube with
curvature and bloom but no lines.

Two things that shape how this is wired:

When the metallib is absent — the package's snapshot tests, or any build without it — both
modes fall back to the drawn `Canvas` overlay rather than losing the effect. `.plain` always
uses the drawn overlay: a static pattern rasterises once and costs nothing per frame, where
a shader would add a pass to every frame to redraw something that never changes.

**The shader cannot live in the package.** SwiftPM does not compile `.metal` in a package
target — it reports the file as an unhandled resource and produces no metallib. So it sits
in `Shaders/` and is added to the sources of all three app targets, which makes Xcode build
it into each app's `default.metallib` for `ShaderLibrary.default` to find. The consequence
is that the function is absent anywhere there is no app bundle, including the package's own
snapshot tests, and a SwiftUI shader naming a missing function is a hard failure at render
time rather than a no-op. `CRTEffect.isAvailable` checks for the metallib first, and
`tubeFallsBackWhenShaderMissing` asserts that path renders instead of taking the suite down.

**Xcode 26 ships the Metal compiler separately.** Without it the build fails with
`cannot execute tool 'metal' due to missing Metal Toolchain`:

```bash
xcodebuild -downloadComponent MetalToolchain     # ~690 MB, one time
```

The app also holds `isIdleTimerDisabled` while it is active, because the rotation redraws
with no user input and tvOS otherwise counts the whole session as idle and drops the
screen saver over the forecast. It is released whenever the app is not active, so nothing
keeps a device awake in the background.

## Location

Defaults to **the device's own location** via CoreLocation, which works on all
four platforms (tvOS supports one-shot requests). You can pin a place instead by
searching in onboarding or Settings — search uses `CLGeocoder`, so no third-party
geocoding service is involved.

Forecasts are US-only, because they come from the National Weather Service.

## Custom music

Five sources, picked in **Settings → Music → Music source**:

| Source | iOS / iPadOS / macOS | tvOS |
|---|---|---|
| **Bundled** — the four instrumental tracks from upstream | ✅ | ✅ |
| **On this device** — files you import | ✅ | ✗ (no document picker on tvOS) |
| **Music server** — an HTTP URL you host | ✅ | ✅ |
| **Apple Music** — a playlist from your library | ✅ | ✅ (needs a subscription) |
| **iCloud (private)** — synced across your devices | opt-in | opt-in (needs a build flag, see below) |

iCloud is **not offered in a stock build**. `CloudKitMusicStore` is compiled out without
`WS4K_CLOUDKIT`, and enabling it also needs an iCloud container on the signing team — so
without both, selecting it could only ever fail. Rather than list it and report "not
enabled in this build" after the fact, it is filtered out of the picker entirely, and a
preference left pointing at it by an earlier build falls back to bundled music. Apple
Music covers the same "my music on every device I own" job with no container to register.

Supported formats: MP3, M4A, AAC, WAV, AIFF, FLAC, ALAC, CAF.

### Apple Music

Pick any playlist from your own Apple Music library and it plays behind the displays,
including on Apple TV — `MusicLibraryRequest` reaches the library on tvOS 16+, so the
playlist picker works on the TV itself rather than needing a phone to choose on.

Two things to know about what this can and cannot do:

- **The library is per-listener.** MusicKit reads the library of whoever is signed into
  *this* device. A playlist you curate is yours; another person running the app sees
  their own playlists, not yours. There is no way to publish one playlist to everybody.
- **Playback needs an active subscription.** This is a MusicKit rule, not a choice made
  here. The bundled tracks and a music server both work without one, which is why they
  remain the defaults for a free app.

Apple Music tracks are DRM-protected and have no file URL, so `AVPlayer` — which plays
every other source — cannot decode them. `ApplicationMusicPlayer` is queued with the
playlist instead, and it owns the ordering, shuffling and advancing. `MusicPlayer`
forwards transport calls to it and keeps its own track queue empty for that source, so
the two players are never both holding the audio session.

#### Two MusicKit traps on macOS

Both of these cost a debugging session, and neither shows up at compile time:

**Do not ask `MusicLibraryRequest` to sort or filter.** On macOS it is bridged to the
iTunes library, and `MPModeliTunesLibraryRequestOperation` has no implementation for
translating a sort descriptor. It raises `doesNotRecognizeSelector:` — an Objective-C
exception, so the process **aborts** rather than throwing something `try` can catch. The
same code is fine on iOS and tvOS, which is what makes it easy to ship. Fetch unsorted
and sort in Swift.

**Start playback from exactly one place.** Assigning
`ApplicationMusicPlayer.shared.queue` while a previous `play()` is still preparing makes
MusicKit abandon the interrupted one with *"Queue was interrupted by another queue"*
(`MPMusicPlayerControllerErrorDomain` 2) — and when two callers race, both can lose, so
the source silently plays nothing. Choosing a playlist changes two observed settings, so
the host re-queued twice within a second. `MusicPlayer` now refuses overlapping starts
and `AppleMusicStore` chains them; `appleMusicStartsAreNotDoubled` covers it.

Relatedly, `MusicPlayer` resolves `AppleMusicStore.shared` **lazily** and accepts an
injected `AppleMusicControlling`. That store wraps `ApplicationMusicPlayer.shared`, which
is the *system* music player: creating it eagerly in `init` meant the test suite opened an
XPC connection to `itunescloudd` and drove the developer's own music library.

To ship it, the App ID needs the MusicKit service turned on — this is the one step that
cannot be done from the repo:

1. developer.apple.com → **Certificates, Identifiers & Profiles → Identifiers** → your
   App ID → **App Services** → enable **MusicKit**.
2. Rebuild. `NSAppleMusicUsageDescription` is already in all three `Info.plist` files.

Without step 1 the app still builds and signs, but authorisation fails at runtime and
the settings screen reports that access was denied.

### Why iCloud is the recommended path for a free, open-source app

CloudKit **private** database storage counts against each *user's* iCloud quota,
not the developer's. A free app with any number of users therefore costs nothing
to run, there is no server to maintain, and no analytics pipeline exists that
could leak anything. It is also the only sync mechanism tvOS supports — there are
no ubiquity containers or document pickers there.

The music server option stays first-class so that people without iCloud work out
of the box, so an existing ws4kp `/music` folder can be reused as-is, and so
forks do not need your CloudKit container.

### Defining the upload location

**Settings → Music → Music source** with *Music server* selected:

- **Server address** — e.g. `http://nas.local:8080`. *Test connection* reports the
  track count it found.
- **Method** — `Companion server (POST)` for the bundled server, or `WebDAV / PUT`
  for a WebDAV server or object store.
- **Folder on the server** — where uploads land, e.g. `/music/custom`.
- **Access token** — optional bearer token, if your server requires one.
- **Choose files and upload…** — pick audio on iPhone/iPad/Mac and push it to that
  folder, so your Apple TV can stream it.

The app reads `GET {server}/playlist.json` first — the same
`{"availableFiles":[…]}` shape ws4kp's own server returns, so **an existing ws4kp
install works as a music source with no changes**. If that endpoint is absent it
falls back to scraping an autoindex directory listing, which makes a plain static
file host work too.

### Companion server

A dependency-free Node server is included, so it runs on a NAS or a Raspberry Pi
with no install step:

```bash
cd server
node server.mjs
# or
WS4K_PORT=8080 WS4K_MUSIC_DIR=/mnt/music WS4K_TOKEN=your-secret node server.mjs
```

| Endpoint | Purpose |
|---|---|
| `GET /playlist.json` | ws4kp-compatible playlist |
| `GET /music/<file>` | streams a track, with range requests for seeking |
| `POST /upload` | `multipart/form-data`: `file`, optional `path` |
| `PUT /music/<file>` | raw-body upload, for WebDAV-style clients |
| `GET /health` | `{ ok: true, tracks: N }` |

Set `WS4K_TOKEN` to require `Authorization: Bearer <token>` on uploads. Uploaded
filenames are reduced to their basename and resolved against the music directory,
so a client cannot write outside it.

---

## Building

Requires **Xcode 26** or newer, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`), and the Metal toolchain, which Xcode 26 no longer bundles:

```bash
xcodebuild -downloadComponent MetalToolchain     # ~690 MB, one time
```

Without it the app targets fail to build with `cannot execute tool 'metal' due to missing
Metal Toolchain`, because the CRT shader is compiled into each app bundle.

```bash
xcodegen generate        # writes weatherfeels.xcodeproj from project.yml
open weatherfeels.xcodeproj
```

Then pick a scheme: **WeatherStar (iOS)**, **WeatherStar (tvOS)** or
**WeatherStar (macOS)**. The iOS target covers iPhone and iPad.

### Set your bundle identifier and team first

Two settings at the top of `project.yml` drive all three targets:

```yaml
settings:
  base:
    WS4K_BUNDLE_ID: net.hlnd.weatherstar   # a registered identifier you own
    WS4K_TEAM_ID: 2KD5ZL97LH               # your 10-character Team ID
```

Find your own Team ID with:

```bash
security find-identity -v -p codesigning | grep "Apple Development"
```

The bracketed code at the end of the identity name is the Team ID. Simulator builds
work without one; device builds and archives do not.

`WS4K_BUNDLE_ID` must match the **Bundle ID** on the App Store Connect record you are
shipping to, not an arbitrary string. The App Store Connect **SKU** and **Apple ID**
(the numeric app id) are upload-time metadata and are not build settings — you supply
those to Transporter or `xcrun altool`, or they are picked up automatically when
uploading from Xcode's Organizer.

Change them, run `xcodegen generate` again, and every target picks them up.

If Xcode reports:

> The app identifier "…" cannot be registered to your development team because it
> is not available.

that identifier already exists. Usually it is genuinely taken by someone else, but it
also happens when *you* registered it earlier under a different Apple ID or team —
Apple reports both cases identically. Check
developer.apple.com → Certificates, Identifiers & Profiles → Identifiers, then pick a
different string and regenerate.

All three platforms deliberately share one identifier: a single App Store record can
carry iOS, tvOS and macOS builds under the same ID, which is what you want for one
free app. Give them distinct IDs only if you intend separate listings.

`project.yml` is the source of truth; `.xcodeproj` is generated and gitignored, so
there are no project-file merge conflicts.

To run the core tests without Xcode:

```bash
cd Packages/WeatherStarCore
swift test
```

### Archiving all three apps at once

Xcode's Organizer archives one scheme at a time, so a release means three separate
trips through the UI. The three archives are independent, so `Tools/archive.sh` runs
them concurrently:

```bash
Tools/archive.sh                 # archive + export all three
Tools/archive.sh tvOS macOS      # only the platforms named
Tools/archive.sh --upload        # also upload to App Store Connect
```

Each platform gets an export in `build/export-<platform>/` signed for App Store
distribution and a full log at `build/<platform>.log`. iOS and tvOS produce an `.ipa`;
macOS produces a `.pkg` for the Mac App Store — change `method` in the generated
`ExportOptions.plist` to `developer-id` if you want a notarised standalone build.

The `.xcarchive`s go to `~/Library/Developer/Xcode/Archives/<today>/` rather than into
`build/`, because Organizer only lists archives it finds there. That keeps the
no-API-key upload path open: **Window → Organizer**, pick the archive, **Distribute
App**.

To upload from the command line instead you need an App Store Connect API key, since
`altool` no longer accepts an Apple ID password. Create one under **Users and Access →
Integrations → App Store Connect API**, drop the `.p8` in
`~/.appstoreconnect/private_keys/`, then:

```bash
export ASC_KEY_ID=XXXXXXXXXX
export ASC_ISSUER_ID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
Tools/archive.sh --upload
```

### One record, three platforms

iPhone and iPad share a single build — the iOS `.ipa` declares `UIDeviceFamily` `[1, 2]`,
and App Store Connect has no separate iPadOS platform. Whatever is in TestFlight for iOS
is already the iPad build; there is nothing extra to upload.

tvOS and macOS are genuinely separate platforms on the same App Store Connect record,
and each has to be added to the record before its build will be accepted. Until the
platform exists, an upload is rejected with *"no suitable application records were
found"* — which reads like a signing problem but is not one. Add it from the app's page
in App Store Connect (the **+** beside the platform list in the left sidebar), then
upload the matching package.

### Landscape on iPhone and iPad

The displays are a 4:3 or 16:9 canvas, so portrait would letterbox them to a narrow
strip. iPhone declares landscape-only in `Info.plist` and that is the end of it.

iPad cannot: App Store validation rejects a bundle that declares fewer than all four
orientations for iPad, since an iPad app has to accept whatever shape multitasking
gives it. So the plist claims all four and `OrientationLock` in
[`Apps/iOS/WeatherStarApp.swift`](Apps/iOS/WeatherStarApp.swift) returns `.landscape`
at runtime, which is what actually governs rotation. `PackagingTests` asserts the plist
side so a future edit cannot quietly reintroduce the rejection.

### Iterating on layout

Installing to a simulator and waiting for a display to come round takes about a
minute per look, which is far too slow for layout work. Two tools shortcut it.

**Off-device snapshots.** `DisplaySnapshotTests` renders the real SwiftUI display
views at the same 4.5× scale a 4K TV uses and writes PNGs to
`/tmp/ws4k-snapshots` in well under a second:

```bash
swift test --filter DisplaySnapshotTests && open /tmp/ws4k-snapshots
```

**Forcing one display on device.** The rotation decides what is on screen, so to
photograph a specific display, enable only that one:

```bash
DEVICE=<simulator-udid>
xcrun simctl spawn "$DEVICE" defaults write net.weatherstar.app \
    ws4k.enabledDisplays -array current-weather
xcrun simctl launch "$DEVICE" net.weatherstar.app
sleep 35 && xcrun simctl io "$DEVICE" screenshot /tmp/shot.png
```

Column widths are checked against measured text rather than by eye — the Star4000
faces run about 8% wider per character than upstream's fixed-pixel CSS columns
assume, so anything sized by character count overflows.

### Why the resource folder is called `Assets`

`Sources/WeatherStarResources/Assets/` holds the fonts, icons, maps and data tables,
and `Package.swift` copies it with `.copy("Assets")`.

The name matters. A directory called `Resources` at the *root of a bundle* makes
`codesign` treat the bundle as a malformed macOS-style bundle and fail with
`bundle format unrecognized, invalid, or unsuitable` — which breaks every signed iOS
and tvOS build, while unsigned command-line builds pass happily. If you rename it back
to `Resources`, Xcode builds will fail at the CodeSign step for
`WeatherStarCore_WeatherStarResources.bundle`.

### A note on the bundled fonts

`Tools/woff2ttf.py` does more than change container format. As shipped, the
`Star4000 Large` face declares an ascent about 0.18 em *below* where its glyphs
actually draw. Text layout sizes a line box from ascent+descent, so UIKit and
SwiftUI sliced the top off every capital and the degree sign — "88°" lost its
degree, "77" read as "//". A browser never showed this because CSS lets ink
overflow the line box.

The converter raises the ascent to the font's bounding box, which fixes it for
every framework at once instead of needing per-view padding. If you regenerate the
fonts, `TextRenderingTests` fails should that correction go missing.

### Enabling private iCloud music sync

Needs a paid Apple Developer account. The CloudKit code is written but compiled
out by default so the repo builds and runs without a team ID.

1. In `project.yml`, uncomment
   `SWIFT_ACTIVE_COMPILATION_CONDITIONS: WS4K_CLOUDKIT`.
2. Add the iCloud capability to each app target with a CloudKit container
   (e.g. `iCloud.net.weatherstar.app`), and set your development team.
3. Optionally add a `WS4KCloudKitContainer` key to `Info.plist` naming the
   container, so forks can point at their own without touching code.
4. `xcodegen generate` and rebuild.

The record type is `MusicTrack` with fields `title` (String), `fileName` (String)
and `audio` (CKAsset), in the **private** database.

---

## Repository layout

```
Packages/WeatherStarCore/       Swift package — all logic and UI
  Sources/WeatherStarKit/       NWS client, models, units, icons, engine, music
  Sources/WeatherStarUI/        SwiftUI displays, settings, onboarding
  Sources/WeatherStarResources/ fonts, icons, maps, city tables, default music
  Tests/                        100 tests across 16 suites
Apps/{iOS,tvOS,macOS}/          thin app targets: @main + Info.plist
Tools/woff2ttf.py               WOFF → TTF converter (no dependencies)
server/                         companion music server
project.yml                     XcodeGen spec
```

The Star4000 fonts ship upstream as `.woff`, which Core Text cannot load.
`Tools/woff2ttf.py` converts them to `.ttf` using only `zlib` — WOFF 1.0 is an
SFNT with individually deflated tables, so no `fontTools` or `fontforge` needed:

```bash
python3 Tools/woff2ttf.py <out_dir> path/to/*.woff
```

## Controls

| | Next / previous display | Play / pause | Settings |
|---|---|---|---|
| **tvOS** | swipe left / right | Play/Pause button | swipe up, then gear |
| **iOS / iPadOS** | tap for controls | tap for controls | tap for controls |
| **macOS** | ← / → | Space | ⌘, |

## Attribution and licence

- Ported from [netbymatt/ws4kp](https://github.com/netbymatt/ws4kp) by Matt Walsh
  (MIT). Fonts, weather icons, background artwork, music and the generated
  city/station tables are from that project.
- Weather data: [NOAA / National Weather Service](https://www.weather.gov/documentation/services-web-api) (public domain).
- Radar composites: [Iowa Environmental Mesonet](https://mesonet.agron.iastate.edu/).
- Convective outlooks: [NOAA Storm Prediction Center](https://www.spc.noaa.gov/).
- Sun and moon math ported from [SunCalc](https://github.com/mourner/suncalc) (BSD-2-Clause).

MIT licensed. Not affiliated with, endorsed by, or connected to The Weather
Channel or NOAA.
