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

/// Geometry shared by the two scrolling tables, whose column titles stay put while the
/// rows travel underneath them.
enum TableHeader {
    /// The coloured strip behind the titles.
    static let bandHeight: CGFloat = 20
    /// Titles are hung above the band's top edge so they sit *on* the strip.
    static let textY: CGFloat = -8

    /// Where the scrolling rows may begin — below the band, not level with it.
    ///
    /// The titles are 32pt type hung at `textY`, so their glyphs descend past the band's
    /// bottom edge. The rows used to be drawn after the header in the same `ZStack`,
    /// which put a scrolling row *over* the titles: every frame of the Hourly display
    /// had "TEMP LIKE WIND" tangled up in a row of numbers, which is how it was caught,
    /// in a store screenshot. Clipping the rows to start here means no row pixel can
    /// reach the titles whatever order the two draw in.
    static let contentTop: CGFloat = 28

    /// The scrolling half of a table: content that slides up behind a fixed header.
    @MainActor
    static func scrolling<Content: View>(
        viewportHeight: CGFloat,
        width: CGFloat,
        scrollOffset: Double,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            // Inside the clip box, so the rows still line up with the band the way they
            // did before the box existed.
            .designOffset(y: bandHeight - contentTop - scrollOffset)
            .designFrame(
                width: width,
                height: viewportHeight - contentTop,
                alignment: .topLeading
            )
            .clipped()
            .designOffset(y: contentTop)
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

    fileprivate enum Column {
        static let hour: CGFloat = 25
        static let icon: CGFloat = 255
        static let temperature: CGFloat = 355
        static let apparent: CGFloat = 425
        static let wind: CGFloat = 505
        static let rowHeight: CGFloat = 72
        static let iconWidth: CGFloat = 70
        /// Upstream's 100pt box could not hold a three-letter direction plus a two-digit
        /// speed ("NNW 15" needs 115pt), so this is wider — but not the 135pt it was,
        /// which ended at exactly 640 and put the final digit hard against the canvas
        /// edge. Anything that frames the picture, a television bezel included, took a
        /// bite out of it there.
        static let windWidth: CGFloat = 120
    }

    /// Height of the scrolling viewport, below the header and above the ticker.
    private var viewportHeight: CGFloat {
        metrics.space.scrollHeight
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Header band sits above the scrolling area and does not move.
            StarColor.columnHeaderBackground
                .designFrame(width: contentWidth, height: TableHeader.bandHeight)

            StarText("TEMP", font: .small, size: 32, color: StarColor.columnHeaderText)
                .designPosition(x: Column.temperature, y: TableHeader.textY)
            StarText("LIKE", font: .small, size: 32, color: StarColor.columnHeaderText)
                .designPosition(x: 435, y: TableHeader.textY)
            StarText("WIND", font: .small, size: 32, color: StarColor.columnHeaderText)
                .designPosition(x: 535, y: TableHeader.textY)

            // Rasterised once, then translated. Scrolling changes only the offset, but
            // these rows are ~24 × 4 labels and `StarText` is six Core Text passes each —
            // about 576 rasterisations — so re-rendering them per scroll step is what put
            // Hourly Forecast at half a frame a second on an Apple TV HD.
            // `.equatable()` is the part that makes the cache hold.
            //
            // `drawingGroup()` alone was not enough: `scrollOffset` is a property of this
            // view, so changing it re-evaluates the body, rebuilds `rowsView` from scratch,
            // and the drawing group re-rasterises content it cannot tell is identical.
            // Comparing the rows lets SwiftUI skip the rebuild entirely, so the raster
            // survives and scrolling is just a transform on it.
            TableHeader.scrolling(
                viewportHeight: viewportHeight,
                width: contentWidth,
                scrollOffset: scrollOffset
            ) {
                rowsView
                    .equatable()
                    .drawingGroup()
            }
        }
        .designFrame(width: contentWidth, height: viewportHeight, alignment: .topLeading)
        .clipped()
    }

    private var rowsView: HourlyRowsView {
        HourlyRowsView(rows: rows, contentWidth: contentWidth)
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

    fileprivate enum Column {
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
                .designFrame(width: contentWidth, height: TableHeader.bandHeight)

            StarText("LOW", font: .small, size: 32, color: StarColor.columnHeaderText, alignment: .center)
                .designFrame(width: Column.temperatureWidth, alignment: .center)
                .designPosition(x: Column.low, y: TableHeader.textY)

            StarText("HIGH", font: .small, size: 32, color: StarColor.columnHeaderText, alignment: .center)
                .designFrame(width: Column.highWidth, alignment: .center)
                .designPosition(x: Column.high, y: TableHeader.textY)

            // Rasterised once, then translated. Scrolling changes only the offset, but
            // these rows are ~24 × 4 labels and `StarText` is six Core Text passes each —
            // about 576 rasterisations — so re-rendering them per scroll step is what put
            // Hourly Forecast at half a frame a second on an Apple TV HD.
            // `.equatable()` is the part that makes the cache hold.
            //
            // `drawingGroup()` alone was not enough: `scrollOffset` is a property of this
            // view, so changing it re-evaluates the body, rebuilds `rowsView` from scratch,
            // and the drawing group re-rasterises content it cannot tell is identical.
            // Comparing the rows lets SwiftUI skip the rebuild entirely, so the raster
            // survives and scrolling is just a transform on it.
            TableHeader.scrolling(
                viewportHeight: viewportHeight,
                width: contentWidth,
                scrollOffset: scrollOffset
            ) {
                rowsView
                    .equatable()
                    .drawingGroup()
            }
        }
        .designFrame(width: contentWidth, height: viewportHeight, alignment: .topLeading)
        .clipped()
    }

