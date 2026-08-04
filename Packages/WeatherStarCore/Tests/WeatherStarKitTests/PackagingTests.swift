import Foundation
import Testing
import WeatherStarResources
@testable import WeatherStarKit

/// Guards the resource bundle layout.
///
/// These exist because a path bug here fails *silently*: the app still launches, but
/// with no fonts, no weather icons and no city tables. Nothing crashes, so only an
/// explicit check catches it.
@Suite("Resource packaging")
struct PackagingTests {
    @Test("Every resource directory resolves inside the bundle")
    func allDirectoriesResolve() {
        for (directory, found) in WeatherStarResources.verifyPackaging() {
            #expect(found, "resource directory missing: \(directory.rawValue)")
        }
    }

    /// App Store validation rules that only surface on upload, checked against the
    /// source plists here instead.
    ///
    /// These have each cost a rejected upload: a missing `CFBundleIdentifier`, then an
    /// iPad orientation list that App Store Connect refuses because an iPad app must be
    /// able to take any shape multitasking gives it. The rules are static, so there is
    /// no reason to learn about them from a failed submission.
    @Test("The app Info.plist files satisfy App Store validation")
    func infoPlistsValidate() throws {
        // Tests run from the package directory; the app targets live beside it.
        let root = Self.repoRoot

        let requiredKeys = [
            "CFBundleIdentifier", "CFBundleExecutable", "CFBundleName",
            "CFBundleVersion", "CFBundleShortVersionString", "CFBundlePackageType",
        ]

        for platform in ["iOS", "tvOS", "macOS"] {
            let url = root
                .appendingPathComponent("Apps/\(platform)/Info.plist")
            guard let data = try? Data(contentsOf: url) else {
                Issue.record("no Info.plist for \(platform) at \(url.path)")
                continue
            }
            let plist = try #require(
                try PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil
                ) as? [String: Any],
                "\(platform) Info.plist is not a dictionary"
            )

            for key in requiredKeys {
                #expect(plist[key] != nil, "\(platform) Info.plist is missing \(key)")
            }

