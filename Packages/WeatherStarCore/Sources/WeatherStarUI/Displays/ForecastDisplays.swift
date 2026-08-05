import SwiftUI
import WeatherStarKit

/// Extended Forecast: three day panels per screen, drawn over background 2's
/// artwork. Layout from `_extended-forecast.scss`.
struct ExtendedForecastDisplay: View {
    @Environment(\.starMetrics) private var metrics
    @Environment(\.starContentWidth) private var contentWidth

    let days: [ExtendedDay]
    /// Screen 0 shows days 1–3, screen 1 shows days 4–6.
    let screenIndex: Int

    private enum Layout {
        /// Outer panel, matching the background artwork.
        static let panelWidth: CGFloat = 174
        static let panelGap: CGFloat = 20
        static let firstLeft: CGFloat = 38
        /// Text box inside the panel — upstream's `.day` is 155pt wide, narrower than
        /// the artwork. Laying text out against the full panel width let it run past
        /// the border.
        static let textWidth: CGFloat = 155
        static let panelTop: CGFloat = 10
        static let dateY: CGFloat = 8
        static let conditionY: CGFloat = 50
        static let conditionHeight: CGFloat = 84
        static let iconY: CGFloat = 132
        static let temperatureY: CGFloat = 202
        /// Matches the background artwork's panel, 100..397 in design space.
        static let panelHeight: CGFloat = 297
        static let iconHeight: CGFloat = 75
    }

    private var visibleDays: [ExtendedDay] {
        let start = screenIndex * 3
        guard start < days.count else { return [] }
        return Array(days[start..<min(start + 3, days.count)])
    }

    /// Left edge of the panel group, centered when the canvas is wider than 640.
    private var groupLeft: CGFloat {
        let groupWidth = 3 * Layout.panelWidth + 2 * Layout.panelGap
        return contentWidth > 640
            ? (contentWidth - groupWidth) / 2
            : Layout.firstLeft
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(visibleDays.enumerated()), id: \.element.id) { index, day in
                let left = groupLeft + CGFloat(index) * (Layout.panelWidth + Layout.panelGap)
                panel(day)
                    .designPosition(x: left, y: Layout.panelTop)
            }
        }
    }

    private func panel(_ day: ExtendedDay) -> some View {
        ZStack(alignment: .top) {
            StarText(
                day.dayName,
                font: .regular,
                size: 32,
                color: StarColor.title,
                alignment: .center
            )
            .designFrame(width: Layout.panelWidth, alignment: .center)
            .designOffset(y: Layout.dateY)

            // Wrapped by the layout, and allowed to condense a little so a long
            // forecast like "Showers And Thunderstorms" fits two lines.
            StarText(
                day.condition,
                font: .regular,
                size: 32,
                alignment: .center,
                lineLimit: 3,
                minimumScaleFactor: 0.55
            )
            // No x offset. This frame is narrower than the panel and the enclosing ZStack
            // already centres it; adding half the difference as an inset applied the
            // centring twice, pushing the text against the panel's right edge and
            // truncating the last line.
            .designFrame(width: Layout.textWidth, height: Layout.conditionHeight, alignment: .top)
            .designOffset(y: Layout.conditionY)

            PixelImage(day.icon, height: Layout.iconHeight)
                .designFrame(width: Layout.panelWidth, alignment: .center)
                .designOffset(y: Layout.iconY)

            // Lo on the left in blue, Hi on the right in yellow.
            HStack(spacing: 0) {
                temperatureBlock(label: "Lo", value: day.low, color: StarColor.extendedLow)
                temperatureBlock(label: "Hi", value: day.high, color: StarColor.title)
            }
            .designFrame(width: Layout.panelWidth)
            .designOffset(y: Layout.temperatureY)
        }
        .designFrame(width: Layout.panelWidth, height: Layout.panelHeight, alignment: .top)
    }

    private func temperatureBlock(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 0) {
            StarText(label, font: .regular, size: 32, color: color, alignment: .center)
            StarText(value, font: .large, size: 32, alignment: .center)
        }
        .designFrame(width: Layout.panelWidth / 2, alignment: .center)
    }
}

