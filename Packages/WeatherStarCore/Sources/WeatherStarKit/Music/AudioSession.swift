import AVFoundation
import Foundation
import OSLog

/// The app's audio session, in one place.
///
/// This used to live inside `MusicPlayer` and was configured only on its play paths, which
/// made the category an accident of whether music happened to be on. `SoundEffects` then
/// inherited whatever session it found: with music switched off nothing had ever asked for
/// `.playback`, so the CRT sounds ran under the default category — muted by the silent
/// switch and stopped when the app left the foreground. Both players want the same session,
/// so neither should own it.
enum AudioSession {
    private static let logger = Logger(
        subsystem: "net.hlnd.weatherstar", category: "AudioSession"
    )

    /// Set to `.playback` and activate, once.
    ///
    /// Idempotent because it is called from every path that is about to make a noise, and
    /// re-activating a live session on each button press is work for no gain. A failure is
    /// logged and swallowed: silence is a poor outcome but a crash on the display loop is a
    /// worse one, and audio is never load-bearing here.
    static func activate() {
        #if !os(macOS)
        guard !isActive else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // `.playback` on purpose: the picture is meant to keep running with sound while
            // the device is locked or the app is backgrounded, and a weather channel that
            // goes silent because the ringer switch is down is not what anyone asked for.
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            isActive = true
        } catch {
            logger.warning("Audio session setup failed: \(error.localizedDescription)")
        }
        #endif
    }

    #if !os(macOS)
    private nonisolated(unsafe) static var isActive = false
    #endif
}