            // The Mac App Store rejects a package with no category, and the value has
            // to be a real category UTI rather than any string.
            if platform == "macOS" {
                let category = plist["LSApplicationCategoryType"] as? String
                #expect(
                    category?.hasPrefix("public.app-category.") == true,
                    """
                    macOS Info.plist needs LSApplicationCategoryType set to a category \
                    UTI; found \(category ?? "nothing")
                    """
                )
            }

            // An iPad app has to declare all four orientations or the upload is
            // rejected; the landscape restriction is applied at runtime instead.
            if let iPad = plist["UISupportedInterfaceOrientations~ipad"] as? [String] {
                let all = Set([
                    "UIInterfaceOrientationPortrait",
                    "UIInterfaceOrientationPortraitUpsideDown",
                    "UIInterfaceOrientationLandscapeLeft",
                    "UIInterfaceOrientationLandscapeRight",
                ])
                #expect(
                    Set(iPad) == all,
                    """
                    \(platform) declares \(iPad.count) iPad orientations; App Store \
                    validation requires all four for iPad multitasking
                    """
                )
            }
        }
    }

    /// Every tvOS image asset has to carry both scales, and the 2x image has to be
    /// exactly twice the 1x.
    ///
    /// A catalog with only 1x builds, installs and runs — the rejection comes from App
    /// Store Connect after the upload finishes:
    ///
    ///     Invalid Image Asset. The image asset 'App Icon' is missing an image for the
    ///     background layer with a scale value of '2'.
    ///
    /// Both halves matter. A missing scale is the rejection above; a 2x that is not
    /// double is accepted and then renders at the wrong size on a 4K Apple TV.
    @Test("Every tvOS image asset provides both 1x and 2x")
    func tvOSAssetsHaveBothScales() throws {
        let brand = Self.repoRoot
            .appendingPathComponent("Apps/tvOS/Assets.xcassets")
            .appendingPathComponent("App Icon & Top Shelf Image.brandassets")

        let enumerated = FileManager.default.enumerator(
            at: brand, includingPropertiesForKeys: nil
        )
        let imagesets = (enumerated?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "imageset" }

        #expect(imagesets.count >= 6, "found only \(imagesets.count) tvOS imagesets")

        for imageset in imagesets {
            // Every image stack layer holds a "Content.imageset", so the leaf name alone
            // would not say which layer failed. Report the path from the catalog down.
            let name = imageset.path
                .components(separatedBy: ".brandassets/").last ?? imageset.lastPathComponent
            let manifest = imageset.appendingPathComponent("Contents.json")
            guard let data = try? Data(contentsOf: manifest),
                  let json = try? JSONSerialization.jsonObject(with: data)
                      as? [String: Any],
                  let images = json["images"] as? [[String: Any]]
            else {
                Issue.record("\(name) has no readable Contents.json")
                continue
            }

            var sizes: [String: (width: Int, height: Int)] = [:]
            for image in images {
                guard let scale = image["scale"] as? String,
                      let filename = image["filename"] as? String
                else { continue }
                let file = imageset.appendingPathComponent(filename)
                guard let size = Self.pngSize(at: file) else {
                    Issue.record("\(name): \(filename) (\(scale)) is missing or not a PNG")
                    continue
                }
                sizes[scale] = size
            }

            guard let oneX = sizes["1x"] else {
                Issue.record("\(name) declares no 1x image")
                continue
            }
            guard let twoX = sizes["2x"] else {
                Issue.record("\(name) declares no 2x image — App Store Connect rejects this")
                continue
            }
            #expect(
                twoX.width == oneX.width * 2 && twoX.height == oneX.height * 2,
                """
                \(name): 2x is \(twoX.width)x\(twoX.height), \
                expected \(oneX.width * 2)x\(oneX.height * 2)
                """
            )
        }
    }

    /// Width and height straight out of a PNG's IHDR chunk.
    ///
    /// Hand-parsed rather than going through ImageIO so this stays usable wherever the
    /// tests run: the header is at a fixed offset and both fields are big-endian.
    private static func pngSize(at url: URL) -> (width: Int, height: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 24), header.count == 24 else {
            return nil
        }
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard Array(header[0..<8]) == signature else { return nil }

        func be32(_ offset: Int) -> Int {
            header[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
        }
        return (be32(16), be32(20))
    }

    /// Repository root, derived from this file's location.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // WeatherStarKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // WeatherStarCore
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // repo root
    }

    @Test("All four Star4000 fonts are present")
    func fontsPresent() {
        let expected = [
            "Star4000.ttf",
            "Star4000 Small.ttf",
            "Star4000 Large.ttf",
            "Star4000 Extended.ttf",
        ]
        for name in expected {
            #expect(
                WeatherStarResources.url(name, in: .fonts) != nil,
                "missing font \(name)"
            )
        }
    }

    @Test("The converted fonts are real SFNT files with glyph outlines")
    func fontsAreValidOutlineFonts() throws {
        // The WOFF→TTF conversion is done by a script in Tools/, so verify the output
        // is loadable and outline-based rather than trusting the conversion blindly.
        for name in ["Star4000.ttf", "Star4000 Small.ttf"] {
            let url = try #require(WeatherStarResources.url(name, in: .fonts))
            let data = try Data(contentsOf: url)
            // A TrueType file starts with the version tag 0x00010000.
            #expect(data.prefix(4) == Data([0x00, 0x01, 0x00, 0x00]), "\(name) is not TrueType")
            // The 'glyf' table must be present for the font to scale as vector art.
            #expect(
                data.range(of: Data("glyf".utf8)) != nil,
                "\(name) has no glyf table, so it would not scale cleanly"
            )
        }
    }

    @Test("Icon sets contain the expected number of files")
    func iconSetsPopulated() {
        #expect(WeatherStarResources.contents(of: .currentConditionIcons).count >= 20)
        #expect(WeatherStarResources.contents(of: .regionalMapIcons).count >= 30)
        #expect(WeatherStarResources.contents(of: .moonPhaseIcons).count >= 4)
    }

    @Test("The bundled default music is present and playable by extension")
    func bundledMusicPresent() {
        let tracks = MusicStorage.bundledTracks()
        #expect(tracks.count == 4, "expected the four upstream tracks")
        #expect(tracks.allSatisfy { SupportedAudio.isSupported($0.url) })
        #expect(tracks.allSatisfy { $0.source == .bundled })
        // Titles come from the filename with the extension stripped.
        #expect(tracks.contains { $0.title == "Crisp day" })
    }

    @Test("The radar and regional base maps are present")
    func mapsPresent() {
        #expect(WeatherStarResources.url("basemap.webp", in: .maps) != nil)
    }

    @Test("The generated data tables are present and parse")
    func dataTablesPresent() {
        for name in ["stations.json", "travelcities.json", "regionalcities.json"] {
            #expect(WeatherStarResources.url(name, in: .data) != nil, "missing \(name)")
        }
        // Parsing is covered elsewhere; this asserts the files reached the bundle.
        #expect(!BundledData.stations.isEmpty)
        #expect(!BundledData.travelCities.isEmpty)
        #expect(!BundledData.regionalCities.isEmpty)
    }

    @Test("A missing resource returns nil rather than trapping")
    func missingResourceIsNil() {
        #expect(WeatherStarResources.url("does-not-exist.gif", in: .currentConditionIcons) == nil)
    }
}

