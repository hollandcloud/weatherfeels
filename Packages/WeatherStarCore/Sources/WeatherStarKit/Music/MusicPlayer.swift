import AVFoundation
import Foundation
import MediaPlayer
import Observation
import OSLog

public enum PlaybackError: Error, LocalizedError, Sendable {
    case trackFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .trackFailed(reason): "Could not play that track: \(reason)"
        }
    }
}

/// Plays the music library behind the weather displays.
///
/// Uses `AVPlayer` rather than `AVAudioPlayer` so a remote server URL streams
/// without being downloaded first — which is what makes the Apple TV path work.
@MainActor
@Observable
public final class MusicPlayer {
    private let logger = Logger(subsystem: "net.weatherstar.kit", category: "MusicPlayer")

    private var player: AVPlayer?

    // Block-based notification observers stay registered until explicitly removed,
    // so the tokens must be reachable from `deinit` — which cannot touch main
    // actor state. `NotificationCenter.removeObserver` is thread-safe and these are
    // only ever written from the main actor, so opting out of isolation is sound.
    @ObservationIgnored nonisolated(unsafe) private var endObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var failureObserver: NSObjectProtocol?

    /// The shuffled (or in-order) sequence currently being played.
    public private(set) var queue: [MusicTrack] = []
    public private(set) var currentIndex = 0
    public private(set) var isPlaying = false
    public private(set) var lastError: Error?

    /// The Apple Music playlist being played, when that is the selected source.
    ///
    /// Apple Music tracks are DRM-protected and have no file URL, so `AVPlayer` cannot
    /// touch them — `ApplicationMusicPlayer` is the only thing that can decode them.
    /// When this is set, every transport call forwards to that player instead, and
    /// `queue` stays empty because the playlist's ordering, shuffling and advancing are
    /// all handled inside MusicKit.
    public private(set) var appleMusicPlaylistID: String?

    private var isAppleMusic: Bool { appleMusicPlaylistID != nil }

    public var currentTrack: MusicTrack? {
        queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
    }

    /// Name shown in the on-screen music indicator.
    public var currentTrackTitle: String {
        if isAppleMusic {
            return appleMusic?.currentTitle ?? "Not playing"
        }
        return currentTrack?.title ?? "Not playing"
    }

    // Clamped via a private store rather than assigning to itself in `didSet`: under
    // `@Observable` a self-assignment inside an observer re-enters the generated
    // setter and recurses until the stack overflows.
    private var storedVolume: Double = 0.75

    public var volume: Double {
        get { storedVolume }
        set {
            storedVolume = min(max(newValue, 0), 1)
            player?.volume = Float(storedVolume)
        }
    }

    /// Apple Music backend, injected so tests never touch the system music player.
    @ObservationIgnored private let injectedAppleMusic: AppleMusicControlling?

    /// Resolved on demand rather than in `init`.
    ///
    /// `AppleMusicStore.shared` wraps `ApplicationMusicPlayer.shared` — the *system*
    /// music player. Defaulting to it in the initialiser meant every `MusicPlayer()`
    /// instantiated it, including in tests, which opened an XPC connection to
    /// `itunescloudd` and put the suite in contact with the developer's own music
    /// library. Every caller below is already behind an `isAppleMusic` check, so
    /// resolving here means a player that never selects Apple Music never creates it.
    private var appleMusic: AppleMusicControlling? {
        #if canImport(MusicKit)
        injectedAppleMusic ?? AppleMusicStore.shared
        #else
        injectedAppleMusic
        #endif
    }

