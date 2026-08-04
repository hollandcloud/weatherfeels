import Foundation
import Observation
import OSLog

public enum MusicLibraryError: Error, LocalizedError, Sendable {
    case noSourceConfigured
    case invalidServerURL
    case serverUnreachable(String)
    case emptyPlaylist
    case cloudKitUnavailable

    public var errorDescription: String? {
        switch self {
        case .noSourceConfigured:
            "No music source is configured."
        case .invalidServerURL:
            "That server address isn't a valid URL."
        case let .serverUnreachable(message):
            "Could not reach the music server: \(message)"
        case .emptyPlaylist:
            "The music source has no playable audio files."
        case .cloudKitUnavailable:
            "iCloud music is not available in this build. See README for enabling it."
        }
    }
}

/// Resolves the configured music source into a list of playable tracks.
///
/// Remote resolution matches ws4kp: ask for `/playlist.json` first, and fall back to
/// scraping an autoindex directory listing, so both a full ws4kp server and a plain
/// static file host work as sources.
@MainActor
@Observable
public final class MusicLibrary {
    private let logger = Logger(subsystem: "net.weatherstar.kit", category: "MusicLibrary")
    private let settings: AppSettings
    private let session: URLSession

    public private(set) var tracks: [MusicTrack] = []
    public private(set) var isLoading = false
    public private(set) var lastError: Error?
    /// Human-readable note about where the current playlist came from.
    public private(set) var sourceDescription: String = ""

    public init(settings: AppSettings, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    public var isEmpty: Bool { tracks.isEmpty }

    /// Load tracks for the configured source, falling back to bundled music so the
    /// unmute button still does something when a remote source is unavailable.
    public func reload() async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        do {
            let resolved = try await resolve(settings.musicSource)
            // Apple Music resolves to no `MusicTrack`s by design — MusicKit holds the
            // queue and plays the playlist itself — so empty is success here, not an
            // unavailable source. Without this exemption the source was reported as
            // failed on every reload and quietly replaced with bundled music.
            if resolved.isEmpty, !settings.musicSource.usesAppleMusicPlayer {
                throw MusicLibraryError.emptyPlaylist
            }
            tracks = resolved
        } catch {
            logger.warning("Music source failed: \(error.localizedDescription)")
            lastError = error
            let fallback = MusicStorage.bundledTracks()
            tracks = fallback
            if !fallback.isEmpty {
                sourceDescription = "Bundled music (source unavailable)"
            }
        }
    }

    private func resolve(_ source: MusicSourceKind) async throws -> [MusicTrack] {
        switch source {
        case .bundled:
            let tracks = MusicStorage.bundledTracks()
            sourceDescription = "\(tracks.count) bundled track\(tracks.count == 1 ? "" : "s")"
            return tracks

        case .localFiles:
            let tracks = MusicStorage.localTracks()
            sourceDescription = "\(tracks.count) file\(tracks.count == 1 ? "" : "s") on this device"
            return tracks

        case .remoteServer:
            guard let base = settings.remoteMusicURL else { throw MusicLibraryError.invalidServerURL }
            let tracks = try await remoteTracks(base: base)
            sourceDescription = "\(tracks.count) track\(tracks.count == 1 ? "" : "s") from \(base.host() ?? base.absoluteString)"
            return tracks

        case .appleMusic:
            // Apple Music never yields `MusicTrack`s. Its items are DRM-protected with
            // no file URL, so `ApplicationMusicPlayer` plays the playlist directly and
            // the library stays empty — see `MusicPlayer.loadAppleMusicPlaylist`.
            if let name = settings.appleMusicPlaylistName {
                sourceDescription = "Apple Music playlist “\(name)”"
            } else {
                sourceDescription = "No Apple Music playlist chosen yet"
            }
            return []

        case .iCloud:
            #if WS4K_CLOUDKIT
            let tracks = try await CloudKitMusicStore.shared.tracks()
            sourceDescription = "\(tracks.count) track\(tracks.count == 1 ? "" : "s") in iCloud"
            return tracks
            #else
            throw MusicLibraryError.cloudKitUnavailable
            #endif
        }
    }

    // MARK: - Remote resolution

    /// Fetch a playlist from a server, trying the ws4kp JSON endpoint then a
    /// directory listing.
    public func remoteTracks(base: URL) async throws -> [MusicTrack] {
        let musicBase = base.appending(path: "music/")

        if let files = try? await fetchPlaylistJSON(base: base), !files.isEmpty {
            return files.compactMap { relative in
                // Playlist entries are relative to /music/ and may be percent-encoded.
                guard let url = URL(string: relative, relativeTo: musicBase)?.absoluteURL
                else { return nil }
                return MusicTrack(url: url, source: .remoteServer)
            }
        }

        // Static hosts have no playlist endpoint; scrape the autoindex instead.
        let scraped = try await scrapeDirectory(musicBase)
        if !scraped.isEmpty { return scraped }

        // ws4kp keeps its shipped tracks in music/default when the folder is empty.
        return try await scrapeDirectory(musicBase.appending(path: "default/"))
    }

    private func fetchPlaylistJSON(base: URL) async throws -> [String] {
        let url = base.appending(path: "playlist.json")
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MusicLibraryError.serverUnreachable("no playlist.json")
        }
        return try JSONDecoder().decode(RemotePlaylist.self, from: data).availableFiles
    }

    /// Pull audio filenames out of an HTML directory index.
    private func scrapeDirectory(_ url: URL) async throws -> [MusicTrack] {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MusicLibraryError.serverUnreachable("HTTP error listing \(url.path())")
        }
        guard let html = String(data: data, encoding: .utf8) else { return [] }

        let extensions = SupportedAudio.fileExtensions.joined(separator: "|")
        guard let regex = try? NSRegularExpression(
            pattern: "href=\"([^\"]+\\.(?:\(extensions)))\"",
            options: [.caseInsensitive]
        ) else { return [] }

        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        var seen = Set<String>()

        return matches.compactMap { match -> MusicTrack? in
            guard let range = Range(match.range(at: 1), in: html) else { return nil }
            let href = String(html[range])
            guard seen.insert(href).inserted,
                  let resolved = URL(string: href, relativeTo: url)?.absoluteURL
            else { return nil }
            return MusicTrack(url: resolved, source: .remoteServer)
        }
    }

    /// Probe a server without changing the library, for the Settings "Test" button.
    public func testConnection(to base: URL) async -> Result<Int, Error> {
        do {
            return .success(try await remoteTracks(base: base).count)
        } catch {
            return .failure(error)
        }
    }
}
