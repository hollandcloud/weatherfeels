import Foundation
import Observation

/// How the fixed WeatherStar canvas is fitted to the screen.
///
/// The original hardware was 4:3. Upstream added `wide` (854×480) and `portrait`
/// (640×1137) variants with their own artwork; we keep those as design spaces and
/// scale them to whatever the display actually is, so a 4K TV fills edge to edge.
public enum LayoutMode: String, Codable, Sendable, CaseIterable {
    /// Pick the design space that best matches the container's aspect ratio.
    case auto
    /// Authentic 640×480, pillarboxed on a widescreen display.
    case standard
    /// 854×480 widescreen, fills a 16:9 TV.
    case wide
    /// 640×1137 tall layout for phones held upright.
    case portrait

    public var displayName: String {
        switch self {
        case .auto: "Automatic"
        case .standard: "Standard (4:3)"
        case .wide: "Widescreen (16:9)"
        case .portrait: "Portrait"
        }
    }
}

/// How the cabinet around the picture is finished.
///
/// Only the cabinet changes. An earlier version also built a room around it — a lit wall,
/// a surface, coloured gels — and it was the wrong idea: a scene competes with the picture
/// instead of presenting it, and the picture is the whole point. What is left is the set
/// itself, on black, in whichever material suits.
public enum TelevisionFinish: String, Codable, Sendable, CaseIterable {
    /// Neutral grey, the colour of rack and edit-suite equipment.
    case monitor
    /// Wood veneer, as domestic sets were finished into the eighties.
    case woodgrain
    /// Black plastic, the portable set of the nineties.
    case black

    public var displayName: String {
        switch self {
        case .monitor: "Studio monitor"
        case .woodgrain: "Wood veneer"
        case .black: "Black portable"
        }
    }

    public var detail: String {
        switch self {
        case .monitor: "Neutral grey, the colour of edit-suite equipment."
        case .woodgrain: "Wood veneer, the way a console set in a living room was finished."
        case .black: "Moulded black plastic, the portable set of the nineties."
        }
    }
}

/// Scanline overlay density. Thickness is derived from the output scale at draw
/// time so the lines never moiré, however far the canvas is scaled up.
public enum ScanlineMode: String, Codable, Sendable, CaseIterable {
    case off
    case hairline
    case thin
    case medium
    case thick

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .hairline: "Hairline"
        case .thin: "Thin"
        case .medium: "Medium"
        case .thick: "Thick"
        }
    }
}

/// How much of a cathode-ray tube to simulate over the displays.
public enum ScreenEffect: String, Codable, Sendable, CaseIterable {
    /// Just the static scanline overlay from `ScanlineMode`.
    case plain
    /// Scanlines that drift, plus the roll bar of a CRT filmed off-screen. Drawn in
    /// `Canvas`, so it works everywhere.
    case animated
    /// The full tube: barrel curvature, phosphor bloom, convergence fringing and corner
    /// falloff, through the `StarCRT` Metal shader. Falls back to `animated` where the
    /// shader is unavailable.
    case tube

    public var displayName: String {
        switch self {
        case .plain: "Static"
        case .animated: "Animated"
        case .tube: "CRT tube"
        }
    }

    public var detail: String {
        switch self {
        case .plain:
            "Plain scanlines, drawn once."
        case .animated:
            "Scanlines drift and a soft roll bar creeps down the screen."
        case .tube:
            "Curved glass, phosphor bloom and colour fringing, drawn on the GPU."
        }
    }

}

/// Playback speed multiplier applied to every display's dwell time.
public enum PlaybackSpeed: String, Codable, Sendable, CaseIterable {
    case fast
    case normal
    case slow
    case verySlow

    public var multiplier: Double {
        switch self {
        case .fast: 0.5
        case .normal: 1.0
        case .slow: 1.5
        case .verySlow: 2.0
        }
    }

    public var displayName: String {
        switch self {
        case .fast: "Fast"
        case .normal: "Normal"
        case .slow: "Slow"
        case .verySlow: "Very Slow"
        }
    }
}

