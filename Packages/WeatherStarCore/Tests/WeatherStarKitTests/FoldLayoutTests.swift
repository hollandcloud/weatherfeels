import SwiftUI
import Testing
@testable import WeatherStarKit
@testable import WeatherStarUI

/// iPhone Duo's shapes, in points, as the app receives them.
///
/// From the simulator's own device profile: the outer display is 1398×2034 pixels and the
/// inner 2853×2007, both at 3×. The crease is the 40pt band the system reports as the inner
/// display's division region — a zero-width fold line padded 20pt either side.
enum DuoScreens {
    static let outerPortrait = CGSize(width: 466, height: 678)
    static let outerLandscape = CGSize(width: 678, height: 466)
    /// Open, held upright: wider than tall, crease running top to bottom.
    static let innerUpright = CGSize(width: 951, height: 669)
    /// Open, turned on its side: taller than wide, crease running side to side.
    static let innerSideways = CGSize(width: 669, height: 951)

    static let bookCrease = CGRect(x: 951 / 2 - 20, y: 0, width: 40, height: 669)
    static let tabletopCrease = CGRect(x: 0, y: 951 / 2 - 20, width: 669, height: 40)
}

@Suite("Fold posture")
struct FoldPostureTests {
    @Test("No division region is a flat screen")
    func noDivisionIsFlat() {
        #expect(FoldPosture.resolve(container: DuoScreens.innerUpright, divisions: []) == .flat)
        #expect(FoldPosture.resolve(container: .zero, divisions: [DuoScreens.bookCrease]) == .flat)
    }

    @Test("A crease running top to bottom is a book")
    func bookFromVerticalCrease() {
        let posture = FoldPosture.resolve(
            container: DuoScreens.innerUpright, divisions: [DuoScreens.bookCrease]
        )
        #expect(posture == .book(crease: DuoScreens.bookCrease))
    }

    @Test("A crease running side to side is a tabletop")
    func tabletopFromHorizontalCrease() {
        let posture = FoldPosture.resolve(
            container: DuoScreens.innerSideways, divisions: [DuoScreens.tabletopCrease]
        )
        #expect(posture == .tabletop(crease: DuoScreens.tabletopCrease))
    }

    /// A system that reported the bare fold line, with no margin either side, still has to be
    /// read as a crease rather than discarded as an empty rectangle.
    @Test("A crease with no margins is still a crease")
    func zeroWidthCrease() {
        let line = CGRect(x: 475.5, y: 0, width: 0, height: 669)
        let posture = FoldPosture.resolve(container: DuoScreens.innerUpright, divisions: [line])
        #expect(posture == .book(crease: line))
    }

    /// Two apps side by side on the open inner display: a pane that only grazes the fold must
    /// not be cut into a sliver and the rest.
    @Test("A crease too near an edge leaves the screen whole")
    func creaseNearEdgeIsIgnored() {
        let pane = CGSize(width: 560, height: 669)
        let nearEdge = CGRect(x: 520, y: 0, width: 40, height: 669)
        #expect(FoldPosture.resolve(container: pane, divisions: [nearEdge]) == .flat)
    }

    @Test("A crease outside the view does not divide it")
    func creaseOutsideIsIgnored() {
        let pane = CGSize(width: 400, height: 669)
        let elsewhere = CGRect(x: 455, y: 0, width: 40, height: 669)
        #expect(FoldPosture.resolve(container: pane, divisions: [elsewhere]) == .flat)
    }

    @Test("The panes and the crease cover the screen exactly")
    func panesTileTheScreen() throws {
        let cases: [(FoldPosture, CGSize)] = [
            (.book(crease: DuoScreens.bookCrease), DuoScreens.innerUpright),
            (.tabletop(crease: DuoScreens.tabletopCrease), DuoScreens.innerSideways),
        ]
        for (posture, size) in cases {
            let panes = try #require(posture.panes(in: size))
            let crease: CGRect = switch posture {
            case .book(let crease), .tabletop(let crease): crease
            case .flat: .zero
            }
            #expect(!panes.first.intersects(crease), "\(posture): first pane overlaps the crease")
            #expect(!panes.second.intersects(crease), "\(posture): second pane overlaps the crease")
            let area = panes.first.width * panes.first.height
                + panes.second.width * panes.second.height
                + crease.width * crease.height
            #expect(abs(area - size.width * size.height) < 0.5, "\(posture): panes leave gaps")
        }
        #expect(FoldPosture.flat.panes(in: DuoScreens.innerUpright) == nil)
    }

