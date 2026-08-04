#if os(macOS)
import CoreText
import SwiftUI
import Testing
@testable import WeatherStarUI

/// Guards the vertical metrics of the bundled Star4000 faces.
///
/// As shipped upstream, `Star4000 Large` declares an ascent about 0.18 em below where
/// its outlines actually draw. Text layout sizes a line box from ascent+descent, so
/// UIKit and SwiftUI sliced the top off every capital and the degree sign — a browser
/// hid it because CSS lets ink overflow the line box. `Tools/woff2ttf.py` raises the
/// ascent to the font bounding box during conversion; these tests fail if a
/// regenerated font loses that correction.
@Suite("Star4000 font metrics")
@MainActor
struct TextRenderingTests {
    /// Ink extent above the declared ascent, as a fraction of the font size.
    /// Positive means glyphs draw outside the line box and will be clipped.
    private func overshoot(_ face: StarFont) -> CGFloat {
        StarFontLoader.registerFonts()
        let font = CTFontCreateWithName(face.rawValue as CFString, 100, nil)
        let attributed = NSAttributedString(
            string: "88\u{00B0} Humidity ABCXYZ 1234567890",
            attributes: [kCTFontAttributeName as NSAttributedString.Key: font]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        return (ink.maxY - CTFontGetAscent(font)) / 100
    }

    @Test("Every face's declared ascent covers its glyph ink")
    func ascentCoversInk() {
        for face in StarFont.allCases {
            #expect(
                overshoot(face) <= 0,
                """
                \(face.rawValue) draws \(overshoot(face)) em above its ascent, so its \
                glyph tops will be clipped. Regenerate the fonts with \
                Tools/woff2ttf.py, which raises the ascent to the font bounding box.
                """
            )
        }
    }

    @Test("The Large face keeps the headroom the converter added")
    func largeFaceHasCorrectedAscent() {
        StarFontLoader.registerFonts()
        let font = CTFontCreateWithName(StarFont.large.rawValue as CFString, 100, nil)
        // Before correction the ascent was ~90.5 at 100pt; the bounding box needs ~129.
        #expect(
            CTFontGetAscent(font) > 120,
            "Large face ascent was not raised — the metric fix is missing"
        )
    }

    @Test("All four faces resolve to the expected PostScript name")
    func facesResolve() {
        StarFontLoader.registerFonts()
        for (face, available) in StarFontLoader.availableFonts() {
            #expect(available, "\(face.rawValue) did not register")
        }
    }

    /// Ink rows of a rendered view, used to prove text is not cut off.
    private func inkRowRange(_ view: some View, size: CGSize) -> (top: Int, bottom: Int)? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }

        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = pixels.withUnsafeMutableBytes({ buffer in
            CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let data = UnsafeBufferPointer(
            start: context.data!.assumingMemoryBound(to: UInt8.self),
            count: width * height * 4
        )
        var top = -1
        var bottom = -1
        for row in 0..<height {
            for column in 0..<width where data[(row * width + column) * 4 + 3] > 8 {
                if top < 0 { top = row }
                bottom = row
                break
            }
        }
        return top < 0 ? nil : (top, bottom)
    }

    @Test("Large-face digits are not clipped relative to plain SwiftUI text")
    func largeDigitsAreNotClipped() throws {
        // "77" is the worst case: the 7's bar sits right at the top of the em box, so
        // any lost headroom removes it entirely and the glyph reads as "/".
        //
        // Comparing StarText against a plain `Text` using the same font isolates the
        // question — does the outline/frame composition lose ink? — from any
        // Core Text unit conversion.
        StarFontLoader.registerFonts()
        let metrics = StarMetrics(space: .wide, container: CGSize(width: 3840, height: 2160))
        let canvas = CGSize(width: 600, height: 500)

        let plain = Text("77")
            .font(StarFont.large.font(size: 32, scale: metrics.scale))
            .foregroundStyle(Color.white)
        let styled = StarText("77", font: .large, size: 32, color: .white)
            .environment(\.starMetrics, metrics)

        let plainInk = try #require(inkRowRange(plain, size: canvas))
        let styledInk = try #require(inkRowRange(styled, size: canvas))

        let plainHeight = plainInk.bottom - plainInk.top + 1
        let styledHeight = styledInk.bottom - styledInk.top + 1

        // The outline and drop shadow only ever *add* ink, so the styled version must
        // never be shorter than the plain glyphs.
        #expect(
            styledHeight >= plainHeight,
            "StarText ink is \(styledHeight)pt vs plain \(plainHeight)pt — glyphs are being clipped"
        )
    }
}
#endif
