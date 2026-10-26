import SwiftUI
import WeatherStarKit

/// Tides: today's and tomorrow's high and low water at the nearest NOAA station.
///
/// Laid out as the Almanac is — a column per day under a yellow day name — so it reads as one
/// of the set rather than a new design. Most coasts have two highs and two lows a day; some, on
/// the Gulf, have one of each, and the rows simply stop.
struct TidesDisplay: View {
    @Environment(\.starMetrics) private var metrics
    @Environment(\.starContentWidth) private var contentWidth

    let data: TidesData
    let timeZone: TimeZone

    private enum Layout {
        /// Inside the blue panel, whose edges sit about 56 points in from either side.
        static let sideMargin: CGFloat = 64
        static let rowHeight: CGFloat = 42
        /// "Hi" and "Lo", as the Extended Forecast labels them.
        static let labelWidth: CGFloat = 44
        static let timeWidth: CGFloat = 116
        static let fontSize: CGFloat = 26
    }

    private var columnWidth: CGFloat {
        (contentWidth - 2 * Layout.sideMargin) / CGFloat(max(data.days.count, 1))
    }

    var body: some View {
        VStack(spacing: 0) {
            StarText(
                data.station.name,
                font: .regular,
                size: 24,
                color: StarColor.title,
                alignment: .center,
                lineLimit: 1,
                minimumScaleFactor: 0.6
            )
            .designFrame(width: contentWidth - 2 * Layout.sideMargin, alignment: .center)
            .designPadding(.top, 6)
            .designPadding(.bottom, 10)

            HStack(alignment: .top, spacing: 0) {
                ForEach(data.days, id: \.name) { day in
                    column(day)
                        .designFrame(width: columnWidth, alignment: .top)
                }
            }
        }
        .designFrame(width: contentWidth, alignment: .top)
    }

    private func column(_ day: TidesData.Day) -> some View {
        VStack(spacing: 0) {
            StarText(
                day.name,
                font: .regular,
                size: 32,
                color: StarColor.columnHeaderText,
                alignment: .center,
                lineLimit: 1,
                minimumScaleFactor: 0.6
            )
            .designFrame(width: columnWidth, height: Layout.rowHeight, alignment: .center)

            ForEach(day.events, id: \.time) { event in
                HStack(spacing: 0) {
                    StarText(event.isHigh ? "Hi" : "Lo", font: .regular, size: Layout.fontSize, color: StarColor.title)
                        .designFrame(width: Layout.labelWidth, alignment: .leading)
                    StarText(time(event.time), font: .regular, size: Layout.fontSize, alignment: .trailing, lineLimit: 1, minimumScaleFactor: 0.7)
                        .designFrame(width: Layout.timeWidth, alignment: .trailing)
                    StarText(height(event.height), font: .regular, size: Layout.fontSize, alignment: .trailing, lineLimit: 1, minimumScaleFactor: 0.7)
                        .designFrame(width: max(columnWidth - Layout.labelWidth - Layout.timeWidth - 16, 40), alignment: .trailing)
                }
                .designFrame(width: columnWidth - 8, height: Layout.rowHeight, alignment: .center)
            }
        }
    }

    private func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    private func height(_ value: Double) -> String {
        String(format: "%.1f%@", value, data.unit == "m" ? "m" : "'")
    }
}