    public init(appleMusic: AppleMusicControlling? = nil) {
        injectedAppleMusic = appleMusic
    }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
    }

    // MARK: - Queue management

    /// Replace the queue. Playback continues with the new queue when already playing.
    public func load(tracks: [MusicTrack], shuffle: Bool) {
        let wasPlaying = isPlaying
        // Leaving Apple Music behind: tear its player down so two players cannot both
        // hold the audio session.
        if isAppleMusic { stopAppleMusic() }
        queue = shuffle ? tracks.shuffled() : tracks
        currentIndex = 0
        if wasPlaying, !queue.isEmpty {
            startCurrent()
        } else if queue.isEmpty {
            stop()
        }
    }

    /// Switch to an Apple Music playlist, replacing whatever was queued.
    ///
    /// Always shuffled, regardless of the `Shuffle` preference, which governs the file
    /// sources. A playlist chosen once and then played behind the weather forever would
    /// otherwise open with the same track on every single launch.
    public func loadAppleMusicPlaylist(id: String) {
        let wasPlaying = isPlaying
        stopFilePlayback()
        queue = []
        currentIndex = 0
        appleMusicPlaylistID = id
        if wasPlaying { play() }
    }

    /// Guards against two overlapping MusicKit queue assignments. See `play()`.
    @ObservationIgnored private var isStartingAppleMusic = false

    /// Reshuffle without interrupting the current track.
    public func reshuffle() {
        guard let current = currentTrack else {
            queue.shuffle()
            return
        }
        var remainder = queue.filter { $0.id != current.id }
        remainder.shuffle()
        queue = [current] + remainder
        currentIndex = 0
    }

    // MARK: - Transport

    public func play() {
        if let playlistID = appleMusicPlaylistID, let appleMusic {
            // One start at a time. Choosing a playlist changes two observed settings, so
            // `RootView` re-queues twice in quick succession; each call replaces the
            // MusicKit queue and MusicKit fails the interrupted one with
            // "Queue was interrupted by another queue", leaving nothing playing.
            guard !isStartingAppleMusic else { return }
            isStartingAppleMusic = true

            configureAudioSession()
            isPlaying = true
            Task { [weak self] in
                defer { self?.isStartingAppleMusic = false }
                do {
                    try await appleMusic.play(playlistID: playlistID, shuffle: true)
                } catch {
                    guard let self else { return }
                    self.logger.error(
                        "Apple Music start failed: \(error.localizedDescription, privacy: .public)"
                    )
                    self.lastError = error
                    self.isPlaying = false
                }
            }
            return
        }

        guard !queue.isEmpty else { return }
        configureAudioSession()

        if player == nil {
            startCurrent()
        } else {
            player?.play()
            isPlaying = true
            updateNowPlaying()
        }
    }

    public func pause() {
        if isAppleMusic {
            appleMusic?.pause()
            isPlaying = false
            return
        }
        player?.pause()
        isPlaying = false
        updateNowPlaying()
    }

    public func stop() {
        if isAppleMusic {
            stopAppleMusic()
            return
        }
        stopFilePlayback()
        isPlaying = false
        clearNowPlaying()
    }

    public func toggle() {
        isPlaying ? pause() : play()
    }

    public func next() {
        if isAppleMusic {
            if let appleMusic { Task { try? await appleMusic.skipToNext() } }
            return
        }
        guard !queue.isEmpty else { return }
        currentIndex += 1
        if currentIndex >= queue.count {
            // Reshuffle at the end of the queue, as upstream does.
            queue.shuffle()
            currentIndex = 0
        }
        startCurrent()
    }

    public func previous() {
        if isAppleMusic {
            if let appleMusic { Task { try? await appleMusic.skipToPrevious() } }
            return
        }
        guard !queue.isEmpty else { return }
        currentIndex = currentIndex > 0 ? currentIndex - 1 : queue.count - 1
        startCurrent()
    }

    /// Tear down the `AVPlayer` without touching the Apple Music player.
    private func stopFilePlayback() {
        player?.pause()
        player = nil
    }

    private func stopAppleMusic() {
        appleMusic?.stop()
        appleMusicPlaylistID = nil
        isPlaying = false
        clearNowPlaying()
    }

    // MARK: - Playback

    private func startCurrent() {
        guard let track = currentTrack else { return }

        let item = AVPlayerItem(url: track.url)
        if let player {
            player.replaceCurrentItem(with: item)
        } else {
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.volume = Float(volume)
            // Music is ambient here; never let it stall the display loop.
            newPlayer.automaticallyWaitsToMinimizeStalling = true
            player = newPlayer
        }

        observe(item)
        configureAudioSession()
        player?.play()
        isPlaying = true
        lastError = nil
        updateNowPlaying()
    }

    private func observe(_ item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }
        }

        failureObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] notification in
            // Reduce the notification to a plain String here: `Notification` is not
            // Sendable, so it must not be captured by the isolated closure below.
            let reason = (notification.userInfo?[
                AVPlayerItemFailedToPlayToEndTimeErrorKey
            ] as? Error)?.localizedDescription ?? "unknown"

            MainActor.assumeIsolated {
                guard let self else { return }
                self.logger.warning("Track failed: \(reason, privacy: .public)")
                self.lastError = PlaybackError.trackFailed(reason)
                // Skip a bad file rather than stalling the queue.
                self.next()
            }
        }
    }

    /// Declare the audio as ambient playback so it mixes correctly and keeps
    /// playing when the app is backgrounded on iOS/tvOS.
    private func configureAudioSession() {
        #if !os(macOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            logger.warning("Audio session setup failed: \(error.localizedDescription)")
        }
        #endif
    }

    // MARK: - Now Playing

    /// Publish the track to Control Center / the Apple TV remote.
    private func updateNowPlaying() {
        guard let track = currentTrack else { return clearNowPlaying() }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: "weatherfeels",
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let duration = player?.currentItem?.duration, duration.isNumeric {
            info[MPMediaItemPropertyPlaybackDuration] = duration.seconds
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
