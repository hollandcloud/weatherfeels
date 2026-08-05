import SwiftUI
import WeatherStarKit

/// Latest Observations: a table of nearby stations. Columns from
/// `_latest-observations.scss`.
struct LatestObservationsDisplay: View {
    @Environment(\.starMetrics) private var metrics
    @Environment(\.starContentWidth) private var contentWidth

    let rows: [ObservationRow]
    let unitSystem: UnitSystem

    /// Column x positions, which differ between the standard and wide canvases.
    ///
    /// Upstream's `.wide.enhanced` rules move every column right and reveal the
    /// "Like" (apparent temperature) column that does not fit at 640pt. Using the
    /// narrow positions on the wide canvas left the extra width unused *and* kept the
    /// gaps too tight, so long station names ran over the temperature.
    private struct Columns {
        let location: CGFloat
        let temperature: CGFloat
        let apparent: CGFloat?
        let weather: CGFloat
        let wind: CGFloat
        /// Right edge available to the last column.
        let rightEdge: CGFloat

        static let standard = Columns(
            location: 64, temperature: 230, apparent: nil,
            weather: 280, wind: 430, rightEdge: 576
        )

        /// Positions from `_latest-observations.scss` under `.wide.enhanced`.
        static let wide = Columns(
            location: 64, temperature: 320, apparent: 380,
            weather: 470, wind: 630, rightEdge: 790
        )
    }

    private enum Layout {
        static let headerY: CGFloat = 0
        static let rowHeight: CGFloat = 40
        /// Clears the column headers, whose descenders reached into row one.
        static let firstRowY: CGFloat = 32
        /// Keeps adjacent columns visually separated once each is clipped to width.
        static let gutter: CGFloat = 16
    }

    private var columns: Columns {
        metrics.space.mode == .wide ? .wide : .standard
    }

    var body: some View {
        let columns = self.columns

        return ZStack(alignment: .topLeading) {
            // Column headers sit above the rows, in the small face.
            StarText(
                unitSystem == .us ? "\(degreeSign)F" : "\(degreeSign)C",
                font: .small,
                size: 32,
                color: StarColor.body
            )
            .designPosition(x: columns.temperature, y: Layout.headerY)

            if let apparent = columns.apparent {
                StarText("Like", font: .small, size: 32)
                    .designPosition(x: apparent, y: Layout.headerY)
            }

            StarText("Weather", font: .small, size: 32)
                .designPosition(x: columns.weather, y: Layout.headerY)

            StarText("Wind", font: .small, size: 32)
                .designPosition(x: columns.wind, y: Layout.headerY)

            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let y = Layout.firstRowY + CGFloat(index) * Layout.rowHeight

                cell(row.location, from: columns.location, to: columns.temperature)
                    .designPosition(x: columns.location, y: y)

                cell(
                    row.temperature,
                    from: columns.temperature,
                    to: columns.apparent ?? columns.weather
                )
                .designPosition(x: columns.temperature, y: y)

                // Apparent temperature only appears on the wide canvas, coloured to
                // say whether it is a heat index or a wind chill.
                if let apparent = columns.apparent {
                    cell(
                        row.apparent,
                        from: apparent,
                        to: columns.weather,
                        color: row.isHeatIndex
                            ? StarColor.heatIndex
                            : (row.isWindChill ? StarColor.windChill : StarColor.body)
                    )
                    .designPosition(x: apparent, y: y)
                }

                cell(row.weather, from: columns.weather, to: columns.wind)
                    .designPosition(x: columns.weather, y: y)

                cell(row.wind, from: columns.wind, to: columns.rightEdge)
                    .designPosition(x: columns.wind, y: y)
            }
        }
    }

    /// One table cell, clipped to the space before the next column so it cannot
    /// bleed into its neighbour whatever the station name length.
    private func cell(
        _ text: String,
        from start: CGFloat,
        to end: CGFloat,
        color: Color = StarColor.body
    ) -> some View {
        // Condense to fit rather than clip: station names like "Orlando Executive"
        // are wider than the column at full size. Clipping stays as the backstop.
        StarText(
            text,
            font: .regular,
            size: 32,
            color: color,
            lineLimit: 1,
            minimumScaleFactor: 0.6
        )
        .designFrame(width: max(end - start - Layout.gutter, 1), alignment: .leading)
        .clipped()
    }
}

/// Hourly Forecast: a scrolling table of the next 24 hours. Columns from
/// `_hourly.scss`.
struct HourlyDisplay: View {
    @Environment(\.starMetrics) private var metrics
    @Environment(\.starContentWidth) private var contentWidth

    let rows: [HourlyRow]
    /// Vertical scroll offset in design points, driven by the engine's base count.
    let scrollOffset: Double

    private enum Column {
        static let hour: CGFloat = 25
        static let icon: CGFloat = 255
        static let temperature: CGFloat = 355
        static let apparent: CGFloat = 425
        static let wind: CGFloat = 505
        static let rowHeight: CGFloat = 72
        static let iconWidth: CGFloat = 70
        /// Runs to the right edge. Upstream's 100pt box could not hold a
        /// three-letter direction plus a two-digit speed ("NNW 15" needs 115pt).
        static let windWidth: CGFloat = 135
    }