    /// The tabletop's upper half is the picture's, and it is the same shape the picture was
    /// drawn for — the reason this posture is worth a layout of its own.
    @Test("A tabletop's upper half is close to the picture's own 4:3")
    func tabletopUpperHalfIsNearlyFourByThree() throws {
        let panes = try #require(
            FoldPosture.tabletop(crease: DuoScreens.tabletopCrease).panes(in: DuoScreens.innerSideways)
        )
        let aspect = panes.first.width / panes.first.height
        #expect(aspect > 1.3 && aspect < 1.55, "upper half is \(aspect):1")
    }
}

@Suite("Screen layout with a fold")
struct FoldPresentationTests {
    @Test("A bent fold splits the screen whatever canvas is chosen")
    func foldOutranksPreferences() {
        let fold = FoldPosture.book(crease: DuoScreens.bookCrease)
        for mode in LayoutMode.allCases {
            for landscapeSet in [false, true] {
                let layout = TelevisionPresentation.layout(
                    layoutMode: mode,
                    showsInLandscape: landscapeSet,
                    container: DuoScreens.innerUpright,
                    fold: fold
                )
                #expect(layout == .folded(fold), "\(mode), set in landscape \(landscapeSet)")
                #expect(layout.hasBuiltInControls)
            }
        }
    }

    /// With the device open flat or closed, nothing about the Duo should differ from any
    /// other phone of that shape.
    @Test("A flat screen keeps the cabinet rule it had")
    func flatKeepsTheCabinetRule() {
        func layout(_ size: CGSize, landscapeSet: Bool = false) -> TelevisionPresentation.Layout {
            TelevisionPresentation.layout(
                layoutMode: .auto, showsInLandscape: landscapeSet, container: size, fold: .flat
            )
        }
        #expect(layout(DuoScreens.outerPortrait) == .cabinet)
        #expect(layout(DuoScreens.innerSideways) == .cabinet)
        #expect(layout(DuoScreens.outerLandscape) == .picture)
        #expect(layout(DuoScreens.innerUpright) == .picture)
        #expect(layout(DuoScreens.innerUpright, landscapeSet: true) == .cabinet)
        #expect(!TelevisionPresentation.Layout.picture.hasBuiltInControls)
        #expect(TelevisionPresentation.Layout.cabinet.hasBuiltInControls)
    }
}

@Suite("Cabinet on a folded page")
struct FoldedCabinetTests {
    /// The leading page of a book: where the set stands while the deck has its buttons.
    private let page = FoldPosture.book(crease: DuoScreens.bookCrease)
        .panes(in: DuoScreens.innerUpright)!.first.size

    @Test("A set without buttons still fits its page, and keeps its speaker and plate")
    func buttonlessSetFits() {
        let set = TelevisionGeometry.resolve(
            container: page, pictureAspect: 4.0 / 3.0, showsControls: false
        )
        #expect(set.cabinetSize.width <= page.width)
        #expect(set.cabinetSize.height <= page.height)
        #expect(set.showsSpeaker)
        #expect(set.showsPlate)
    }

    /// Taking the buttons off must not change the set's size: it would otherwise jump as the
    /// device is bent and straightened.
    @Test("The buttons do not change the size of the set")
    func buttonsDoNotResize() {
        let with = TelevisionGeometry.resolve(container: page, pictureAspect: 4.0 / 3.0)
        let without = TelevisionGeometry.resolve(
            container: page, pictureAspect: 4.0 / 3.0, showsControls: false
        )
        #expect(with.cabinetSize == without.cabinetSize)
        #expect(with.screenSize == without.screenSize)
    }
}

@Suite("Fold split insets")
struct FoldSplitInsetTests {
    private let safeArea = EdgeInsets(top: 10, leading: 20, bottom: 30, trailing: 40)

    @Test("A pane takes only the insets of the edges it reaches")
    func insetsFollowTheEdges() {
        let size = DuoScreens.innerSideways
        let panes = FoldPosture.tabletop(crease: DuoScreens.tabletopCrease).panes(in: size)!

        let upper = FoldSplit<EmptyView, EmptyView>.insets(safeArea, touching: panes.first, in: size)
        #expect(upper == EdgeInsets(top: 10, leading: 20, bottom: 0, trailing: 40))

        let lower = FoldSplit<EmptyView, EmptyView>.insets(safeArea, touching: panes.second, in: size)
        #expect(lower == EdgeInsets(top: 0, leading: 20, bottom: 30, trailing: 40))
    }
}

