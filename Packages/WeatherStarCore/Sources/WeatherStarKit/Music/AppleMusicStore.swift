#if canImport(MusicKit)
import Foundation
import MusicKit
import Observation
import OSLog

/// A playlist in the signed-in listener's own Apple Music library.
public struct AppleMusicPlaylist: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    /// Nil when the track relationship has not been fetched.
    public let trackCount: Int?

    public init(id: String, name: String, trackCount: Int? = nil) {
        self.id = id
        self.name = name
        self.trackCount = trackCount
    }
}

/// Why Apple Music can or cannot be used right now.
///
/// Kept separate from `Error` because none of these are faults — they are states the
/// listener can resolve, and each needs its own sentence in the settings screen.
public enum AppleMusicAvailability: Sendable, Equatable {
    /// Not yet checked.
    case unknown
    /// The listener has not been asked yet.
    case notDetermined
    /// The listener said no, or the device is restricted.
    case denied
    /// Authorised, but there is no active Apple Music subscription, so catalog
    /// playback is not permitted.
    case noSubscription
    /// Authorised and able to play.
    case ready

    public var canPlay: Bool { self == .ready }
}

public enum AppleMusicError: Error, LocalizedError, Sendable {
    case notAuthorized
    case noSubscription
    case playlistNotFound

    public var errorDescription: String? {
        switch self {
        case .notAuthorized:
            "weatherfeels has not been allowed access to Apple Music."
        case .noSubscription:
            "Playing an Apple Music playlist needs an active Apple Music subscription."
        case .playlistNotFound:
            "That playlist is no longer in your Apple Music library."
        }
    }
}

/// Reads the listener's Apple Music library and plays a playlist from it.
///
/// Playback goes through `ApplicationMusicPlayer` rather than the `AVPlayer` used for
/// every other source, because Apple Music tracks have no file URL to hand to
/// `AVPlayer` — they are DRM-protected and only that player can decode them. So this
/// type owns its own transport, and `MusicPlayer` forwards to it when Apple Music is the
/// selected source.
///
/// The library is per-listener: this shows whoever is signed into *this* device their
/// own playlists. There is no way to publish one library's playlist to other people's
/// devices, and playback needs each listener to hold a subscription.
@MainActor
@Observable
public final class AppleMusicStore: AppleMusicControlling {
    public static let shared = AppleMusicStore()

    private let logger = Logger(subsystem: "net.weatherstar.kit", category: "AppleMusic")

    public private(set) var availability: AppleMusicAvailability = .unknown
    public private(set) var playlists: [AppleMusicPlaylist] = []
    public private(set) var isLoadingPlaylists = false
    public private(set) var lastError: Error?

    /// Title of whatever `ApplicationMusicPlayer` is currently on.
    public var currentTitle: String? {
        ApplicationMusicPlayer.shared.queue.currentEntry?.title
    }

    public var isPlaying: Bool {
        ApplicationMusicPlayer.shared.state.playbackStatus == .playing
    }

    public init() {}

    // MARK: - Availability

    /// Check the current state without prompting.
    public func refreshAvailability() async {
        switch MusicAuthorization.currentStatus {
        case .notDetermined:
            availability = .notDetermined
        case .denied, .restricted:
            availability = .denied
        case .authorized:
            availability = await hasSubscription() ? .ready : .noSubscription
        @unknown default:
            availability = .unknown
        }
    }

    /// Prompt for access, then re-evaluate.
    public func requestAuthorization() async {
        let status = await MusicAuthorization.request()
        switch status {
        case .authorized:
            availability = await hasSubscription() ? .ready : .noSubscription
        case .denied, .restricted:
            availability = .denied
        case .notDetermined:
            availability = .notDetermined
        @unknown default:
            availability = .unknown
        }
    }

    /// Whether the listener may play catalog content.
    ///
    /// Treated as unavailable if the check itself fails: a network error here should
    /// surface as "no subscription" rather than silently letting playback be attempted
    /// and fail later with something less explicable.
    /// Read once via `MusicSubscription.current` rather than iterating
    /// `subscriptionUpdates`: that is an unbounded stream, so taking its first element
    /// would hang here if no update ever arrived.
    private func hasSubscription() async -> Bool {
        do {
            return try await MusicSubscription.current.canPlayCatalogContent
        } catch {
            logger.error("subscription check failed: \(error.localizedDescription)")
            lastError = error
            return false
        }
    }

    // MARK: - Library

