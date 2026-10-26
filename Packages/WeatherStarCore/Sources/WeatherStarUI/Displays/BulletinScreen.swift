import SwiftUI
import WeatherStarKit

/// The weather bulletin: a warning breaking into the rotation.
///
/// Drawn inside the picture like any display, so it comes through the tube, the scanlines and
/// the cabinet the same way. Red, as the WeatherStar's hazard screens were, with the event
/// pulsing in the title colour so it reads from across a room. The NWS's own text follows —
/// where the storm is, where it is going, what to do — and once the headline has had time to
/// be read it scrolls up through the window at a reading pace.
struct BulletinScreen: View {
    @Environment(\.starMetrics) private var metrics
    @Environment(\.starContentWidth) private var contentWidth

    let bulletin: WeatherBulletin
    /// When the bulletin went up, which the scroll is timed from.
    let shownAt: Date

    private enum Layout {
        static let sideMargin: CGFloat = 48
        /// Seconds the text holds still before scrolling, for the headline to be read.
        static let scrollDelay: Double = 6
        /// Design points a second: about a line every two seconds at this size.
        static let scrollSpeed: Double = 16
        /// Points of stillness at the end of the text before it starts again.
        static let endPause: Double = 80
    }

    private static let backgroundTop = Color(hex: 0x8A1C1C)
    private static let backgroundBottom = Color(hex: 0x3A0909)

    /// The text's height and its window's, in design points, measured once laid out.
    @State private var bodyHeight: CGFloat = 0
    @State private var windowHeight: CGFloat = 0

    var body: some View {
        let canvasHeight = metrics.space.height
        let textWidth = contentWidth - 2 * Layout.sideMargin

        ZStack(alignment: .top) {
            LinearGradient(
                colors: [Self.backgroundTop, Self.backgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )

            // Stacked rather than placed: the headline runs from one line to four depending on
            // the office and the hazard, and whatever it leaves is the text's window.
            VStack(alignment: .leading, spacing: 0) {
                StarText("Weather Bulletin", font: .large, size: 40, color: StarColor.title, alignment: .center)
                    .designFrame(width: textWidth, alignment: .center)

                // The event pulses between white and the title yellow, once a second.
                TimelineView(.periodic(from: shownAt, by: 1)) { timeline in
                    let lit = Int(timeline.date.timeIntervalSince(shownAt)) % 2 == 0
                    StarText(
                        bulletin.event.uppercased(),
                        font: .regular,
                        size: 40,
                        color: lit ? StarColor.body : StarColor.title,
                        alignment: .center,
                        lineLimit: 1,
                        minimumScaleFactor: 0.6
                    )
                    .designFrame(width: textWidth, alignment: .center)
                }
                .designPadding(.top, 4)

                StarPlainText(bulletin.headline, font: .regular, size: 22, lineSpacing: 2)
                    .designFrame(width: textWidth, alignment: .leading)
                    .lineLimit(4)
                    .designPadding(.top, 12)

                Rectangle()
                    .fill(StarColor.title.opacity(0.7))
                    .designFrame(width: textWidth, height: 2)
                    .designPadding(.vertical, 10)

                scrollingBody(width: textWidth)
            }
            .designPadding(.top, 18)
            .designPadding(.bottom, 26)
            .designPadding(.horizontal, Layout.sideMargin)
        }
        .designFrame(width: contentWidth, height: canvasHeight, alignment: .top)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Weather bulletin: \(bulletin.event). \(bulletin.headline). \(bulletin.text)")
    }

    /// The warning's text, rising through its window once the headline has been read, then
    /// pausing at its end and starting again from the top.
    private func scrollingBody(width: CGFloat) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(shownAt) - Layout.scrollDelay)
            let travel = max(0, bodyHeight - windowHeight)
            let offset = travel > 0
                ? min((elapsed * Layout.scrollSpeed).truncatingRemainder(dividingBy: travel + Layout.endPause), travel)
                : 0

            StarPlainText(bulletin.text, font: .regular, size: 24, lineSpacing: 4)
                .designFrame(width: width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    bodyHeight = $0 / max(metricsScale, 0.01)
                }
                .designOffset(y: -offset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    windowHeight = $0 / max(metricsScale, 0.01)
                }
        }
    }

    private var metricsScale: CGFloat { metrics.scale }

    /// How long a bulletin stays up: long enough to read, never so long it holds the screen.
    static func duration(for bulletin: WeatherBulletin) -> TimeInterval {
        min(max(Layout.scrollDelay + Double(bulletin.text.count) / 18, 18), 60)
    }
}
