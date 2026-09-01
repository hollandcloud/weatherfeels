import AVFoundation
import Foundation
import OSLog
import WeatherStarResources

/// The set's own noises: the flyback whine and thump as the picture comes and goes.
///
/// Separate from `MusicPlayer` because they are not music and must not behave like it.
/// The music is a bed the user chose and can turn off; these are the interface making a
/// sound, they are short, and they play over whatever is already going rather than
/// interrupting it.
///
/// The assets are synthesised by `Tools/MakeSounds.py` and committed — see that file for
/// why they are generated rather than sampled.
@MainActor
@Observable
public final class SoundEffects {
    public enum Effect: String, CaseIterable, Sendable {
        case powerOn = "crt-power-on"
        case powerOff = "crt-power-off"
    }

    private static let logger = Logger(
        subsystem: "net.hlnd.weatherstar", category: "SoundEffects"
    )

    /// One player per effect, prepared up front.
    ///
    /// Building an `AVAudioPlayer` takes long enough to be felt when the sound is meant to
    /// land on the same frame as a button press, and these are two files of a few tens of
    /// kilobytes — cheap to hold for the life of the app.
    private var players: [Effect: AVAudioPlayer] = [:]

    /// Whether the effects are audible at all.
    ///
    /// Deliberately *not* wired to `musicEnabled`. Someone who turned the music off asked
    /// for no soundtrack, not for a silent interface, and conflating the two means the
    /// power button goes quiet for a reason that has nothing to do with it.
    public var isEnabled: Bool = true

    public init() {
        for effect in Effect.allCases {
            guard let url = WeatherStarResources.url("\(effect.rawValue).wav", in: .sounds) else {
                Self.logger.error("Missing sound \(effect.rawValue, privacy: .public).wav")
                continue
            }
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                players[effect] = player
            } catch {
                Self.logger.error(
                    "Could not load \(effect.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Play `effect` from the start, over anything already sounding.
    ///
    /// Restarting rather than ignoring a retrigger: mashing the power button should click
    /// each time, the way a real switch does, not swallow presses while the last one rings
    /// out. A missing file is silence, never a crash — the picture still has to work.
    public func play(_ effect: Effect) {
        guard isEnabled, let player = players[effect] else { return }
        // Not inherited from the music. With music switched off nothing else asks for
        // `.playback`, and these would run under the default category — silenced by the
        // ringer switch and stopped on backgrounding.
        AudioSession.activate()
        player.currentTime = 0
        player.play()
    }
}