    private var rowsView: TravelRowsView {
        TravelRowsView(rows: rows, contentWidth: contentWidth)
    }

    /// Total height of all rows, for the engine's scroll timing.
    static func contentHeight(rowCount: Int) -> CGFloat {
        CGFloat(rowCount) * Column.rowHeight + 20
    }
}


/// The scrolling rows, split out as an `Equatable` view.
///
/// This exists purely so `.equatable()` has a named type to compare. Left as a computed
/// property on the display, changing `scrollOffset` re-evaluated the body and rebuilt these
/// rows, which defeated `drawingGroup()` — it cannot tell that freshly-built content is
/// identical, so it re-rasterised ~576 Core Text passes on every scroll step.
private struct HourlyRowsView: View, Equatable {
    let rows: [HourlyRow]
    let contentWidth: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let y = CGFloat(index) * HourlyDisplay.Column.rowHeight + 8

                StarText(row.hourLabel, font: .large, size: 32, color: StarColor.title)
                    .designPosition(x: HourlyDisplay.Column.hour, y: y)

                PixelImage(row.icon, width: HourlyDisplay.Column.iconWidth)
                    .designPosition(x: HourlyDisplay.Column.icon, y: y - 6)

                StarText(row.temperature, font: .large, size: 32, color: StarColor.title)
                    .designPosition(x: HourlyDisplay.Column.temperature, y: y)

                StarText(
                    row.apparent,
                    font: .large,
                    size: 32,
                    color: row.isHeatIndex
                        ? StarColor.heatIndex
                        : (row.isWindChill ? StarColor.windChill : StarColor.title)
                )
                .designPosition(x: HourlyDisplay.Column.apparent, y: y)

                StarText(
                    row.wind,
                    font: .large,
                    size: 32,
                    color: StarColor.title,
                    alignment: .trailing,
                    lineLimit: 1,
                    minimumScaleFactor: 0.8
                )
                .designFrame(width: HourlyDisplay.Column.windWidth, alignment: .trailing)
                .designPosition(x: HourlyDisplay.Column.wind, y: y)
            }
        }
        .designFrame(
            width: contentWidth,
            height: max(CGFloat(rows.count) * HourlyDisplay.Column.rowHeight, 1),
            alignment: .topLeading
        )
    }
}

/// The scrolling rows, split out as an `Equatable` view.
///
/// This exists purely so `.equatable()` has a named type to compare. Left as a computed
/// property on the display, changing `scrollOffset` re-evaluated the body and rebuilt these
/// rows, which defeated `drawingGroup()` — it cannot tell that freshly-built content is
/// identical, so it re-rasterised ~576 Core Text passes on every scroll step.
private struct TravelRowsView: View, Equatable {
    let rows: [TravelRow]
    let contentWidth: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let y = CGFloat(index) * TravelDisplay.Column.rowHeight + 8

                StarText(
                    row.city,
                    font: .large,
                    size: 32,
                    color: StarColor.title,
                    lineLimit: 1,
                    minimumScaleFactor: 0.8
                )
                .designFrame(width: TravelDisplay.Column.icon - TravelDisplay.Column.city - 10, alignment: .leading)
                .clipped()
                .designPosition(x: TravelDisplay.Column.city, y: y)

                if let icon = row.icon {
                    PixelImage(icon, width: TravelDisplay.Column.iconWidth)
                        .designPosition(x: TravelDisplay.Column.icon, y: y - 6)
                }

                StarText(row.low, font: .large, size: 32, color: StarColor.title, alignment: .center)
                    .designFrame(width: TravelDisplay.Column.temperatureWidth, alignment: .center)
                    .designPosition(x: TravelDisplay.Column.low, y: y)

                StarText(
                    row.high,
                    font: .large,
                    size: 32,
                    color: StarColor.title,
                    alignment: .center,
                    lineLimit: 1
                )
                .designFrame(width: TravelDisplay.Column.highWidth, alignment: .center)
                .designPosition(x: TravelDisplay.Column.high, y: y)
            }
        }
        .designFrame(
            width: contentWidth,
            height: max(CGFloat(rows.count) * TravelDisplay.Column.rowHeight, 1),
            alignment: .topLeading
        )
    }
}