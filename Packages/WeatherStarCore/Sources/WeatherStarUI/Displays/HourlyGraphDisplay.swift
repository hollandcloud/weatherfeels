import SwiftUI
import WeatherStarKit

/// Hourly Graph: temperature, dewpoint, precipitation chance and sky cover plotted
/// over the next 24 hours. Ported from `hourly-graph.mjs`.
///
/// Each series is stroked twice — a wider black pass then the coloured pass — which
/// is how the original gets a hard outline on the lines.
struct HourlyGraphDisplay: View {
    @Environment(\.starMetrics) private var metrics
    @Environment(\.starContentWidth) private var contentWidth

    let rows: [HourlyRow]
    let temperatureUnit: String
    let timeZone: TimeZone

    private enum Layout {
        static let chartWidth: CGFloat = 532
        /// Fits the 310pt main area with room for the x-axis beneath.
        static let chartHeight: CGFloat = 246
        static let chartLeft: CGFloat = 64
        /// Measured from the top of the main area, which already sits below the header.
        static let chartTop: CGFloat = 6
        /// Inset from the top and bottom of the plot area, as upstream uses.
        static let verticalPadding: CGFloat = 10
        static let leftGutter: CGFloat = 5
        static let lineWidth: CGFloat = 3
        static let axisLabelSize: CGFloat = 24
        static let legendSize: CGFloat = 28
        static let xAxisTicks = 6
    }

    private enum Series {
        static let temperature = Color.red
        static let dewpoint = Color.green
        static let precipitation = Color.cyan
        static let cloud = Color(white: 0.83)
    }

    private var temperatures: [Double] { rows.compactMap(\.temperatureValue) }
    private var dewpoints: [Double] { rows.compactMap(\.dewpointValue) }