@Suite("Music source resolution")
struct MusicSourceTests {
    @Test("Track titles strip the extension and upstream's separators")
    func trackTitles() {
        #expect(
            MusicTrack.displayTitle(from: URL(fileURLWithPath: "/m/Rolling Clouds.mp3"))
                == "Rolling Clouds"
        )
        // Percent-encoded names arrive this way from a remote playlist.
        #expect(
            MusicTrack.displayTitle(from: URL(string: "http://x/Catch%20the%20Sun.mp3")!)
                == "Catch the Sun"
        )
    }

    @Test("Only audio extensions are accepted")
    func supportedExtensions() {
        #expect(SupportedAudio.isSupported(URL(fileURLWithPath: "/a/song.mp3")))
        #expect(SupportedAudio.isSupported(URL(fileURLWithPath: "/a/song.FLAC")))
        #expect(!SupportedAudio.isSupported(URL(fileURLWithPath: "/a/notes.txt")))
        #expect(!SupportedAudio.isSupported(URL(fileURLWithPath: "/a/cover.jpg")))
    }

    @Test("Local file import is offered everywhere except tvOS")
    func platformAvailability() {
        // tvOS has no document picker, so that source must not be offered there.
        #if os(tvOS)
        #expect(!MusicSourceKind.localFiles.isAvailableOnThisPlatform)
        #expect(!MusicSourceKind.availableCases.contains(.localFiles))
        #else
        #expect(MusicSourceKind.localFiles.isAvailableOnThisPlatform)
        #endif
        // These work on every platform unconditionally. iCloud does not — it depends on
        // the build carrying the CloudKit flag, which `iCloudHiddenWithoutCloudKit`
        // covers.
        #expect(MusicSourceKind.remoteServer.isAvailableOnThisPlatform)
        #expect(MusicSourceKind.bundled.isAvailableOnThisPlatform)
        #expect(MusicSourceKind.appleMusic.isAvailableOnThisPlatform)
    }

    @Test("The playlist format matches what ws4kp's server returns")
    func playlistDecoding() throws {
        // Decoding this exact shape is what lets an existing ws4kp install be used
        // as a music source with no changes.
        let json = #"{"availableFiles":["Catch the Sun.mp3","default/Crisp day.mp3"]}"#
        let playlist = try JSONDecoder().decode(RemotePlaylist.self, from: Data(json.utf8))
        #expect(playlist.availableFiles.count == 2)
        #expect(playlist.availableFiles[1] == "default/Crisp day.mp3")
    }
}

@Suite("Music player")
@MainActor
struct MusicPlayerTests {
    /// Regression test: clamping used to be done by assigning to the property inside
    /// its own `didSet`, which under `@Observable` recurses until the stack overflows.
    /// Reaching the assertion at all proves it no longer recurses.
    @Test("Volume clamps to 0...1 without recursing")
    func volumeClamping() {
        let player = MusicPlayer()
        player.volume = 5
        #expect(player.volume == 1)
        player.volume = -3
        #expect(player.volume == 0)
        player.volume = 0.4
        #expect(player.volume == 0.4)
    }

