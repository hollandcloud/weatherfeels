import AVFoundation
import SwiftUI
import WeatherStarKit

/// One clip from the reel, playing.
///
/// Calls `onEnd` once — when the clip finishes, when it cannot be played, or when it reaches
/// its time limit — so the ad break always moves on, whatever the file or the network does.
/// A clip that fails to load gives way to the next ad at once rather than leaving a black
/// picture up for its full slot.
@MainActor
final class ClipPlayback {
    let player: AVPlayer
    private var observers: [NSObjectProtocol] = []
    private var statusObservation: NSKeyValueObservation?
    private var limit: Task<Void, Never>?
    private var ended = false
    private let onEnd: @MainActor () -> Void

    init(clip: AdClip, volume: Float, onEnd: @escaping @MainActor () -> Void) {
        self.onEnd = onEnd
        let item = AVPlayerItem(url: clip.file)
        player = AVPlayer(playerItem: item)
        player.volume = volume

        for name in [AVPlayerItem.didPlayToEndTimeNotification, AVPlayerItem.failedToPlayToEndTimeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish() }
            })
        }
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in self?.finish() }
        }
        let seconds = clip.seconds ?? AdBreaks.defaultClipSeconds
        limit = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(seconds, 1)))
            guard !Task.isCancelled else { return }
            self?.finish()
        }
        player.play()
    }

    /// Stop, and tell the owner, once.
    func finish() {
        guard !ended else { return }
        ended = true
        stop()
        onEnd()
    }

    /// Stop without telling the owner, for when the owner is the one ending the break. A
    /// failure already on its way to `finish` is dropped too, so it cannot move on a break
    /// that has since moved on itself.
    func stop() {
        ended = true
        player.pause()
        limit?.cancel()
        statusObservation?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}

/// The clip's picture.
///
/// A platform layer, which is why it sits above the picture's effects rather than inside them:
/// the CRT tube is a Metal layer effect, and SwiftUI cannot run one over a platform view. The
/// drawn scanline overlay goes back on top so the clip still reads as the set's picture.
struct ClipVideoView {
    let player: AVPlayer
}

#if os(macOS)
import AppKit

final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = playerLayer
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { nil }
}

extension ClipVideoView: NSViewRepresentable {
    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        view.playerLayer.player = player
    }
}
#else
import UIKit

final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
        backgroundColor = .black
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { nil }
}

extension ClipVideoView: UIViewRepresentable {
    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        view.playerLayer.player = player
    }
}
#endif
