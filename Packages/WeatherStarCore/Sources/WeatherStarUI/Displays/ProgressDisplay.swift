import SwiftUI
import WeatherStarKit

/// The startup screen: every display with its loading state, plus the striped
/// progress bar. Layout from `_progress.scss`.
struct ProgressDisplay: View {
    @Environment(\.starMetrics) private var metrics
    @Environment(\.starContentWidth) private var contentWidth

    let displays: [DisplayIdentifier]
    let statusFor: (DisplayIdentifier) -> DisplayStatus

    private enum Layout {
        static let boxMargin: CGFloat = 64
        static let innerInset: CGFloat = 10
        static let top: CGFloat = 15
        static let lineHeight: CGFloat = 28
        static let barWidth: CGFloat = 524
        static let barHeight: CGFloat = 20
    }

    /// Inner text column, inside the blue panel's margins.
    private var textWidth: CGFloat {
        contentWidth - 2 * Layout.boxMargin - 2 * Layout.innerInset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(displays) { display in
                row(display)
            }
        }
        .designFrame(width: textWidth, alignment: .topLeading)
        .designOffset(x: Layout.boxMargin + Layout.innerInset, y: Layout.top)
    }

    private func row(_ display: DisplayIdentifier) -> some View {
        let status = statusFor(display)
        return ZStack(alignment: .topLeading) {
            // Upstream pads the name with a long dotted run and lets it clip, which
            // produces the leader dots up to the status column.
            StarText(
                "\(display.name)\(String(repeating: ".", count: 72))",
                font: .extended,
                size: 25
            )
            .designFrame(width: textWidth, alignment: .leading)
            .clipped()

            StarText(
                Self.label(for: status),
                font: .extended,
                size: 25,
                color: Self.color(for: status),
                alignment: .trailing
            )
            .designPadding(.leading, 4)
            .background(StarColor.blueBox)
            .designFrame(width: textWidth, alignment: .trailing)
        }
        .designFrame(height: Layout.lineHeight, alignment: .topLeading)
    }

    private static func label(for status: DisplayStatus) -> String {
        switch status {
        case .loading: "Loading"
        case .loaded: "Press Here"
        case .failed: "Failed"
        case .noData: "No Data"
        case .disabled: "Disabled"
        case .retrying: "Retrying"
        }
    }

    private static func color(for status: DisplayStatus) -> Color {
        switch status {
        case .loading, .retrying: StarColor.statusLoading
        case .loaded: StarColor.statusReady
        case .failed: StarColor.statusFailed
        case .noData, .disabled: StarColor.statusDisabled
        }
    }
}

/// The striped loading bar shown under the progress list.
///
/// Upstream animates a repeating gradient's background position in eight steps; this
/// draws the same stripe pattern and offsets it on a timeline.
struct ProgressBar: View {
    @Environment(\.starMetrics) private var metrics
    @Environment(\.starContentWidth) private var contentWidth

    let progress: Double

    private enum Layout {
        static let width: CGFloat = 524
        static let height: CGFloat = 24
        static let stripeWidth: CGFloat = 5
        static let patternWidth: CGFloat = 40
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: false)) { timeline in
            // Eight discrete steps over two seconds, matching the CSS animation.
            let step = Int(timeline.date.timeIntervalSinceReferenceDate / 0.25) % 8
            let shift = CGFloat(step) * (Layout.patternWidth / 8)

            ZStack(alignment: .leading) {
                Canvas(opaque: false) { context, size in
                    let colors = StarColor.loadingGradient
                    // The pattern ramps up through the four blues and back down.
                    let sequence = [
                        colors[0], colors[1], colors[2], colors[3],
                        colors[2], colors[1], colors[0], colors[0],
                    ]
                    let stripe = metrics.s(Layout.stripeWidth)
                    var x = -metrics.s(Layout.patternWidth) + metrics.s(shift)
                    var index = 0
                    while x < size.width {
                        context.fill(
                            Path(CGRect(x: x, y: 0, width: stripe, height: size.height)),
                            with: .color(sequence[index % sequence.count])
                        )
                        x += stripe
                        index += 1
                    }
                }
                .designFrame(width: Layout.width, height: Layout.height)

                // A white cover masks the unfinished portion of the bar.
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Color.white
                        .designFrame(
                            width: Layout.width * (1 - min(max(progress, 0), 1)),
                            height: Layout.height
                        )
                }
                .designFrame(width: Layout.width, height: Layout.height)
            }
            .designFrame(width: Layout.width, height: Layout.height)
            .border(Color.black, width: metrics.s(2))
        }
    }
}