    @Test("An empty queue reports nothing playing and ignores transport commands")
    func emptyQueue() {
        let player = MusicPlayer()
        #expect(player.currentTrack == nil)
        #expect(player.currentTrackTitle == "Not playing")

        // These must be no-ops rather than trapping on an empty array.
        player.play()
        player.next()
        player.previous()
        #expect(!player.isPlaying)
    }

    /// Records what `MusicPlayer` asks of the Apple Music backend.
    ///
    /// The default backend is `ApplicationMusicPlayer.shared`, which is the *system*
    /// music player — an earlier version of this test drove it for real and opened an
    /// XPC connection to `itunescloudd` on the machine running the suite. Nothing here
    /// may touch the developer's music library.
    @MainActor
    private final class AppleMusicSpy: AppleMusicControlling {
        var currentTitle: String? = "Spy Track"
        var played: [(playlist: String, shuffle: Bool)] = []
        var pauseCount = 0
        var stopCount = 0

        func play(playlistID: String, shuffle: Bool) async throws {
            played.append((playlistID, shuffle))
        }
        func pause() { pauseCount += 1 }
        func stop() { stopCount += 1 }
        func skipToNext() async throws {}
        func skipToPrevious() async throws {}
    }

    /// Apple Music and file playback use two different players, so selecting one must
    /// fully release the other — otherwise both hold the audio session and you get two
    /// things playing at once.
    @Test("Switching between Apple Music and files releases the other player")
    func appleMusicSwitchesExclusively() {
        let spy = AppleMusicSpy()
        let player = MusicPlayer(appleMusic: spy)
        let tracks = (1...2).map {
            MusicTrack(url: URL(fileURLWithPath: "/m/Track \($0).mp3"), source: .bundled)
        }

        player.load(tracks: tracks, shuffle: false)
        #expect(player.appleMusicPlaylistID == nil)
        #expect(player.queue.count == 2)
        #expect(spy.stopCount == 0, "the Apple Music player was touched for a file source")

        player.loadAppleMusicPlaylist(id: "p.abc123", shuffle: true)
        #expect(player.appleMusicPlaylistID == "p.abc123")
        // The file queue is emptied: MusicKit owns the ordering for this source, so a
        // stale queue here would make `currentTrack` disagree with what is audible.
        #expect(player.queue.isEmpty)
        #expect(player.currentTrackTitle == "Spy Track")

        // Back to files: the Apple Music player must actually be told to stop, not just
        // be left behind still holding the audio session.
        player.load(tracks: tracks, shuffle: false)
        #expect(spy.stopCount == 1)
        #expect(player.appleMusicPlaylistID == nil)
        #expect(player.queue.count == 2)
        #expect(player.currentTrackTitle == "Track 1")
    }

    /// Choosing a playlist changes two observed settings, so the host re-queues twice in
    /// quick succession. On a real Mac that produced two `ApplicationMusicPlayer` queue
    /// assignments 0.8s apart and MusicKit failed both with
    /// "Queue was interrupted by another queue" (MPMusicPlayerControllerErrorDomain 2) —
    /// the source appeared to do nothing at all.
    @Test("Two rapid starts do not race the Apple Music queue")
    func appleMusicStartsAreNotDoubled() async throws {
        let spy = AppleMusicSpy()
        let player = MusicPlayer(appleMusic: spy)

        player.loadAppleMusicPlaylist(id: "p.race", shuffle: true)
        player.play()
        player.play()

        // Let the in-flight start settle.
        try await Task.sleep(for: .milliseconds(100))
        #expect(
            spy.played.count == 1,
            "asked the Apple Music player to start \(spy.played.count) times, not once"
        )
        #expect(spy.played.first?.playlist == "p.race")
        #expect(spy.played.first?.shuffle == true)