/// Local Forecast: the narrative text, scrolled vertically. Layout from
/// `_local-forecast.scss`.
struct LocalForecastDisplay: View {
    @Environment(\.starMetrics) private var metrics
    @Environment(\.starContentWidth) private var contentWidth

    let data: LocalForecastData
    let scrollOffset: Double

    fileprivate enum Layout {
        static let boxMargin: CGFloat = 64
        static let innerInset: CGFloat = 10
        static let top: CGFloat = 15
        static let viewportHeight: CGFloat = 280
        static let lineSpacing: CGFloat = 8
        static let paragraphSpacing: CGFloat = 20
    }

    private var textWidth: CGFloat {
        contentWidth - 2 * Layout.boxMargin - 2 * Layout.innerInset
    }

    /// Total height of the wrapped narrative, so the engine knows how far to scroll.
    ///
    /// Computed from font metrics rather than read back from the rendered view: the
    /// view is clipped to the viewport, so measuring it always returned the viewport
    /// height and the scroll distance came out as zero.
    @MainActor
    static func contentHeight(for data: LocalForecastData, textWidth: CGFloat) -> CGFloat {
        data.paragraphs.reduce(0) { total, paragraph in
            total + StarFont.regular.textHeight(
                paragraph,
                size: 32,
                width: textWidth,
                lineSpacing: Layout.lineSpacing
            ) + Layout.paragraphSpacing
        }
    }

    /// Viewport the narrative scrolls within.
    @MainActor
    static var viewport: CGFloat { Layout.viewportHeight }

    @MainActor
    static func textWidth(for contentWidth: CGFloat) -> CGFloat {
        contentWidth - 2 * Layout.boxMargin - 2 * Layout.innerInset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(data.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                StarText(
                    paragraph,
                    font: .regular,
                    size: 32,
                    lineSpacing: Layout.lineSpacing
                )
                .designFrame(width: textWidth, alignment: .leading)
                .designPadding(.bottom, Layout.paragraphSpacing)
            }
        }
        .designFrame(width: textWidth, alignment: .topLeading)
        // Rasterised once so scrolling translates a layer instead of re-running Core Text
        // over every wrapped paragraph. See the note in `TableDisplays`.
        .drawingGroup()
        .designOffset(y: -scrollOffset)
        .designFrame(width: textWidth, height: Layout.viewportHeight, alignment: .topLeading)
        .clipped()
        .designOffset(x: Layout.boxMargin + Layout.innerInset, y: Layout.top)
    }
}

/// Almanac: sunrise/sunset for the next three days plus upcoming moon phases.
/// Layout from `_almanac.scss`.
struct AlmanacDisplay: View {
    @Environment(\.starMetrics) private var metrics
    @Environment(\.starContentWidth) private var contentWidth

    let data: AlmanacData

    private enum Layout {
        static let sunTop: CGFloat = 3
        static let labelColumn: CGFloat = 150
        static let sideMargin: CGFloat = 20
        static let rowHeight: CGFloat = 34
        static let moonIconHeight: CGFloat = 60
    }

    /// Three days fit the standard canvas; the wider one fits four.
    private var visibleDays: [AlmanacDay] {
        Array(data.days.prefix(contentWidth > 640 ? 4 : 3))
    }

    /// Day columns share whatever is left after the row-label column.
    ///
    /// Upstream sizes these to content with a fixed 90pt gap, which at these font
    /// metrics overflows 640pt once the day names are spelled out in full. Dividing
    /// the remaining width keeps every column inside the canvas at any size.
    private var dayColumnWidth: CGFloat {
        let available = contentWidth - Layout.labelColumn - 2 * Layout.sideMargin
        return max(available / CGFloat(max(visibleDays.count, 1)), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sunGrid
                .designPadding(.top, Layout.sunTop)
            moonSection
                .designPadding(.top, 12)
        }
        .designFrame(width: contentWidth, alignment: .top)
    }