    /// Fetch the listener's playlists, newest first.
    public func loadPlaylists() async {
        guard availability == .ready || availability == .noSubscription else { return }
        isLoadingPlaylists = true
        defer { isLoadingPlaylists = false }

        do {
            // Deliberately unsorted. Asking MusicKit to sort crashes the process on
            // macOS: `MusicLibraryRequest` is bridged to the iTunes library there, and
            // `MPModeliTunesLibraryRequestOperation` has no implementation for
            // translating a sort descriptor — it raises `doesNotRecognizeSelector:`,
            // which is an Objective-C exception, so it aborts rather than surfacing as a
            // Swift error that `try` could catch. Sorting the results here is equivalent
            // and cannot fail.
            let request = MusicLibraryRequest<Playlist>()
            let response = try await request.response()
            playlists = response.items
                .map {
                    AppleMusicPlaylist(
                        id: $0.id.rawValue,
                        name: $0.name,
                        trackCount: $0.tracks?.count
                    )
                }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            lastError = nil
        } catch {
            logger.error("playlist fetch failed: \(error.localizedDescription)")
            lastError = error
            playlists = []
        }
    }

    /// Look up one playlist by the identifier persisted in settings.
    public func playlist(id: String) async -> AppleMusicPlaylist? {
        if let cached = playlists.first(where: { $0.id == id }) { return cached }
        guard let found = try? await fetchPlaylist(id: id) else { return nil }
        return AppleMusicPlaylist(
            id: found.id.rawValue, name: found.name, trackCount: found.tracks?.count
        )
    }

    /// Find one playlist by identifier.
    ///
    /// Fetches everything and matches in Swift rather than using
    /// `request.filter(matching:equalTo:)`. The macOS iTunes-library bridge behind
    /// `MusicLibraryRequest` is incomplete — its sort-descriptor path raises
    /// `doesNotRecognizeSelector:` — and because those are Objective-C exceptions they
    /// terminate the process instead of throwing something catchable. A predicate goes
    /// through the same translation layer, so it is not worth the risk for a list that
    /// is a few dozen items long.
    private func fetchPlaylist(id: String) async throws -> Playlist {
        let request = MusicLibraryRequest<Playlist>()
        let items = try await request.response().items
        guard let playlist = items.first(where: { $0.id.rawValue == id }) else {
            throw AppleMusicError.playlistNotFound
        }
        return playlist
    }

    // MARK: - Playback

    /// The start currently in flight, so the next one queues behind it.
    private var startTask: Task<Void, Error>?

    /// Queue a playlist and begin playing it.
    ///
    /// Starts are chained rather than run concurrently. Assigning
    /// `ApplicationMusicPlayer.shared.queue` while a previous `play()` is still preparing
    /// makes MusicKit abandon the interrupted one with "Queue was interrupted by another
    /// queue" — and when two callers race, both can lose and nothing plays at all.
    public func play(playlistID: String, shuffle: Bool) async throws {
        guard MusicAuthorization.currentStatus == .authorized else {
            throw AppleMusicError.notAuthorized
        }

        let previous = startTask
        let task = Task<Void, Error> { [weak self] in
            // Let the in-flight start finish before touching the queue. Its failure is
            // not this caller's failure, hence the discard.
            _ = try? await previous?.value
            guard let self else { return }
            try await self.startPlayback(playlistID: playlistID, shuffle: shuffle)
        }
        startTask = task

        defer { if startTask == task { startTask = nil } }
        try await task.value
    }

    private func startPlayback(playlistID: String, shuffle: Bool) async throws {
        let playlist = try await fetchPlaylist(id: playlistID)
        let player = ApplicationMusicPlayer.shared

        // Queue the playlist itself rather than its tracks: the player then handles
        // advancing and repeat internally, which keeps this from having to mirror the
        // queue bookkeeping that `MusicPlayer` does for file sources.
        player.queue = ApplicationMusicPlayer.Queue(for: [playlist])
        player.state.shuffleMode = shuffle ? .songs : .off
        player.state.repeatMode = .all

        do {
            try await player.play()
        } catch {
            logger.error("Apple Music playback failed: \(error.localizedDescription)")
            lastError = error
            // A subscription lapse only shows up at this point, so translate it here
            // rather than reporting a raw MusicKit error to the user.
            throw await hasSubscription() ? error : AppleMusicError.noSubscription
        }
    }

    public func pause() {
        ApplicationMusicPlayer.shared.pause()
    }

    public func resume() async throws {
        try await ApplicationMusicPlayer.shared.play()
    }

    public func stop() {
        let player = ApplicationMusicPlayer.shared
        player.stop()
        player.queue = ApplicationMusicPlayer.Queue()
    }

    public func skipToNext() async throws {
        try await ApplicationMusicPlayer.shared.skipToNextEntry()
    }

    public func skipToPrevious() async throws {
        try await ApplicationMusicPlayer.shared.skipToPreviousEntry()
    }
}
#endif
