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

    /// Asserted as row-to-row *contrast* rather than against absolute brightness levels.
    ///
    /// An earlier version compared the darkest row to a fixed threshold and happened to
    /// land exactly on it once the drift and roll bar were added — `ImageRenderer` samples
    /// the timeline at an arbitrary moment, so which rows are dark is not deterministic.
    /// The difference between light and dark rows is phase-independent; the absolute values
    /// are not.
    @Test("Lines are drawn and leave the picture visible", arguments: [false, true])
    func linesPresentButNotOpaque(animated: Bool) throws {
        let image = try #require(render(animated: animated), "overlay failed to render")
        let rows = Self.rowLuma(image)
        let darkest = rows.min() ?? 255
        let brightest = rows.max() ?? 0

        #expect(
            brightest - darkest > 20,
            """
            animated=\(animated): no line pattern — rows run \(darkest)...\(brightest),             so the overlay is either absent or a flat wash
            """
        )
        #expect(
            brightest > 150,
            "animated=\(animated): the overlay is too dense, brightest row is \(brightest)"
        )
    }

    /// The guard has to hold, or every snapshot test dies.
    ///
    /// `ShaderLibrary.default` reads the main bundle's metallib, which exists in an app and
    /// not in this test process. A SwiftUI shader naming a function that is not there is a
    /// hard failure at render time, so `CRTEffect.isAvailable` is what keeps asking for the
    /// tube from taking the whole suite down.
    @Test("Requesting the tube without a metallib renders instead of trapping")
    func tubeFallsBackWhenShaderMissing() throws {
        #expect(
            !CRTEffect.isAvailable,
            "this process has a metallib, so the fallback path is not being exercised"
        )

        let view = ZStack {
            Color.white
            Color.blue.frame(width: 100, height: 100)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .crtEffect(CRTSettings(), size: Self.size)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        // Reaching this line at all is the assertion: a missing shader would have
        // terminated the process.
        #expect(renderer.cgImage != nil, "the fallback path failed to render")
    }
}
#endif

#if os(macOS)
/// Extended Forecast panels must centre their wrapped condition text.
///
/// The condition frame is narrower than the panel and the enclosing `ZStack` already
/// centres it; an inset of half the difference was applied on top, so the text sat against
/// the panel's right edge and the last line was truncated. Second time that
/// double-centring has appeared in this layout code, hence the test.
@Suite("Extended Forecast centring")
@MainActor
struct ExtendedForecastCentringTests {
    @Test("Condition text is centred within each panel")
    func conditionCentred() throws {
        StarFontLoader.registerFonts()

        let days = (0..<3).map { index in
            ExtendedDay(
                dayName: ["TUE", "WED", "THU"][index],
                icon: IconMapper.smallIcon(for: "/icons/land/day/tsra_hi"),
                condition: "Scattered Showers And Thunderstorms",
                low: "74",
                high: "88"
            )
        }

        let size = CGSize(width: 854, height: 480)
        let view = ExtendedForecastDisplay(days: days, screenIndex: 0)
            .environment(\.starMetrics, StarMetrics(space: .wide, container: size))
            .environment(\.starContentWidth, 854)
            .frame(width: size.width, height: size.height)
            .background(Color.black)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage, "failed to render")

        // Measured inside *one* panel, not across all three. An earlier version compared
        // the outer margins of the whole band, which the bug barely moved — every panel
        // shifted by the same amount, so the leftmost and rightmost ink both slid over and
        // the ratio stayed within tolerance. The asymmetry only shows up per panel.
        //
        // Mirrors ExtendedForecastDisplay.Layout: three 174pt panels with 20pt gaps,
        // centred in the 854pt wide space, so the first starts at 146pt. The design space
        // matches the container here, and the renderer is at 2x.
        let deviceScale = 2.0
        let panelLeft = Int(146.0 * deviceScale)
        let panelWidth = Int(174.0 * deviceScale)

        let band = try #require(
            image.cropping(to: CGRect(
                x: panelLeft, y: Int(Double(image.height) * 0.16),
                width: panelWidth, height: Int(Double(image.height) * 0.22)
            )),
            "crop failed"
        )
        let columns = Self.litColumns(band)
        let left = try #require(columns.first, "no condition text found in the first panel")
        let right = try #require(columns.last)

        let leftMargin = Double(left)
        let rightMargin = Double(band.width - 1 - right)
        #expect(
            leftMargin + rightMargin > 0,
            "text filled the whole panel, so centring cannot be judged"
        )
        let imbalance = abs(leftMargin - rightMargin) / (leftMargin + rightMargin)
        #expect(
            imbalance < 0.34,
            """
            condition text is off-centre in its panel: \(Int(leftMargin))px left vs \
            \(Int(rightMargin))px right
            """
        )
    }

    /// Indices of columns containing anything brighter than the panel background.
    private static func litColumns(_ image: CGImage) -> [Int] {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = pixels.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let data = UnsafeBufferPointer(
            start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: w * h * 4
        )
        return (0..<w).filter { col in
            for row in stride(from: 0, to: h, by: 2) {
                let i = (row * w + col) * 4
                // The condition text is near-white; the panel behind it is mid blue.
                if data[i] > 200, data[i + 1] > 200, data[i + 2] > 200 { return true }
            }
            return false
        }
    }
}
#endif