    /// Height of the scrolling viewport, below the header and above the ticker.
    private var viewportHeight: CGFloat {
        metrics.space.scrollHeight
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Header band sits above the scrolling area and does not move.
            StarColor.columnHeaderBackground
                .designFrame(width: contentWidth, height: 20)

            StarText("TEMP", font: .small, size: 32, color: StarColor.columnHeaderText)
                .designPosition(x: Column.temperature, y: -8)
            StarText("LIKE", font: .small, size: 32, color: StarColor.columnHeaderText)
                .designPosition(x: 435, y: -8)
            StarText("WIND", font: .small, size: 32, color: StarColor.columnHeaderText)
                .designPosition(x: 535, y: -8)

            // Rasterised once, then translated. Scrolling changes only the offset, but
            // these rows are ~24 × 4 labels and `StarText` is six Core Text passes each —
            // about 576 rasterisations — so re-rendering them per scroll step is what put
            // Hourly Forecast at half a frame a second on an Apple TV HD.
            rowsView
                .drawingGroup()
                .designOffset(y: 20 - scrollOffset)
        }
        .designFrame(width: contentWidth, height: viewportHeight, alignment: .topLeading)
        .clipped()
    }

    private var rowsView: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let y = CGFloat(index) * Column.rowHeight + 8

                StarText(row.hourLabel, font: .large, size: 32, color: StarColor.title)
                    .designPosition(x: Column.hour, y: y)

                PixelImage(row.icon, width: Column.iconWidth)
                    .designPosition(x: Column.icon, y: y - 6)

                StarText(row.temperature, font: .large, size: 32, color: StarColor.title)
                    .designPosition(x: Column.temperature, y: y)

                StarText(
                    row.apparent,
                    font: .large,
                    size: 32,
                    color: row.isHeatIndex
                        ? StarColor.heatIndex
                        : (row.isWindChill ? StarColor.windChill : StarColor.title)
                )
                .designPosition(x: Column.apparent, y: y)

                StarText(
                    row.wind,
                    font: .large,
                    size: 32,
                    color: StarColor.title,
                    alignment: .trailing,
                    lineLimit: 1,
                    minimumScaleFactor: 0.8
                )
                .designFrame(width: Column.windWidth, alignment: .trailing)
                .designPosition(x: Column.wind, y: y)
            }
        }
        .designFrame(
            width: contentWidth,
            height: max(CGFloat(rows.count) * Column.rowHeight, 1),
            alignment: .topLeading
        )
    }

    /// Total content height, so the parent can compute scroll timing.
    /// Total height of all rows, for the engine's scroll timing.
    static func contentHeight(rowCount: Int) -> CGFloat {
        CGFloat(rowCount) * Column.rowHeight + 20
    }
}

/// Travel Forecast: fixed national cities with tomorrow's high and low. Columns
/// from `_travel.scss`.
struct TravelDisplay: View {
    @Environment(\.starMetrics) private var metrics
    @Environment(\.starContentWidth) private var contentWidth

    let rows: [TravelRow]
    let scrollOffset: Double

    private enum Column {
        static let city: CGFloat = 80
        static let icon: CGFloat = 330
        static let low: CGFloat = 455
        static let high: CGFloat = 510
        static let rowHeight: CGFloat = 72
        static let iconWidth: CGFloat = 47
        static let temperatureWidth: CGFloat = 50
        /// "HIGH" needs 61pt in the small face, so the 60pt box lost its final H.
        static let highWidth: CGFloat = 72
    }

    private var viewportHeight: CGFloat { metrics.space.scrollHeight }

    var body: some View {
        ZStack(alignment: .topLeading) {
            StarColor.columnHeaderBackground
                .designFrame(width: contentWidth, height: 20)

            StarText("LOW", font: .small, size: 32, color: StarColor.columnHeaderText, alignment: .center)
                .designFrame(width: Column.temperatureWidth, alignment: .center)
                .designPosition(x: Column.low, y: -8)

            StarText("HIGH", font: .small, size: 32, color: StarColor.columnHeaderText, alignment: .center)
                .designFrame(width: Column.highWidth, alignment: .center)
                .designPosition(x: Column.high, y: -8)

            // Rasterised once, then translated. Scrolling changes only the offset, but
            // these rows are ~24 × 4 labels and `StarText` is six Core Text passes each —
            // about 576 rasterisations — so re-rendering them per scroll step is what put
            // Hourly Forecast at half a frame a second on an Apple TV HD.
            rowsView
                .drawingGroup()
                .designOffset(y: 20 - scrollOffset)
        }
        .designFrame(width: contentWidth, height: viewportHeight, alignment: .topLeading)
        .clipped()
    }

    private var rowsView: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let y = CGFloat(index) * Column.rowHeight + 8

                StarText(
                    row.city,
                    font: .large,
                    size: 32,
                    color: StarColor.title,
                    lineLimit: 1,
                    minimumScaleFactor: 0.8
                )
                .designFrame(width: Column.icon - Column.city - 10, alignment: .leading)
                .clipped()
                .designPosition(x: Column.city, y: y)

                if let icon = row.icon {
                    PixelImage(icon, width: Column.iconWidth)
                        .designPosition(x: Column.icon, y: y - 6)
                }

                StarText(row.low, font: .large, size: 32, color: StarColor.title, alignment: .center)
                    .designFrame(width: Column.temperatureWidth, alignment: .center)
                    .designPosition(x: Column.low, y: y)

                StarText(
                    row.high,
                    font: .large,
                    size: 32,
                    color: StarColor.title,
                    alignment: .center,
                    lineLimit: 1
                )
                .designFrame(width: Column.highWidth, alignment: .center)
                .designPosition(x: Column.high, y: y)
            }
        }
        .designFrame(
            width: contentWidth,
            height: max(CGFloat(rows.count) * Column.rowHeight, 1),
            alignment: .topLeading
        )
    }

    /// Total height of all rows, for the engine's scroll timing.
    static func contentHeight(rowCount: Int) -> CGFloat {
        CGFloat(rowCount) * Column.rowHeight + 20
    }
}
