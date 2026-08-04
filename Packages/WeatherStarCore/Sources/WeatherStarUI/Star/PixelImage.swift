import ImageIO
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import WeatherStarKit

/// A decoded image, with animation frames when the source is an animated GIF.
struct DecodedImage: Sendable {
    struct Frame: Sendable {
        let image: CGImage
        /// Seconds this frame is held.
        let duration: Double
    }

    let frames: [Frame]
    let pixelSize: CGSize

    var isAnimated: Bool { frames.count > 1 }
    var totalDuration: Double { frames.reduce(0) { $0 + $1.duration } }

    /// Frame index for a point in time, looping.
    func frameIndex(at time: Double) -> Int {
        guard isAnimated, totalDuration > 0 else { return 0 }
        var remaining = time.truncatingRemainder(dividingBy: totalDuration)
        for (index, frame) in frames.enumerated() {
            remaining -= frame.duration
            if remaining < 0 { return index }
        }
        return frames.count - 1
    }
}

/// Decodes and caches the bundled weather art.
///
/// Several of the icons are 7-frame animated GIFs, which SwiftUI's `Image` will not
/// animate on its own, so frames are pulled out with ImageIO and driven by a
/// `TimelineView`.
enum ImageDecoder {
    private static let logger = Logger(subsystem: "net.weatherstar.ui", category: "ImageDecoder")

    /// GIFs that specify no delay, or an implausibly short one, are shown at this
    /// rate — the convention browsers use.
    private static let defaultFrameDuration = 0.1
    private static let minimumFrameDuration = 0.02

    private static let cache = Cache()

    /// Keyed by absolute file path.
    private actor Cache {
        private var storage: [String: DecodedImage] = [:]

        func value(for key: String) -> DecodedImage? { storage[key] }
        func insert(_ value: DecodedImage, for key: String) { storage[key] = value }
    }

    static func decode(_ url: URL) async -> DecodedImage? {
        let key = url.path
        if let cached = await cache.value(for: key) { return cached }
        guard let decoded = decodeSynchronously(url) else { return nil }
        await cache.insert(decoded, for: key)
        return decoded
    }

    static func decodeSynchronously(_ url: URL) -> DecodedImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            logger.warning("Could not open image \(url.lastPathComponent, privacy: .public)")
            return nil
        }

        let count = CGImageSourceGetCount(source)
        var frames: [DecodedImage.Frame] = []
        var pixelSize = CGSize.zero

        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            if pixelSize == .zero {
                pixelSize = CGSize(width: image.width, height: image.height)
            }
            frames.append(
                DecodedImage.Frame(
                    image: image,
                    duration: frameDuration(source: source, index: index)
                )
            )
        }

        guard !frames.isEmpty else { return nil }
        return DecodedImage(frames: frames, pixelSize: pixelSize)
    }

    /// Per-frame delay from the GIF metadata, preferring the unclamped value.
    private static func frameDuration(source: CGImageSource, index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            as NSDictionary?,
            let gif = properties[kCGImagePropertyGIFDictionary] as? NSDictionary
        else { return defaultFrameDuration }

        let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double
        let delay = unclamped ?? clamped ?? defaultFrameDuration

        // A zero or near-zero delay means "as fast as possible"; browsers substitute
        // 100ms, and matching that keeps the animation speed faithful.
        return delay < minimumFrameDuration ? defaultFrameDuration : delay
    }
}

/// Draws bundled pixel art at any scale without blurring it.
///
/// The weather icons are hand-drawn pixel art. Smooth interpolation turns them to
/// mush when scaled 4.5× for a 4K TV, so magnification uses nearest-neighbor
/// (`.interpolation(.none)`) — the icons stay crisp and read as deliberate pixel art.
public struct PixelImage: View {
    private let icon: WeatherIcon?
    private let url: URL?
    /// Design-space height; width follows the source aspect ratio.
    private let designHeight: CGFloat?
    private let designWidth: CGFloat?

    @Environment(\.starMetrics) private var metrics
    @State private var decoded: DecodedImage?

    public init(_ icon: WeatherIcon?, width: CGFloat? = nil, height: CGFloat? = nil) {
        self.icon = icon
        url = icon?.url
        designWidth = width
        designHeight = height
    }

    public init(url: URL?, width: CGFloat? = nil, height: CGFloat? = nil) {
        icon = nil
        self.url = url
        designWidth = width
        designHeight = height
    }

    public var body: some View {
        Group {
            if let decoded {
                if decoded.isAnimated {
                    animated(decoded)
                } else if let frame = decoded.frames.first {
                    render(frame.image, source: decoded.pixelSize)
                }
            } else {
                // Reserve the slot so the layout does not shift once decoding lands.
                Color.clear
                    .designFrame(width: designWidth, height: designHeight)
            }
        }
        .task(id: url) {
            guard let url else { return }
            decoded = await ImageDecoder.decode(url)
        }
    }

    /// Drive GIF frames off a shared timeline so several icons stay in step.
    private func animated(_ decoded: DecodedImage) -> some View {
        TimelineView(.animation(minimumInterval: 0.05, paused: false)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let index = decoded.frameIndex(at: elapsed)
            render(decoded.frames[index].image, source: decoded.pixelSize)
        }
    }

    private func render(_ image: CGImage, source: CGSize) -> some View {
        let size = resolvedSize(source: source)
        return Image(decorative: image, scale: 1)
            .interpolation(.none)
            .antialiased(false)
            .resizable()
            .frame(width: metrics.s(size.width), height: metrics.s(size.height))
    }

    /// Size in design points, derived from whichever dimension the caller specified.
    private func resolvedSize(source: CGSize) -> CGSize {
        let aspect = source.height > 0 ? source.width / source.height : 1

        switch (designWidth, designHeight) {
        case let (width?, height?):
            return CGSize(width: width, height: height)
        case let (width?, nil):
            return CGSize(width: width, height: aspect > 0 ? width / aspect : width)
        case let (nil, height?):
            return CGSize(width: height * aspect, height: height)
        case (nil, nil):
            // Bundled art is authored at the design scale, so use its own size.
            return source
        }
    }
}