    /// Shared min/max across temperature and dewpoint, so both use one scale.
    private var temperatureRange: (min: Double, max: Double)? {
        let values = temperatures + dewpoints
        guard let low = values.min(), let high = values.max() else { return nil }
        // A flat series would divide by zero; widen it a little.
        return low == high ? (low - 1, high + 1) : (low, high)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let range = temperatureRange, rows.count > 1 {
                chart(range: range)
                    .designPosition(x: Layout.chartLeft, y: Layout.chartTop)

                yAxis(range: range)
                    .designPosition(x: Layout.chartLeft - 58, y: Layout.chartTop)

                xAxis
                    .designPosition(x: Layout.chartLeft, y: Layout.chartTop + Layout.chartHeight + 4)
            } else {
                StarText("Hourly data unavailable", font: .regular, size: 32)
                    .designPosition(x: Layout.chartLeft, y: Layout.chartTop + 120)
            }

            // Drawn last so the plotted lines pass behind the labels rather than
            // through them — the temperature trace runs right across this corner.
            legend
                .designPosition(x: contentWidth - 420, y: 4)
        }
    }

    // MARK: - Chart

    private func chart(range: (min: Double, max: Double)) -> some View {
        // Read the scale outside the draw closure: the closure is nonisolated, so it
        // must not touch the main-actor `@Environment` value.
        let scale = metrics.scale

        return Canvas(opaque: false) { context, size in
            let plotTop = Layout.verticalPadding * scale
            let plotBottom = size.height - Layout.verticalPadding * scale

            /// Horizontal position for a sample index.
            func x(_ index: Int) -> CGFloat {
                let span = max(rows.count - 1, 1)
                let gutter = Layout.leftGutter * scale
                return gutter + (size.width - gutter) * CGFloat(index) / CGFloat(span)
            }

            /// Vertical position on the temperature scale.
            func yTemperature(_ value: Double) -> CGFloat {
                let fraction = (value - range.min) / (range.max - range.min)
                return plotBottom - CGFloat(fraction) * (plotBottom - plotTop)
            }

            /// Vertical position on the 0–100% scale.
            func yPercent(_ value: Double) -> CGFloat {
                plotBottom - CGFloat(value / 100) * (plotBottom - plotTop)
            }

            // Draw order matters: later series sit on top, so temperature is last.
            stroke(&context, points: rows.map(\.skyCoverValue).enumerated()
                .compactMap { index, value in value.map { CGPoint(x: x(index), y: yPercent($0)) } },
                color: Series.cloud)

            stroke(&context, points: rows.map(\.precipitationChance).enumerated()
                .compactMap { index, value in value.map { CGPoint(x: x(index), y: yPercent($0)) } },
                color: Series.precipitation)

            stroke(&context, points: rows.map(\.dewpointValue).enumerated()
                .compactMap { index, value in value.map { CGPoint(x: x(index), y: yTemperature($0)) } },
                color: Series.dewpoint)

            stroke(&context, points: rows.map(\.temperatureValue).enumerated()
                .compactMap { index, value in value.map { CGPoint(x: x(index), y: yTemperature($0)) } },
                color: Series.temperature)
        }
        .designFrame(width: Layout.chartWidth, height: Layout.chartHeight)
    }

    /// Stroke a series with a black underlay, giving the line a hard outline.
    private func stroke(
        _ context: inout GraphicsContext,
        points: [CGPoint],
        color: Color
    ) {
        guard points.count > 1 else { return }
        var path = Path()
        path.move(to: points[0])
        for point in points.dropFirst() { path.addLine(to: point) }

        context.stroke(
            path,
            with: .color(.black),
            style: StrokeStyle(lineWidth: metrics.s(Layout.lineWidth + 2), lineJoin: .round)
        )
        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(lineWidth: metrics.s(Layout.lineWidth), lineJoin: .round)
        )
    }

    // MARK: - Axes and legend

    /// Four temperature labels: max, two thirds, one third, min.
    private func yAxis(range: (min: Double, max: Double)) -> some View {
        let third = (range.max - range.min) / 3
        let labels = [
            range.max,
            (range.min + third * 2).rounded(),
            (range.min + third).rounded(),
            range.min,
        ]

        return VStack(alignment: .trailing, spacing: 0) {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, value in
                StarText(
                    "\(Int(value))\(degreeSign)",
                    font: .small,
                    size: Layout.axisLabelSize,
                    alignment: .trailing
                )
                .designFrame(width: 54, alignment: .trailing)
                if index < labels.count - 1 {
                    Spacer(minLength: 0)
                }
            }
        }
        .designFrame(width: 54, height: Layout.chartHeight, alignment: .trailing)
    }

    private var xAxis: some View {
        HStack(spacing: 0) {
            ForEach(0...Layout.xAxisTicks, id: \.self) { tick in
                let index = rows.count * tick / Layout.xAxisTicks
                let row = rows.indices.contains(index) ? rows[index] : rows.last
                StarText(
                    row.map { Self.tickLabel($0.time, in: timeZone) } ?? "",
                    font: .small,
                    size: Layout.axisLabelSize,
                    alignment: .center
                )
                .designFrame(
                    width: Layout.chartWidth / CGFloat(Layout.xAxisTicks + 1),
                    alignment: .center
                )
            }
        }
        .designFrame(width: Layout.chartWidth, alignment: .leading)
    }

    private var legend: some View {
        VStack(alignment: .trailing, spacing: 0) {
            legendRow("Temperature \(degreeSign)\(temperatureUnit)", Series.temperature)
            legendRow("Dewpoint \(degreeSign)\(temperatureUnit)", Series.dewpoint)
            legendRow("Cloud Cover %", Series.cloud)
            legendRow("Precip Chance %", Series.precipitation)
        }
        .designFrame(width: 360, alignment: .trailing)
    }

    private func legendRow(_ label: String, _ color: Color) -> some View {
        StarText(
            label,
            font: .small,
            size: Layout.legendSize,
            color: color,
            alignment: .trailing
        )
        .designFrame(width: 360, alignment: .trailing)
    }

    /// "3 PM", or "WED" at a day boundary.
    private static func tickLabel(_ date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = calendar.component(.hour, from: date) == 0 ? "EEE" : "h a"
        return formatter.string(from: date).uppercased()
    }
}
