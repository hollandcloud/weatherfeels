import SwiftUI
import Testing
@testable import WeatherStarUI

/// The scrolling tables, against the blue panel they are drawn on.
///
/// This is the rule that was broken in production. Background 1 insets its panel from the
/// canvas edges, and the wide canvas also insets the 640pt content block by 107pt, which
/// carries every column comfortably clear. The standard canvas has no content inset, so the
/// same column numbers put the Hourly hour label off the panel's left edge and its wind
/// value off the right, onto the orange field either side.
///
/// It shipped that way — it is visible in the 1.1 iPad screenshots — because nothing
/// compared the two numbers. Arithmetic can, and a canvas nobody looks at often is exactly
/// where arithmetic earns its keep.
@Suite("Table columns fit the blue panel")
@MainActor
struct TableColumnFitTests {
    /// Widest realistic content, so the check is against the worst case and not today's
    /// weather. Sizes are the ones the displays actually draw at.
    private static let bodySize: CGFloat = 32

    private func width(_ text: String, _ font: StarFont = .large) -> CGFloat {
        StarFontLoader.registerFonts()
        return font.textWidth(text, size: Self.bodySize)
    }

    /// The Hourly table on the 640pt canvas, which is what the television shows and what
    /// an iPad in landscape has always used.
    @Test("Hourly stays inside the panel on the standard canvas")
    func hourlyFitsStandardCanvas() {
        let panel = BluePanelInset.bounds(canvasWidth: DesignSpace.standard.width)
        let columns = HourlyDisplay.Columns.standard

        // Left edge: the hour label starts at its column and runs right.
        #expect(
            columns.hour >= panel.lowerBound,
            "hour column starts at \(columns.hour), panel starts at \(panel.lowerBound)"
        )

        // Right edge: the wind value is trailing-aligned in its own box, so the box's end
        // is the rightmost ink.
        let windEnd = columns.wind + columns.windWidth
        #expect(
            windEnd <= panel.upperBound,
            "wind column ends at \(windEnd), panel ends at \(panel.upperBound)"
        )
    }

    /// The wide canvas is a different sum: the content block is inset before any of these
    /// positions apply, so the columns are measured after that shift.
    @Test("Hourly stays inside the panel on the wide canvas")
    func hourlyFitsWideCanvas() {
        let space = DesignSpace.wide
        let panel = BluePanelInset.bounds(canvasWidth: space.width)
        let columns = HourlyDisplay.Columns.wide
        let inset = space.contentInset

        #expect(columns.hour + inset >= panel.lowerBound)
        #expect(columns.wind + columns.windWidth + inset <= panel.upperBound)
    }

    /// The other two tables were already inside the panel and must stay there. Travel in
    /// particular clears the right edge by only a couple of points, so it is one careless
    /// column nudge from the same bug.
    @Test("Travel and Latest Observations stay inside the panel")
    func otherTablesFitStandardCanvas() {
        let panel = BluePanelInset.bounds(canvasWidth: DesignSpace.standard.width)

        // Travel: city label on the left, high temperature box on the right.
        let travelLeft: CGFloat = 80
        let travelRight: CGFloat = 510 + 72
        #expect(travelLeft >= panel.lowerBound, "Travel starts at \(travelLeft)")
        #expect(travelRight <= panel.upperBound, "Travel ends at \(travelRight)")

        // Latest Observations declares its own right edge.
        let observationsLeft: CGFloat = 64
        let observationsRight: CGFloat = 576
        #expect(observationsLeft >= panel.lowerBound)
        #expect(observationsRight <= panel.upperBound)
    }

    /// Repositioning the columns is only safe if the text still has somewhere to go. The
    /// standard set buys its room from the gap after the hour label, so that gap is the one
    /// worth measuring rather than assuming.
    @Test("The standard columns leave room for the widest text")
    func standardColumnsDoNotCollide() {
        let columns = HourlyDisplay.Columns.standard

        // "12 AM" is the widest hour label; it must clear the icon.
        let hourEnd = columns.hour + width("12 AM")
        #expect(
            hourEnd <= columns.icon,
            "hour label reaches \(hourEnd), icon starts at \(columns.icon)"
        )

        // The icon box must clear the temperature.
        let iconEnd = columns.icon + HourlyDisplay.Layout.iconWidth
        #expect(iconEnd <= columns.temperature, "icon reaches \(iconEnd)")

        // Three-digit temperatures exist, and both columns are left-anchored.
        let temperatureEnd = columns.temperature + width("100")
        #expect(temperatureEnd <= columns.apparent, "temperature reaches \(temperatureEnd)")

        let apparentEnd = columns.apparent + width("-40")
        #expect(apparentEnd <= columns.wind, "apparent reaches \(apparentEnd)")

        // The widest wind string upstream's own box was sized for.
        #expect(
            width("NNW 15") <= columns.windWidth,
            "\"NNW 15\" needs \(width("NNW 15"))pt of \(columns.windWidth)pt"
        )
    }
}
