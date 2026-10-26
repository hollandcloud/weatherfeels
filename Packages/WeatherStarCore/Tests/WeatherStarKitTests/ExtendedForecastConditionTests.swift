import CoreGraphics
import SwiftUI
import Testing
@testable import WeatherStarKit
@testable import WeatherStarUI

/// An Extended Forecast day's condition must stay above the day's icon.
///
/// "Slight Chance Rain Showers" wrapped to three lines at 32pt, and the third ran down onto
/// the icon: `StarText` keeps its natural height, so its scale factor only ever condensed a
/// line to the width and never shrank the text to fit the box.
@Suite("Extended Forecast condition")
@MainActor
struct ExtendedForecastConditionTests {
    /// Where the icon starts, measured from the top of the condition box.
    private static let iconTop = 82

    /// The lowest row of lit text, in design points, drawn one point to a design point on
    /// black. The outline and shadow are black, so only the fill counts.
    private func lowestInk(_ view: some View) throws -> Int {
        StarFontLoader.registerFonts()
        let metrics = StarMetrics(
            space: .standard, scale: 1, origin: .zero, scaledSize: CGSize(width: 640, height: 480)
        )
        let content = view
            .environment(\.starMetrics, metrics)
            .frame(width: 155, height: 240, alignment: .top)
            .background(Color.black)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try #require(renderer.cgImage, "failed to render")

        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        for row in stride(from: height - 1, through: 0, by: -1) {
            for column in 0..<width {
                let i = (row * width + column) * 4
                if Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) > 300 { return row }
            }
        }
        return 0
    }

    private func fullSize(_ text: String) -> some View {
        StarText(text, font: .regular, size: 32, alignment: .center, lineLimit: 3, minimumScaleFactor: 0.55)
            .frame(width: 155)
    }

    @Test("A long condition stays above the icon")
    func longConditionsFit() throws {
        // The harness can see the bug: at the single old size, this one ran onto the icon.
        #expect(try lowestInk(fullSize("Slight Chance Rain Showers")) > Self.iconTop)

        for text in [
            "Slight Chance Rain Showers",
            "Chance Showers And Thunderstorms",
            "Showers And Thunderstorms Likely",
            "Patchy Fog then Mostly Sunny",
        ] {
            let bottom = try lowestInk(ExtendedForecastDisplay.condition(text))
            #expect(bottom <= Self.iconTop, "\"\(text)\" reaches \(bottom), the icon starts at \(Self.iconTop)")
        }
    }

    @Test("A condition that already fits keeps the full size")
    func shortConditionsKeepTheirSize() throws {
        // Including one that only fits by condensing onto two lines, which it should still do
        // rather than drop a size.
        for text in ["Sunny", "Mostly Sunny", "Showers And Thunderstorms"] {
            #expect(
                try lowestInk(ExtendedForecastDisplay.condition(text)) == lowestInk(fullSize(text)),
                "\"\(text)\" was drawn smaller than it needed to be"
            )
        }
    }
}