@Suite("Glass reflection")
struct GlassGlareTests {
    @Test("The reflection follows the lid back and stops at the ends")
    func tiltIsMonotonicAndClamped() {
        let angles: [Double] = [0, 60, 90, 100, 120, 150, 180]
        let tilts = angles.map { GlassGlare.tilt(for: $0) }
        #expect(tilts == tilts.sorted())
        #expect(tilts.first == 0)
        #expect(tilts.last == 1)
        // No angle reported: drawn as for a lid stood up, not left out.
        #expect(GlassGlare.tilt(for: nil) > 0 && GlassGlare.tilt(for: nil) < 0.5)
    }
}

@Suite("Control deck layout")
struct ControlDeckLayoutTests {
    private static let allChannels = DisplayIdentifier.rotationOrder.count
    private static let defaultChannels = DisplayIdentifier.defaultEnabled.count

    /// The second pane of each posture: where the deck actually goes.
    private static let duoPanes: [(String, CGSize)] = [
        (
            "tabletop, lower half",
            FoldPosture.tabletop(crease: DuoScreens.tabletopCrease)
                .panes(in: DuoScreens.innerSideways)!.second.size
        ),
        (
            "book, trailing page",
            FoldPosture.book(crease: DuoScreens.bookCrease)
                .panes(in: DuoScreens.innerUpright)!.second.size
        ),
    ]

    @Test("Every button clears the touch floor")
    func touchTargetsClearTheFloor() {
        let panes = Self.duoPanes + [
            ("narrowest pane", CGSize(width: FoldPosture.minimumPane, height: 669)),
            ("shortest pane", CGSize(width: 669, height: FoldPosture.minimumPane)),
        ]
        for (name, size) in panes {
            for count in [1, Self.defaultChannels, Self.allChannels] {
                let layout = ControlDeckLayout.resolve(size: size, channelCount: count)
                #expect(layout.transportTouch >= ControlDeckLayout.minimumTouch, "\(name): transport")
                #expect(layout.channelHeight >= ControlDeckLayout.minimumTouch, "\(name): presets")
            }
        }
    }

    @Test("The transport fits across the deck")
    func transportFitsAcross() {
        let panes = Self.duoPanes + [("narrowest pane", CGSize(width: FoldPosture.minimumPane, height: 669))]
        for (name, size) in panes {
            let layout = ControlDeckLayout.resolve(size: size, channelCount: Self.allChannels)
            let perRow = layout.transportRows == 1 ? ControlDeckLayout.transportCount : 3
            let needed = layout.transportTouch * CGFloat(perRow) + layout.spacing * CGFloat(perRow - 1)
            #expect(needed <= size.width - layout.margin * 2 + 0.5, "\(name): \(needed)pt needed")
        }
    }

    /// On the Duo itself nothing should have to scroll: every display the app has is one
    /// press away in either posture.
    @Test("All twelve displays fit on the Duo without scrolling")
    func everyDisplayFitsOnTheDuo() {
        for (name, size) in Self.duoPanes {
            let layout = ControlDeckLayout.resolve(size: size, channelCount: Self.allChannels)
            #expect(!layout.channelsScroll, "\(name) scrolls")

            let rows = CGFloat((Self.allChannels + layout.channelColumns - 1) / layout.channelColumns)
            let stack = layout.readoutHeight
                + rows * layout.channelHeight + (rows - 1) * layout.spacing
                + layout.transportTouch
                + layout.spacing * 2
            #expect(stack <= size.height - layout.margin * 2 + 0.5, "\(name): \(stack)pt of deck")
        }
    }

    @Test("Presets come in an even number of columns, four when there is room")
    func evenColumns() {
        for (name, size) in Self.duoPanes {
            let layout = ControlDeckLayout.resolve(size: size, channelCount: Self.allChannels)
            #expect(layout.channelColumns % 2 == 0, "\(name)")
        }
        let tabletop = ControlDeckLayout.resolve(size: Self.duoPanes[0].1, channelCount: 8)
        let book = ControlDeckLayout.resolve(size: Self.duoPanes[1].1, channelCount: 8)
        #expect(tabletop.channelColumns == 4)
        #expect(book.channelColumns == 2)
    }

    @Test("Every display has a preset label short enough to print")
    func presetLabelsAreShort() {
        for display in DisplayIdentifier.allCases {
            #expect(display.presetLabel.count <= 10, "\(display): \(display.presetLabel)")
        }
    }
}