        // The guard must clear, or nothing can ever be started again.
        player.play()
        try await Task.sleep(for: .milliseconds(100))
        #expect(spy.played.count == 2, "the one-start guard never released")
    }

    @Test("Only the Apple Music source routes to ApplicationMusicPlayer")
    func appleMusicRouting() {
        for source in MusicSourceKind.allCases {
            #expect(
                source.usesAppleMusicPlayer == (source == .appleMusic),
                "\(source) routed to the wrong player"
            )
        }
    }

    /// Apple Music is offered on Apple TV, unlike local file import: `MusicLibraryRequest`
    /// reads the listener's playlists on tvOS 16+, so the picker works on the TV itself.
    @Test("Apple Music is available on every platform")
    func appleMusicAvailableEverywhere() {
        #expect(MusicSourceKind.availableCases.contains(.appleMusic))
    }

    /// iCloud must not be offered unless the build can actually use it.
    ///
    /// It was listed in build 2 while `CloudKitMusicStore` was compiled out, so it could
    /// be selected and then never produce a track — which looks like music being broken
    /// rather than a source being unavailable.
    @Test("iCloud is only offered when CloudKit is compiled in")
    func iCloudHiddenWithoutCloudKit() {
        #if WS4K_CLOUDKIT
        #expect(MusicSourceKind.availableCases.contains(.iCloud))
        #else
        #expect(!MusicSourceKind.availableCases.contains(.iCloud))
        #endif
    }

    /// A persisted source that is no longer available has to fall back, or a listener who
    /// picked iCloud in an earlier build stays stuck on it with no way back through the
    /// picker — the option is not shown any more.
    @Test("An unavailable persisted source falls back to bundled")
    func unavailableSourceFallsBack() {
        let suite = "ws4k.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!

        // Write iCloud directly, the way an older build would have left it.
        defaults.set(try! JSONEncoder().encode(MusicSourceKind.iCloud), forKey: "ws4k.musicSource")

        let settings = AppSettings(defaults: defaults)
        #if WS4K_CLOUDKIT
        #expect(settings.musicSource == .iCloud)
        #else
        #expect(settings.musicSource == .bundled)
        #endif
    }

    @Test("Loading in order preserves the track sequence")
    func loadInOrder() {
        let player = MusicPlayer()
        let tracks = (1...3).map {
            MusicTrack(url: URL(fileURLWithPath: "/m/Track \($0).mp3"), source: .bundled)
        }
        player.load(tracks: tracks, shuffle: false)
        #expect(player.queue.map(\.title) == ["Track 1", "Track 2", "Track 3"])
        #expect(player.currentTrack?.title == "Track 1")
    }

    @Test("Shuffling keeps every track exactly once")
    func shufflePreservesTracks() {
        let player = MusicPlayer()
        let tracks = (1...20).map {
            MusicTrack(url: URL(fileURLWithPath: "/m/Track \($0).mp3"), source: .bundled)
        }
        player.load(tracks: tracks, shuffle: true)
        #expect(Set(player.queue.map(\.id)) == Set(tracks.map(\.id)))
        #expect(player.queue.count == tracks.count)
    }

    @Test("Reshuffling leaves the current track playing at the front")
    func reshuffleKeepsCurrent() {
        let player = MusicPlayer()
        let tracks = (1...10).map {
            MusicTrack(url: URL(fileURLWithPath: "/m/Track \($0).mp3"), source: .bundled)
        }
        player.load(tracks: tracks, shuffle: false)
        let current = player.currentTrack

        player.reshuffle()
        #expect(player.currentTrack == current, "must not interrupt the current track")
        #expect(player.queue.count == tracks.count)
        #expect(Set(player.queue.map(\.id)) == Set(tracks.map(\.id)))
    }
}

@Suite("Settings persistence")
@MainActor
struct SettingsTests {
    /// An isolated defaults domain, so tests never touch the real app's settings.
    private func makeSettings() -> (AppSettings, UserDefaults) {
        let suite = "ws4k.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (AppSettings(defaults: defaults), defaults)
    }

