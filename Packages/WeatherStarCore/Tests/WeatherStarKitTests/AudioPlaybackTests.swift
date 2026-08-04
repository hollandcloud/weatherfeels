import AVFoundation
import Foundation
import Testing
@testable import WeatherStarKit

/// Verifies the audio path end to end, short of the speakers themselves.
///
/// A screenshot cannot show whether music is playing, and the player only logs
/// failures, so "no errors in the log" proves nothing. These tests decode the real
/// bundled files with AVFoundation and drive the player, which covers everything the
/// app controls: the files are present, they are valid audio, they report a duration,
/// and the player advances through a queue.
@Suite("Audio playback")
struct AudioPlaybackTests {
    @Test("The bundled tracks are real, decodable audio with a sensible duration")
    func bundledTracksAreDecodable() async throws {
        let tracks = MusicStorage.bundledTracks()
        #expect(tracks.count == 4)

        for track in tracks {
            let asset = AVURLAsset(url: track.url)

            // `isPlayable` is AVFoundation's own verdict on whether it can render this.
            let playable = try await asset.load(.isPlayable)
            #expect(playable, "\(track.title) is not playable")

            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            // The upstream tracks run roughly 2–4 minutes.
            #expect(
                seconds > 30 && seconds < 600,
                "\(track.title) reports an implausible duration of \(seconds)s"
            )

            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            #expect(!audioTracks.isEmpty, "\(track.title) has no audio track")
        }
    }

    @Test("Playing a bundled track reaches the ready-to-play state")
    @MainActor
    func playerReachesReadyState() async throws {
        let track = try #require(MusicStorage.bundledTracks().first)
        let item = AVPlayerItem(url: track.url)
        let player = AVPlayer(playerItem: item)
        player.volume = 0  // silent: this asserts on state, not sound

        player.play()

        // Poll briefly for readiness rather than assuming an interval is enough.
        var status = item.status
        for _ in 0..<40 where status != .readyToPlay {
            try? await Task.sleep(for: .milliseconds(50))
            status = item.status
        }

        #expect(status == .readyToPlay, "player item never became ready: \(item.error?.localizedDescription ?? "no error")")
        player.pause()
    }

    @Test("The player reports the track it is on and advances through the queue")
    @MainActor
    func playerAdvancesQueue() {
        let player = MusicPlayer()
        let tracks = MusicStorage.bundledTracks()
        try? #require(!tracks.isEmpty)

        player.load(tracks: tracks, shuffle: false)
        #expect(player.currentTrackTitle == tracks[0].title)

        player.next()
        #expect(player.currentTrackTitle == tracks[1].title)

        // Stepping past the end wraps around rather than stalling.
        for _ in 0..<tracks.count { player.next() }
        #expect(player.currentTrack != nil)
    }

    @Test("A remote playlist resolves relative filenames against the music path")
    func remotePlaylistResolvesURLs() async {
        // Mirrors what a ws4kp server returns, including a percent-encoded name and a
        // subdirectory, since both appear in real playlists.
        let json = #"{"availableFiles":["Catch%20the%20Sun.mp3","default/Crisp day.mp3"]}"#
        let playlist = try? JSONDecoder().decode(RemotePlaylist.self, from: Data(json.utf8))
        let files = try? #require(playlist?.availableFiles)
        #expect(files?.count == 2)

        let base = URL(string: "http://nas.local:8080")!.appending(path: "music/")
        let resolved = (files ?? []).compactMap {
            URL(string: $0, relativeTo: base)?.absoluteURL
        }
        #expect(resolved.count == 2)
        #expect(resolved[0].absoluteString == "http://nas.local:8080/music/Catch%20the%20Sun.mp3")
        #expect(resolved[1].absoluteString == "http://nas.local:8080/music/default/Crisp%20day.mp3")

        // Titles are what the on-screen indicator shows.
        #expect(MusicTrack(url: resolved[0], source: .remoteServer).title == "Catch the Sun")
    }
}
