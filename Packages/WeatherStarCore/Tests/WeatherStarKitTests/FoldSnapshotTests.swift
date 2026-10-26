#if os(macOS)
import ImageIO
import SwiftUI
import Testing
@testable import WeatherStarKit
@testable import WeatherStarUI

/// Renders iPhone Duo's folded layouts off-device, to `/tmp/ws4k-snapshots`.
///
/// The simulator can bend its hinge but, in Xcode 27.1, not turn the open device on its side
/// from the command line — so the tabletop posture cannot be photographed there without
/// driving Device Hub by hand. These draw the same views `RootView` composes, at the Duo's
/// own sizes, so both postures can be looked at in seconds. They assert the one thing that
/// matters most and is easiest to measure: nothing is drawn across the crease.
@Suite("Folded layout snapshots")
@MainActor
struct FoldSnapshotTests {
    private static let outputDirectory = URL(fileURLWithPath: "/tmp/ws4k-snapshots")

    private func render(_ view: some View, named name: String, size: CGSize) throws -> CGImage {
        StarFontLoader.registerFonts()
        try? FileManager.default.createDirectory(
            at: Self.outputDirectory, withIntermediateDirectories: true
        )
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        let image = try #require(renderer.cgImage, "\(name) did not render")

        if let destination = CGImageDestinationCreateWithURL(
            Self.outputDirectory.appendingPathComponent("\(name).png") as CFURL,
            "public.png" as CFString, 1, nil
        ) {
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        return image
    }

    // MARK: - Pieces

    private var sampleDays: [ExtendedDay] {
        [
            ("TUE", "Sunny", "68", "84"),
            ("WED", "Partly Sunny", "70", "86"),
            ("THU", "Chance Showers", "72", "85"),
        ].map { day, condition, low, high in
            ExtendedDay(
                dayName: day,
                icon: IconMapper.smallIcon(for: "/icons/land/day/few"),
                condition: condition,
                low: low,
                high: high
            )
        }
    }

    /// A real display, drawn the way `WeatherStarView` draws one into a pane of this size.
    private func picture(in size: CGSize) -> some View {
        let space = DesignSpace.resolve(for: .auto, container: size)
        let metrics = StarMetrics(space: space, container: size)
        return ZStack {
            Color.black
            StarDisplayFrame(
                display: .extendedForecast,
                clockFormat: { _ in ("10:42:08 AM", "MON OCT 26") }
            ) {
                ExtendedForecastDisplay(days: sampleDays, screenIndex: 0)
            }
            .environment(\.starMetrics, metrics)
            .frame(width: metrics.scaledSize.width, height: metrics.scaledSize.height)
        }
    }

    private func deck(finish: TelevisionFinish, insets: EdgeInsets) -> some View {
        ControlDeck(
            content: ControlDeckContent(
                channels: DisplayIdentifier.rotationOrder.map {
                    // Two still loading, so the dimmed state is in the picture too.
                    .init(display: $0, isReady: $0 != .hazards && $0 != .spcOutlook)
                },
                activeDisplay: .extendedForecast,
                conditions: "TAMPA, FL  74°  CLEAR",
                nowPlaying: "Fair Weather",
                isRotating: true,
                isSoundOn: true,
                isPictureOn: true,
                clock: { _ in "10:42 AM" },
                clockInterval: 15,
                onSelect: { _ in },
                onPrevious: {},
                onNext: {},
                onToggleRotation: {},
                onToggleSound: {},
                onSettings: {},
                onPower: {}
            ),
            finish: finish,
            insets: insets
        )
    }

    // MARK: - Postures

    @Test("Tabletop: the picture above the crease, the deck below it")
    func tabletop() throws {
        let posture = FoldPosture.tabletop(crease: DuoScreens.tabletopCrease)
        let size = DuoScreens.innerSideways
        let panes = try #require(posture.panes(in: size))

        for finish in TelevisionFinish.allCases {
            let view = FoldSplit(posture: posture) {
                picture(in: panes.first.size)
                    .overlay { GlassGlare(hingeAngle: 115) }
            } second: { insets in
                deck(finish: finish, insets: insets)
            }
            .background(Color.black)

            let image = try render(view, named: "duo-tabletop-\(finish.rawValue)", size: size)
            try expectCreaseIsDark(image, crease: DuoScreens.tabletopCrease)
        }
    }

    @Test("Book: the set on the leading page, the deck on the trailing one")
    func book() throws {
        let posture = FoldPosture.book(crease: DuoScreens.bookCrease)
        let size = DuoScreens.innerUpright
        let panes = try #require(posture.panes(in: size))

        let set = TelevisionGeometry.resolve(
            container: panes.first.size,
            pictureAspect: DesignSpace.standard.aspectRatio,
            showsControls: false
        )
        let view = FoldSplit(posture: posture) {
            StarTelevision(geometry: set, finish: .woodgrain, showsControls: false) {
                picture(in: set.screenSize)
            }
        } second: { insets in
            deck(finish: .woodgrain, insets: insets)
        }
        .background(Color.black)

        let image = try render(view, named: "duo-book", size: size)
        try expectCreaseIsDark(image, crease: DuoScreens.bookCrease)
    }

    /// Every pixel down the middle of the crease is near black: nothing — no picture, no
    /// button, no panel edge — has been laid across the fold.
    private func expectCreaseIsDark(_ image: CGImage, crease: CGRect) throws {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(pixels.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        })
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)

        // The crease's centre line, in image rows and columns. CGContext rows run bottom-up.
        let isVertical = crease.height > crease.width
        let samples: [(x: Int, y: Int)] = isVertical
            ? (0..<height).map { (Int(crease.midX), $0) }
            : (0..<width).map { ($0, height - 1 - Int(crease.midY)) }

        let lit = samples.filter { x, y in
            let offset = (y * width + x) * 4
            return max(data[offset], data[offset + 1], data[offset + 2]) > 24
        }
        #expect(lit.isEmpty, "\(lit.count) of \(samples.count) pixels on the crease are lit")
    }
}
#endif
