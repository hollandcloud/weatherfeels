import SwiftUI
import Testing
@testable import WeatherStarUI

/// The cabinet's fitting rule, on every screen the app actually runs on.
///
/// Worth its own suite because the failure is invisible in code review and expensive in
/// practice: a cabinet fractionally too tall is cropped by the screen edge, and the first
/// place anyone would notice is an App Store screenshot. The rule is pure arithmetic on
/// two numbers, so it is checked as arithmetic.
@Suite("Television cabinet geometry")
struct TelevisionGeometryTests {
    /// Portrait sizes in points, as the app receives them.
    private static let portraitScreens: [(String, CGSize)] = [
        ("iPhone 16 Pro", CGSize(width: 402, height: 874)),
        ("iPhone 16 Pro Max", CGSize(width: 440, height: 956)),
        ("iPhone SE", CGSize(width: 320, height: 568)),
        ("iPad Pro 13-inch", CGSize(width: 1032, height: 1376)),
        ("iPad mini", CGSize(width: 744, height: 1133)),
        ("iPad Pro 11-inch", CGSize(width: 834, height: 1210)),
    ]

    private static let pictureAspect: CGFloat = 640.0 / 480.0

    @Test("The cabinet fits inside the screen it is given")
    func cabinetFits() {
        for (name, container) in Self.portraitScreens {
            let geometry = TelevisionGeometry.resolve(
                container: container, pictureAspect: Self.pictureAspect
            )
            #expect(
                geometry.cabinetSize.width <= container.width,
                "\(name): cabinet is \(geometry.cabinetSize.width)pt wide in \(container.width)pt"
            )
            #expect(
                geometry.cabinetSize.height <= container.height,
                "\(name): cabinet is \(geometry.cabinetSize.height)pt tall in \(container.height)pt"
            )
        }
    }

    /// The whole point of the treatment is that the picture is *not* distorted to fill a
    /// shape it was never drawn for, so the glass has to keep 4:3 exactly.
    @Test("The glass keeps the picture's aspect ratio")
    func screenKeepsAspect() {
        for (name, container) in Self.portraitScreens {
            let geometry = TelevisionGeometry.resolve(
                container: container, pictureAspect: Self.pictureAspect
            )
            let aspect = geometry.screenSize.width / geometry.screenSize.height
            #expect(
                abs(aspect - Self.pictureAspect) < 0.001,
                "\(name): glass is \(aspect):1, not \(Self.pictureAspect):1"
            )
        }
    }

    /// A set that only occupied a third of the screen would look like a mistake rather
    /// than a choice, and one filling it completely would lose the room it stands in.
    @Test("The set fills the screen without touching its edges")
    func cabinetIsWellProportioned() {
        for (name, container) in Self.portraitScreens {
            let geometry = TelevisionGeometry.resolve(
                container: container, pictureAspect: Self.pictureAspect
            )
            let widthShare = geometry.cabinetSize.width / container.width
            #expect(
                widthShare > 0.55,
                "\(name): cabinet takes only \(widthShare) of the width — it reads as an error"
            )
            #expect(
                widthShare < 0.99,
                "\(name): cabinet takes \(widthShare) of the width — no room left around it"
            )
        }
    }

    /// The cabinet is derived from the picture width, so every moulding has to scale with
    /// it. A fixed bezel would look like trim on a small screen and a picture frame on a
    /// large one.
    @Test("Cabinet trim scales with the picture")
    func trimIsProportional() {
        let small = TelevisionGeometry.resolve(
            container: CGSize(width: 320, height: 568), pictureAspect: Self.pictureAspect
        )
        let large = TelevisionGeometry.resolve(
            container: CGSize(width: 1032, height: 1376), pictureAspect: Self.pictureAspect
        )
        let ratio = large.screenSize.width / small.screenSize.width

        for (name, value) in [
            ("bezel", large.bezel / small.bezel),
            ("control strip", large.controlStrip / small.controlStrip),
            ("cabinet radius", large.cabinetCornerRadius / small.cabinetCornerRadius),
            ("screen radius", large.screenCornerRadius / small.screenCornerRadius),
        ] {
            #expect(
                abs(value - ratio) < 0.001,
                "\(name) scaled \(value)x where the picture scaled \(ratio)x"
            )
        }
    }

    /// The chin carries a maker's plate, a speaker and four buttons, and the buttons have
    /// a touch-target floor that does not shrink with the cabinet. On a phone that floor is
    /// most of the available width, so the other two have to give way — the plate ran off
    /// the end as "WEATHER…" before they did.
    @Test("Everything on the chin fits across it")
    func chinContentsFit() {
        for (name, container) in Self.portraitScreens {
            let geometry = TelevisionGeometry.resolve(
                container: container, pictureAspect: Self.pictureAspect
            )
            let chin = geometry.screenSize.width - geometry.bezel * 1.2
            var used = geometry.controlTouchSize * 4 + geometry.controlStrip * 0.10 * 3
            if geometry.showsSpeaker { used += geometry.controlStrip * 0.55 }
            if geometry.showsPlate { used += geometry.controlStrip * 1.9 }
            #expect(used <= chin, "\(name): chin needs \(used)pt of \(chin)pt")
        }
    }

    /// The buttons are the one thing that must never be dropped or shrunk away: they are
    /// the only way to reach settings or move the rotation while the set is on screen.
    @Test("The buttons always meet the touch-target floor")
    func buttonsStayTappable() {
        for (name, container) in Self.portraitScreens {
            let geometry = TelevisionGeometry.resolve(
                container: container, pictureAspect: Self.pictureAspect
            )
            #expect(
                geometry.controlTouchSize >= 44,
                "\(name): buttons are \(geometry.controlTouchSize)pt, under the 44pt floor"
            )
        }
    }

    /// Guards the degenerate inputs SwiftUI genuinely hands out — a `GeometryReader`
    /// reports `.zero` on its first pass — since the resolver divides by both of them.
    @Test("Degenerate containers do not produce a broken cabinet")
    func degenerateContainers() {
        for container in [CGSize.zero, CGSize(width: 0, height: 800), CGSize(width: 400, height: 0)] {
            let geometry = TelevisionGeometry.resolve(
                container: container, pictureAspect: Self.pictureAspect
            )
            #expect(geometry.screenSize.width > 0)
            #expect(geometry.screenSize.height > 0)
            #expect(geometry.cabinetSize.width.isFinite)
            #expect(geometry.cabinetSize.height.isFinite)
        }
    }
}