    private var sunGrid: some View {
        VStack(spacing: 0) {
            // Header row: an empty label cell then one day name per column.
            gridRow(label: "") { day in
                StarText(
                    day.dayName,
                    font: .regular,
                    size: 32,
                    color: StarColor.columnHeaderText,
                    alignment: .center,
                    lineLimit: 1,
                    minimumScaleFactor: 0.6
                )
            }
            gridRow(label: "Sunrise:") { day in
                StarText(
                    day.sunrise,
                    font: .regular,
                    size: 32,
                    alignment: .center,
                    lineLimit: 1,
                    minimumScaleFactor: 0.7
                )
            }
            gridRow(label: "Sunset:") { day in
                StarText(
                    day.sunset,
                    font: .regular,
                    size: 32,
                    alignment: .center,
                    lineLimit: 1,
                    minimumScaleFactor: 0.7
                )
            }
        }
        .designFrame(width: contentWidth, alignment: .leading)
    }

    private func gridRow<Cell: View>(
        label: String,
        @ViewBuilder cell: @escaping (AlmanacDay) -> Cell
    ) -> some View {
        HStack(spacing: 0) {
            StarText(
                label,
                font: .regular,
                size: 32,
                alignment: .trailing,
                lineLimit: 1
            )
            .designFrame(width: Layout.labelColumn, alignment: .trailing)

            ForEach(visibleDays) { day in
                cell(day)
                    .designFrame(width: dayColumnWidth, alignment: .center)
            }
        }
        .designFrame(height: Layout.rowHeight)
        .designOffset(x: Layout.sideMargin)
    }

    private var moonSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            StarText("Moon Data:", font: .regular, size: 32, color: StarColor.columnHeaderText)
                .designOffset(x: 63)

            // The wide canvas has room for a fifth phase. Columns share the width so
            // the row cannot grow past the canvas.
            let phases = Array(data.moonPhases.prefix(contentWidth > 640 ? 5 : 4))
            let moonColumnWidth = (contentWidth - 2 * Layout.sideMargin)
                / CGFloat(max(phases.count, 1))

            HStack(spacing: 0) {
                ForEach(phases) { phase in
                    VStack(spacing: 0) {
                        StarText(
                            phase.phase.rawValue,
                            font: .regular,
                            size: 32,
                            alignment: .center,
                            lineLimit: 1,
                            minimumScaleFactor: 0.7
                        )
                        PixelImage(IconMapper.moonIcon(for: phase.phase), height: Layout.moonIconHeight)
                        StarText(
                            Self.monthDay(phase.date),
                            font: .regular,
                            size: 32,
                            alignment: .center,
                            lineLimit: 1,
                            minimumScaleFactor: 0.7
                        )
                    }
                    .designFrame(width: moonColumnWidth, alignment: .center)
                }
            }
            .designFrame(width: contentWidth - 2 * Layout.sideMargin, alignment: .center)
            .designOffset(x: Layout.sideMargin)
        }
    }

    /// "Mar 14".
    private static func monthDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}

/// Hazards: active NWS alerts on a red field, no header. Layout from
/// `_hazards.scss`.
struct HazardsDisplay: View {
    @Environment(\.starMetrics) private var metrics
    @Environment(\.starContentWidth) private var contentWidth

    let hazards: [HazardItem]

    private enum Layout {
        static let sideMargin: CGFloat = 80
        static let top: CGFloat = 10
        static let itemSpacing: CGFloat = 20
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(hazards) { hazard in
                StarPlainText(
                    "\(hazard.event.uppercased())\(hazard.detail.isEmpty ? "" : " - \(hazard.detail.uppercased())")",
                    font: .regular,
                    size: 32,
                    lineSpacing: 6
                )
                .designFrame(
                    width: contentWidth - 2 * Layout.sideMargin,
                    alignment: .leading
                )
                .designPadding(.bottom, Layout.itemSpacing)
            }
        }
        .designOffset(x: Layout.sideMargin, y: Layout.top)
    }
}
