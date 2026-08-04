import Foundation
import WeatherStarResources

/// The transport `MusicPlayer` needs from an Apple Music backend.
///
/// Exists so `MusicPlayer` never reaches `ApplicationMusicPlayer.shared` directly. That
/// singleton *is* the system music player: a test that touched it drove the real Music
/// app and opened an XPC connection to `itunescloudd` on the developer's own machine.
/// Injecting this instead keeps tests entirely off the listener's music library.
@MainActor
public protocol AppleMusicControlling: AnyObject {
    /// Title of the entry currently playing, if any.
    var currentTitle: String? { get }
    func play(playlistID: String, shuffle: Bool) async throws
    func pause()
    func stop()
    func skipToNext() async throws
    func skipToPrevious() async throws
}

/// Where the app looks for music.
public enum MusicSourceKind: String, Codable, Sendable, CaseIterable {
    /// The four tracks shipped with the app.
    case bundled
    /// Files imported into the app's own Documents folder (iOS, iPadOS, macOS).
    case localFiles
    /// An HTTP server exposing a playlist, including an existing ws4kp install.
    case remoteServer
    /// A playlist from the listener's own Apple Music library.
    case appleMusic
    /// The user's private CloudKit database, synced across their devices.
    case iCloud

    public var displayName: String {
        switch self {
        case .bundled: "Bundled music"
        case .localFiles: "On this device"
        case .remoteServer: "Music server"
        case .appleMusic: "Apple Music"
        case .iCloud: "iCloud (private)"
        }
    }

    public var detail: String {
        switch self {
        case .bundled:
            "The four instrumental tracks included with the app."
        case .localFiles:
            "Audio files you add to this device. Not available on Apple TV."
        case .remoteServer:
            "Streams from a URL you host. Works with an existing WeatherStar 4000+ server."
        case .appleMusic:
            "A playlist from your Apple Music library. Needs an Apple Music subscription."
        case .iCloud:
            "Add music on iPhone, iPad or Mac and it appears on your Apple TV. Stored in your own iCloud account."
        }
    }

    /// Whether playback for this source runs through `ApplicationMusicPlayer` instead of
    /// the app's own `AVPlayer`, because its tracks have no file URL.
    public var usesAppleMusicPlayer: Bool { self == .appleMusic }

    /// Whether this source can be chosen in this build, on this platform.
    ///
    /// A source that cannot possibly load anything is not offered at all. Listing one
    /// and then reporting "not enabled in this build" after it is picked leaves the app
    /// pointed at a source that never yields a track, which presents as music simply
    /// never starting — the least diagnosable failure available.
    public var isAvailableOnThisPlatform: Bool {
        switch self {
        case .localFiles:
            // tvOS has no document picker, so there is no way to get a file in.
            #if os(tvOS)
            return false
            #else
            return true
            #endif

        case .iCloud:
            // `CloudKitMusicStore` is compiled out without the flag, and enabling it
            // needs an iCloud container on the signing team — so a stock build cannot
            // use this at all. Apple Music covers the same "my music on all my devices"
            // job without any of that.
            #if WS4K_CLOUDKIT
            return true
            #else
            return false
            #endif

        case .bundled, .remoteServer, .appleMusic:
            // Apple Music included: `MusicLibraryRequest` reaches the listener's own
            // playlists on tvOS 16+, so the picker works on the Apple TV itself rather
            // than needing a phone to choose on.
            return true
        }
    }

    public static var availableCases: [MusicSourceKind] {
        allCases.filter(\.isAvailableOnThisPlatform)
    }
}

/// One playable track.
public struct MusicTrack: Sendable, Hashable, Identifiable {
    public let id: String
    /// Display name, derived from the filename with the extension stripped.
    public let title: String
    public let url: URL
    public let source: MusicSourceKind

    public init(id: String? = nil, title: String? = nil, url: URL, source: MusicSourceKind) {
        self.url = url
        self.source = source
        self.id = id ?? url.absoluteString
        self.title = title ?? Self.displayTitle(from: url)
    }

    /// Strip the extension and the separators ws4kp's filenames use, matching
    /// `setTrackName` in `media.mjs`.
    static func displayTitle(from url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let decoded = base.removingPercentEncoding ?? base
        return decoded
            .replacingOccurrences(of: "_-", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Audio file types the app will play. Broader than upstream's mp3-only support,
/// since AVFoundation handles these natively.
public enum SupportedAudio {
    public static let fileExtensions: Set<String> = [
        "mp3", "m4a", "aac", "aif", "aiff", "wav", "caf", "flac", "alac", "mp4",
    ]

    public static func isSupported(_ url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
    }
}

/// The playlist shape ws4kp's server returns from `/playlist.json`.
/// Reused verbatim so an existing install works as a source with no changes.
public struct RemotePlaylist: Codable, Sendable {
    public var availableFiles: [String]

    public init(availableFiles: [String]) {
        self.availableFiles = availableFiles
    }
}

/// Local storage for imported music, inside the app's Documents directory so it is
/// covered by the user's device backup and visible in Files when the app opts in.
public enum MusicStorage {
    public static var directory: URL? {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return documents.appendingPathComponent("Music", isDirectory: true)
    }

    /// Create the music directory if needed and return it.
    @discardableResult
    public static func ensureDirectory() throws -> URL {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    /// Imported audio files, sorted by name.
    public static func localTracks() -> [MusicTrack] {
        guard let directory,
              let contents = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: nil
              )
        else { return [] }

        return contents
            .filter(SupportedAudio.isSupported)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { MusicTrack(url: $0, source: .localFiles) }
    }

    public static func bundledTracks() -> [MusicTrack] {
        WeatherStarResources.contents(of: .music)
            .filter(SupportedAudio.isSupported)
            .map { MusicTrack(url: $0, source: .bundled) }
    }
}