    @Test("Defaults are the documented first-run values")
    func firstRunDefaults() {
        let (settings, _) = makeSettings()
        #expect(settings.units == .us)
        #expect(settings.layoutMode == .auto)
        #expect(settings.scanlines == .off)
        #expect(settings.speed == .normal)
        // Device location is the default, per the product decision.
        #expect(settings.locationMode == .device)
        #expect(!settings.hasCompletedOnboarding)
        #expect(settings.musicSource == .bundled)
        #expect(settings.enabledDisplayIDs.count == DisplayIdentifier.defaultEnabled.count)
    }

    @Test("Values survive a reload from the same defaults domain")
    func roundTrip() {
        let (settings, defaults) = makeSettings()
        settings.units = .si
        settings.layoutMode = .wide
        settings.scanlines = .medium
        settings.hasCompletedOnboarding = true
        settings.locationMode = .manual
        settings.savedLocation = SavedLocation(
            name: "Orlando, FL", latitude: 28.5383, longitude: -81.3792
        )
        settings.remoteMusicURLString = "http://nas.local:8080"
        settings.musicSource = .appleMusic
        settings.appleMusicPlaylistID = "p.LV0kdLA"
        settings.appleMusicPlaylistName = "Rainy Day Instrumentals"

        // A fresh instance reading the same domain must see all of it.
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.units == .si)
        #expect(reloaded.layoutMode == .wide)
        #expect(reloaded.scanlines == .medium)
        #expect(reloaded.hasCompletedOnboarding)
        #expect(reloaded.locationMode == .manual)
        #expect(reloaded.savedLocation?.name == "Orlando, FL")
        #expect(reloaded.remoteMusicURL?.host() == "nas.local")
        #expect(reloaded.musicSource == .appleMusic)
        #expect(reloaded.appleMusicPlaylistID == "p.LV0kdLA")
        // The name is persisted alongside the identifier so the settings screen can name
        // the chosen playlist before MusicKit has been authorised.
        #expect(reloaded.appleMusicPlaylistName == "Rainy Day Instrumentals")
    }

    @Test("The refresh interval is clamped to a range the NWS API tolerates")
    func refreshClamping() {
        let (settings, _) = makeSettings()
        settings.refreshMinutes = 1
        #expect(settings.refreshMinutes == 5)
        settings.refreshMinutes = 600
        #expect(settings.refreshMinutes == 60)
        settings.refreshMinutes = 15
        #expect(settings.refreshInterval == 900)
    }

    @Test("Volume is clamped to 0...1")
    func volumeClamping() {
        let (settings, _) = makeSettings()
        settings.musicVolume = 5
        #expect(settings.musicVolume == 1)
        settings.musicVolume = -1
        #expect(settings.musicVolume == 0)
    }

    @Test("A blank or malformed server address yields no URL")
    func invalidServerURL() {
        let (settings, _) = makeSettings()
        settings.remoteMusicURLString = "   "
        #expect(settings.remoteMusicURL == nil)
        settings.remoteMusicURLString = "nas.local"  // no scheme
        #expect(settings.remoteMusicURL == nil)
        settings.remoteMusicURLString = "https://nas.local"
        #expect(settings.remoteMusicURL != nil)
    }

    @Test("Toggling a display in the rotation persists")
    func displayToggles() {
        let (settings, defaults) = makeSettings()
        #expect(settings.isEnabled(.currentWeather))
        #expect(!settings.isEnabled(.hourly))

        settings.setEnabled(true, for: .hourly)
        settings.setEnabled(false, for: .currentWeather)

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.isEnabled(.hourly))
        #expect(!reloaded.isEnabled(.currentWeather))
    }

    @Test("Recent locations de-duplicate and stay bounded")
    func recentLocations() {
        let (settings, _) = makeSettings()
        for index in 0..<12 {
            settings.rememberRecent(
                SavedLocation(name: "City \(index)", latitude: Double(index), longitude: 0)
            )
        }
        #expect(settings.recentLocations.count == 8, "list must be trimmed")
        #expect(settings.recentLocations.first?.name == "City 11", "most recent first")

        // Re-adding an existing place moves it to the front without duplicating.
        let existing = settings.recentLocations[3]
        settings.rememberRecent(existing)
        #expect(settings.recentLocations.first == existing)
        #expect(settings.recentLocations.filter { $0 == existing }.count == 1)
    }
}
