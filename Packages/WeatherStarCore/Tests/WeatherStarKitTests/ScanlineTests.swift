#if os(macOS)
import ImageIO
import SwiftUI
import Testing
@testable import WeatherStarKit
@testable import WeatherStarUI

/// The animated overlay must actually differ frame to frame, and must not swamp the
/// picture underneath.
@Suite("Animated scanlines")
@MainActor
struct ScanlineTests {
    private static let size = CGSize(width: 854, height: 480)

    /// Renders the overlay alone over white, so only the overlay's own darkening shows.
    private func render(animated: Bool) -> CGImage? {
        let view = ZStack {
            Color.white
            Scanlines(mode: .medium, animated: animated)
                .environment(\.starMetrics, StarMetrics(space: .wide, container: Self.size))
        }
        .frame(width: Self.size.width, height: Self.size.height)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.cgImage
    }

    private static func rowLuma(_ image: CGImage) -> [Int] {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let context = pixels.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let data = UnsafeBufferPointer(
            start: context.data!.assumingMemoryBound(to: UInt8.self), count: w * h * 4
        )
        return (0..<h).map { row in
            var total = 0
            for col in stride(from: 0, to: w, by: 16) {
                let i = (row * w + col) * 4
                total += (Int(data[i]) + Int(data[i + 1]) + Int(data[i + 2])) / 3
            }
            return total / max(1, w / 16)
        }
    }

    @Test("Lines are drawn and leave the picture visible")
    func linesPresentButNotOpaque() throws {
        let image = try #require(render(animated: true), "overlay failed to render")
        let rows = Self.rowLuma(image)

        let darkest = rows.min() ?? 255
        let brightest = rows.max() ?? 0
        // There must be a pattern: some rows darkened, others near white.
        #expect(brightest > 200, "no bright rows — the overlay is too dense (max \(brightest))")
        #expect(darkest < 200, "no dark rows — the lines are not being drawn (min \(darkest))")
    }

    @Test("The static overlay still renders")
    func staticStillWorks() throws {
        let image = try #require(render(animated: false))
        let rows = Self.rowLuma(image)
        #expect((rows.max() ?? 0) > 200)
        #expect((rows.min() ?? 255) < 200)
    }
}
#endif
