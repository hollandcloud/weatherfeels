import SwiftUI
import WeatherStarKit

/// Current Conditions: temperature, condition and icon on the left, a table of
/// secondary readings on the right. Layout from `_current-weather.scss`.
struct CurrentConditionsDisplay: View {
    @Environment(\.starMetrics) private var metrics
    @Environment(\.starContentWidth) private var canvasWidth

    let data: CurrentConditionsData

    private enum Layout {
        /// The blue panel's inner content area.
        static let boxMargin: CGFloat = 64
        /// Column width at 640pt; `.wide.enhanced` widens these to 300 plus margins.
        static let columnWidth: CGFloat = 255
        static let wideColumnWidth: CGFloat = 300
        static let columnTop: CGFloat = 20
        static let iconHeight: CGFloat = 108
        static let rowSpacing: CGFloat = 12
        static let labelIndent: CGFloat = 20
        static let valueInset: CGFloat = 10
    }

    /// Width inside the blue panel.
    private var panelWidth: CGFloat {
        canvasWidth - 2 * Layout.boxMargin
    }

    private var columnWidth: CGFloat {
        canvasWidth > 640 ? Layout.wideColumnWidth : Layout.columnWidth
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            leftColumn
                .designFrame(width: columnWidth)
            Spacer(minLength: 0)
            rightColumn
                .designFrame(width: columnWidth)
        }
        .designFrame(width: panelWidth, alignment: .topLeading)
        .designPadding(.top, Layout.columnTop)
        .designOffset(x: Layout.boxMargin)
    }

    /// Temperature, condition text, the large icon, then wind.
    private var leftColumn: some View {
        VStack(spacing: 0) {
            StarText(
                data.temperature,
                font: .large,
                size: 32,
                color: StarColor.body,
                alignment: .center
            )
            .designFrame(width: columnWidth, alignment: .center)

            StarText(
                data.condition,
                font: .extended,
                size: 32,
                color: StarColor.body,
                alignment: .center,
                lineLimit: 1,
                minimumScaleFactor: 0.6
            )
            .designFrame(width: columnWidth, alignment: .center)

            PixelImage(data.icon, height: Layout.iconHeight)
                .designFrame(width: columnWidth, alignment: .center)
                .designPadding(.vertical, 6)

            // "Wind:" on the left, direction and speed right-aligned.
            HStack(spacing: 0) {
                StarText("Wind:", font: .extended, size: 32)
                Spacer(minLength: 0)
                StarText(data.wind, font: .extended, size: 32, alignment: .trailing)
            }
            .designFrame(width: columnWidth - 10)
            .designOffset(x: 10)

            if let gust = data.windGust {
                StarText(gust, font: .extended, size: 32, alignment: .trailing)
                    .designFrame(width: columnWidth - 10, alignment: .trailing)
                    .designOffset(x: 10)
            }
        }
    }

    /// Station name, then the label/value table.
    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            StarText(
                data.locationName,
                font: .large,
                size: 20,
                color: StarColor.title,
                lineLimit: 1,
                minimumScaleFactor: 0.7
            )
            .designFrame(width: columnWidth, alignment: .leading)
            .designPadding(.bottom, 10)

            row("Humidity:", data.humidity)
            row("Dewpoint:", data.dewpoint)
            row("Ceiling:", data.ceiling)
            row("Visibility:", data.visibility)
            // Pressure is hidden when the station has no barometer.
            if !data.pressure.hasPrefix("-") {
                row("Pressure:", data.pressure)
            }
            if let label = data.apparentLabel, let value = data.apparentValue {
                row(label, value)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        // Both sides condense rather than overprint. On the 640pt canvas the column is
        // 255pt, and "Pressure:" beside "30.04 in.hg" needs more than that — the spacer
        // collapsed to nothing and the two ran straight through each other. The reading
        // holds its size first, because a squeezed label is still readable and a squeezed
        // number is the thing someone is here for.
        HStack(spacing: 0) {
            StarText(label, font: .large, size: 20, lineLimit: 1, minimumScaleFactor: 0.55)
            Spacer(minLength: 0)
            StarText(
                value,
                font: .large,
                size: 20,
                alignment: .trailing,
                lineLimit: 1,
                minimumScaleFactor: 0.8
            )
            // The reading holds its size and the label gives way, because a condensed
            // label is still readable and a condensed number is what someone is here for.
            .layoutPriority(1)
        }
        // Padding, not `designOffset`. The indents used to be offsets, which translate a
        // view *after* layout: the row was laid out across the full column and then the
        // two halves were slid 30pt towards each other, so "Pressure:" and "30.04 in.hg"
        // overprinted however they were sized. As padding the width is really reserved,
        // which is what lets the spacer and the scale factors do their job.
        .designPadding(.leading, Layout.labelIndent)
        .designPadding(.trailing, Layout.valueInset)
        .designFrame(width: columnWidth)
        .designPadding(.bottom, Layout.rowSpacing)
    }
}