/// User-facing configuration, persisted to `UserDefaults`.
///
/// Reads are cheap and synchronous; every mutation writes through immediately so
/// the tvOS app survives being jetsammed without losing the user's setup.
@MainActor
@Observable
public final class AppSettings {
    public static let shared = AppSettings()

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        units = defaults.decoded(Key.units, default: .us)
        layoutMode = defaults.decoded(Key.layoutMode, default: .auto)
        // The retro treatment is the point of the app on a handheld, where the screen is
        // close to the eye and the tube reads as intended. A Mac window and an Apple TV
        // are both looked at from further away and are more often left running in the
        // corner of a room, so those stay clean unless asked otherwise.
        #if os(iOS)
        scanlines = defaults.decoded(Key.scanlines, default: .medium)
        #else
        scanlines = defaults.decoded(Key.scanlines, default: .off)
        #endif
        speed = defaults.decoded(Key.speed, default: .normal)
        storedRefreshMinutes = min(max(defaults.value(forKey: Key.refreshMinutes) as? Int ?? 10, 5), 60)
        clockSeconds = defaults.bool(forKey: Key.clockSeconds, default: true)
        // No capability check here: an unsupported GPU is handled by the render path
        // falling back to the drawn overlay, so a stored `.tube` costs nothing.
        #if os(iOS)
        screenEffect = defaults.decoded(Key.screenEffect, default: .tube)
        #else
        screenEffect = defaults.decoded(Key.screenEffect, default: .plain)
        #endif
        televisionFinish = defaults.decoded(Key.televisionFinish, default: .monitor)
        televisionInLandscape = defaults.bool(Key.televisionInLandscape, default: false)
        // Defaults on only for Apple TV. A television is the panel at risk of burn-in and
        // the device most likely to be left showing this for hours; nudging a phone or a
        // Mac window around would be noise for no benefit.
        #if os(tvOS)
        burnInProtection = defaults.bool(forKey: Key.burnInProtection, default: true)
        #else
        burnInProtection = defaults.bool(forKey: Key.burnInProtection, default: false)
        #endif
        enabledDisplayIDs = Set(
            defaults.stringArray(forKey: Key.enabledDisplays)
                ?? DisplayIdentifier.defaultEnabled.map(\.rawValue)
        )
        locationMode = defaults.decoded(Key.locationMode, default: .device)
        savedLocation = defaults.decoded(Key.savedLocation, default: nil)
        recentLocations = defaults.decoded(Key.recentLocations, default: [])
        hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding, default: false)
        // A source chosen by an earlier build can stop being available: iCloud once the
        // build ships without the CloudKit flag, or local files if the same preferences
        // reach an Apple TV. Without this the app stays pointed at a source that can
        // never return a track, and the only symptom is that music never starts.
        //
        // Resolved before the assignment rather than corrected after it: writing to an
        // `@Observable` property twice in `init` fails to compile, because the generated
        // `didSet` cannot run until every stored property is initialised.
        let storedSource = defaults.decoded(Key.musicSource, default: MusicSourceKind.bundled)
        musicSource = storedSource.isAvailableOnThisPlatform ? storedSource : .bundled
        storedMusicVolume = min(max(defaults.value(forKey: Key.musicVolume) as? Double ?? 0.75, 0), 1)
        musicEnabled = defaults.bool(forKey: Key.musicEnabled, default: false)
        musicShuffle = defaults.bool(forKey: Key.musicShuffle, default: true)
        appleMusicPlaylistID = defaults.string(forKey: Key.appleMusicPlaylistID)
        appleMusicPlaylistName = defaults.string(forKey: Key.appleMusicPlaylistName)
        remoteMusicURLString = defaults.string(forKey: Key.remoteMusicURL) ?? ""
        uploadPath = defaults.string(forKey: Key.uploadPath) ?? "/music"
        uploadToken = defaults.string(forKey: Key.uploadToken) ?? ""
    }

    // MARK: - Display

    public var units: UnitSystem { didSet { defaults.encode(units, Key.units) } }
    public var layoutMode: LayoutMode { didSet { defaults.encode(layoutMode, Key.layoutMode) } }
    public var televisionFinish: TelevisionFinish {
        didSet { defaults.encode(televisionFinish, Key.televisionFinish) }
    }
    /// Whether the cabinet is also drawn on a screen wider than it is tall.
    ///
    /// Off by default, because landscape is the shape the picture was drawn for and
    /// filling the screen with it is the better default. On, the set appears in both
    /// orientations for anyone who wants the object rather than the picture.
    public var televisionInLandscape: Bool {
        didSet { defaults.set(televisionInLandscape, forKey: Key.televisionInLandscape) }
    }
    public var scanlines: ScanlineMode { didSet { defaults.encode(scanlines, Key.scanlines) } }
    public var speed: PlaybackSpeed { didSet { defaults.encode(speed, Key.speed) } }
    public var clockSeconds: Bool { didSet { defaults.set(clockSeconds, forKey: Key.clockSeconds) } }

    /// How much CRT to simulate. Anything beyond `.plain` redraws every frame, so the
    /// default stays static.
    public var screenEffect: ScreenEffect {
        didSet { defaults.encode(screenEffect, Key.screenEffect) }
    }

    /// Walk the canvas a few points around its centre to avoid burning in the header,
    /// logo and clock. See `BurnInShift`.
    public var burnInProtection: Bool {
        didSet { defaults.set(burnInProtection, forKey: Key.burnInProtection) }
    }

    // Clamped properties use a private store plus a computed accessor rather than
    // assigning to themselves inside `didSet`. Under `@Observable` a self-assignment
    // in an observer re-enters the generated setter and recurses until the stack
    // overflows, so the clamping has to happen before the store is written.
    private var storedRefreshMinutes: Int
    private var storedMusicVolume: Double

    /// How often data is silently refreshed, clamped to a range the NWS API tolerates.
    public var refreshMinutes: Int {
        get { storedRefreshMinutes }
        set {
            storedRefreshMinutes = min(max(newValue, 5), 60)
            defaults.set(storedRefreshMinutes, forKey: Key.refreshMinutes)
        }
    }

    public var refreshInterval: TimeInterval { TimeInterval(refreshMinutes * 60) }

    // MARK: - Displays in rotation

    public var enabledDisplayIDs: Set<String> {
        didSet {
            defaults.set(Array(enabledDisplayIDs).sorted(), forKey: Key.enabledDisplays)
        }
    }

    public func isEnabled(_ display: DisplayIdentifier) -> Bool {
        enabledDisplayIDs.contains(display.rawValue)
    }

    public func setEnabled(_ enabled: Bool, for display: DisplayIdentifier) {
        if enabled {
            enabledDisplayIDs.insert(display.rawValue)
        } else {
            enabledDisplayIDs.remove(display.rawValue)
        }
    }

    // MARK: - Onboarding

    /// Gates the first-run flow. Set once the user finishes (or skips) onboarding.
    public var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }

    // MARK: - Location

    /// Defaults to following the device's location; the user can pin a place instead.
    public var locationMode: LocationMode {
        didSet { defaults.encode(locationMode, Key.locationMode) }
    }

    /// The manually chosen place, and also a cache of the last resolved device fix so
    /// the app can draw something immediately at launch while a new fix is acquired.
    public var savedLocation: SavedLocation? {
        didSet { defaults.encode(savedLocation, Key.savedLocation) }
    }

    /// Recently used places, most recent first, for quick switching.
    public var recentLocations: [SavedLocation] {
        didSet { defaults.encode(recentLocations, Key.recentLocations) }
    }

    private static let maximumRecents = 8

    /// Record a place as recently used, de-duplicating and trimming the list.
    public func rememberRecent(_ location: SavedLocation) {
        var updated = recentLocations.filter { $0.id != location.id }
        updated.insert(location, at: 0)
        recentLocations = Array(updated.prefix(Self.maximumRecents))
    }

    // MARK: - Music

    public var musicSource: MusicSourceKind {
        didSet { defaults.encode(musicSource, Key.musicSource) }
    }

    public var musicEnabled: Bool { didSet { defaults.set(musicEnabled, forKey: Key.musicEnabled) } }
    public var musicShuffle: Bool { didSet { defaults.set(musicShuffle, forKey: Key.musicShuffle) } }

    /// Identifier of the chosen Apple Music library playlist.
    ///
    /// Stored per device rather than synced: an Apple Music library belongs to whoever
    /// is signed into this device, so a playlist identifier from one account means
    /// nothing on another.
    public var appleMusicPlaylistID: String? {
        didSet { defaults.set(appleMusicPlaylistID, forKey: Key.appleMusicPlaylistID) }
    }

    /// Display name of that playlist, kept so settings can show it without a round trip
    /// to MusicKit before authorisation has been granted.
    public var appleMusicPlaylistName: String? {
        didSet { defaults.set(appleMusicPlaylistName, forKey: Key.appleMusicPlaylistName) }
    }

    public var musicVolume: Double {
        get { storedMusicVolume }
        set {
            storedMusicVolume = min(max(newValue, 0), 1)
            defaults.set(storedMusicVolume, forKey: Key.musicVolume)
        }
    }

    /// Base URL of a server hosting music, e.g. `http://nas.local:8080`.
    /// Compatible with an upstream ws4kp install, which serves `/playlist.json`.
    public var remoteMusicURLString: String {
        didSet { defaults.set(remoteMusicURLString, forKey: Key.remoteMusicURL) }
    }

    public var remoteMusicURL: URL? {
        let trimmed = remoteMusicURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil else { return nil }
        return url
    }

    /// Directory on the remote server that uploads are written to.
    public var uploadPath: String { didSet { defaults.set(uploadPath, forKey: Key.uploadPath) } }

    /// Optional bearer token sent with uploads, for a server that requires one.
    public var uploadToken: String { didSet { defaults.set(uploadToken, forKey: Key.uploadToken) } }

}

/// `UserDefaults` keys. Declared outside `AppSettings` so they stay non-isolated —
/// nested in a `@MainActor` type they would inherit its isolation and could not be
/// referenced from the class's own property initializers.
private enum Key {
    private static let prefix = "ws4k."

    static let units = prefix + "units"
    static let layoutMode = prefix + "layoutMode"
    static let televisionFinish = prefix + "televisionFinish"
    static let televisionInLandscape = prefix + "televisionInLandscape"
    static let scanlines = prefix + "scanlines"
    static let speed = prefix + "speed"
    static let refreshMinutes = prefix + "refreshMinutes"
    static let clockSeconds = prefix + "clockSeconds"
    static let screenEffect = prefix + "screenEffect"
    static let burnInProtection = prefix + "burnInProtection"
    static let enabledDisplays = prefix + "enabledDisplays"
    static let hasCompletedOnboarding = prefix + "hasCompletedOnboarding"
    static let locationMode = prefix + "locationMode"
    static let savedLocation = prefix + "savedLocation"
    static let recentLocations = prefix + "recentLocations"
    static let musicSource = prefix + "musicSource"
    static let musicVolume = prefix + "musicVolume"
    static let musicEnabled = prefix + "musicEnabled"
    static let musicShuffle = prefix + "musicShuffle"
    static let appleMusicPlaylistID = prefix + "appleMusicPlaylistID"
    static let appleMusicPlaylistName = prefix + "appleMusicPlaylistName"
    static let remoteMusicURL = prefix + "remoteMusicURL"
    static let uploadPath = prefix + "uploadPath"
    static let uploadToken = prefix + "uploadToken"
}

/// A place the user has chosen to show weather for.
public struct SavedLocation: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(latitude),\(longitude)" }
    public var name: String
    public var latitude: Double
    public var longitude: Double

    public init(name: String, latitude: Double, longitude: Double) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
    }
}

// MARK: - UserDefaults helpers

extension UserDefaults {
    fileprivate func bool(forKey key: String, default fallback: Bool) -> Bool {
        object(forKey: key) as? Bool ?? fallback
    }

    /// Same as above; the label reads better at the call sites that pass a key constant.
    fileprivate func bool(_ key: String, default fallback: Bool) -> Bool {
        bool(forKey: key, default: fallback)
    }

    fileprivate func decoded<T: Decodable>(_ key: String, default fallback: T) -> T {
        guard let data = data(forKey: key),
              let value = try? JSONDecoder().decode(T.self, from: data)
        else { return fallback }
        return value
    }

    fileprivate func encode<T: Encodable>(_ value: T, _ key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        set(data, forKey: key)
    }
}
