import SwiftUI
import WeatherStarKit
import WeatherStarResources

/// Header geometry from `_weather-display.scss`, in design points.
///
/// Declared outside `StarDisplayFrame` because Swift does not allow static stored
/// properties inside a generic type.
private enum Layout {
    static let headerHeight: CGFloat = 90
    static let logoX: CGFloat = 50
    static let logoY: CGFloat = 30
    static let logoWidth: CGFloat = 85
    static let logoHeight: CGFloat = 67
    static let titleX: CGFloat = 170
    static let titleSingleY: CGFloat = 40
    static let titleTopY: CGFloat = 27
    static let titleBottomY: CGFloat = 56
    static let titleSize: CGFloat = 32
    static let noaaX: CGFloat = 356
    static let noaaY: CGFloat = 39
    static let noaaWidth: CGFloat = 65
    static let clockWidth: CGFloat = 170
    /// Distance from the canvas's right edge to the clock's right edge.
    static let clockRightMargin: CGFloat = 55
    static let clockY: CGFloat = 30
    static let dateY: CGFloat = 56
    static let clockSize: CGFloat = 32
}

/// The header clock, which owns its own timeline.
///
/// Previously the whole canvas sat inside a one-second `TimelineView`, so every
/// display — background canvas, every row, every icon — was rebuilt once a second.
/// Scoping the tick to just these two labels is the single biggest rendering saving.
struct StarClock: View {
    let width: CGFloat
    let size: CGFloat
    let clockY: CGFloat
    let dateY: CGFloat
    /// Seconds between ticks.
    let interval: TimeInterval
    /// Formats a point in time into the clock and date lines.
    let format: (Date) -> (clock: String, date: String)

    var body: some View {
        TimelineView(.periodic(from: .now, by: interval)) { timeline in
            let text = format(timeline.date)
            ZStack(alignment: .topLeading) {
                StarText(
                    text.clock,
                    font: .small, size: size,
                    color: StarColor.dateTime, alignment: .trailing
                )
                .designFrame(width: width, alignment: .trailing)
                .designOffset(y: clockY)

                StarText(
                    text.date,
                    font: .small, size: size,
                    color: StarColor.dateTime, alignment: .trailing
                )
                .designFrame(width: width, alignment: .trailing)
                .designOffset(y: dateY)
            }
        }
    }
}

/// The chrome every display sits inside: background art, the header with its logo,
/// title and clock, and the bottom ticker.
///
/// Positions come from `_weather-display.scss` and are expressed in design points,
/// so the whole frame scales with the canvas.
public struct StarDisplayFrame<Content: View>: View {
    @Environment(\.starMetrics) private var metrics

    private let display: DisplayIdentifier
    /// Header override, used by Current Conditions to say "Recent" when data is old.
    private let titleOverride: (top: String, bottom: String?)?
    private let scroll: ScrollContent?
    private let clockInterval: TimeInterval
    private let clockFormat: (Date) -> (clock: String, date: String)
    private let content: Content

    public init(
        display: DisplayIdentifier,
        titleOverride: (top: String, bottom: String?)? = nil,
        scroll: ScrollContent? = nil,
        clockInterval: TimeInterval = 1,
        clockFormat: @escaping (Date) -> (clock: String, date: String) = { _ in ("", "") },
        @ViewBuilder content: () -> Content
    ) {
        self.display = display
        self.titleOverride = titleOverride
        self.scroll = scroll
        self.clockInterval = clockInterval
        self.clockFormat = clockFormat
        self.content = content()
    }

    /// Horizontal shift applied to 640pt-wide content on the wide canvas.
    ///
    /// Upstream's `.wide &` rules move the header and main area right by this margin
    /// so a 640pt layout sits centred in the 854pt canvas. Displays marked
    /// `expandsToWideCanvas` opt out and use the full width instead.
    private var contentInset: CGFloat {
        metrics.space.contentInset
    }

    /// Clock column's left edge, derived from the right margin so it stays flush right
    /// on any canvas width.
    private var clockX: CGFloat {
        metrics.space.width - Layout.clockWidth - Layout.clockRightMargin
    }

    /// Design-space height available to the content, between header and ticker.
    private var availableContentHeight: CGFloat {
        metrics.space.height
            - (display.drawsHeader ? Layout.headerHeight : 0)
            - (display.showsScroll ? ScrollTicker.height : 0)
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            StarBackground(style: display.backgroundStyle)

            content
                .environment(
                    \.starContentWidth,
                    display.expandsToWideCanvas ? metrics.space.width : 640
                )
                // Bounded to what is actually free between the header and the ticker.
                //
                // Without this the content is proposed the *whole* canvas height and then
                // offset down past the header, so anything that fills its height hangs off
                // the bottom by exactly the header's 90pt and is lost to the frame's clip.
                // Displays that position everything absolutely never noticed; the startup
                // screen, which lays out a VStack, lost its credit line, its link and its
                // progress bar.
                .designFrame(height: availableContentHeight, alignment: .top)
                .designOffset(
                    x: display.expandsToWideCanvas ? 0 : contentInset,
                    y: display.drawsHeader ? Layout.headerHeight : 0
                )

            // Painted after the content: upstream gives the header `z-index: 10` so
            // the logo sits on top where it overhangs the display area.
            //
            // Not inset on the wide canvas: upstream shifts the whole 640pt header
            // right, leaving the logo floating in from the left edge and the clock
            // short of the right. Spanning the full width puts the branding hard left
            // and the clock hard right, which is what widescreen chrome should do.
            if display.drawsHeader {
                header
            }

            if display.showsScroll, let scroll {
                ScrollTicker(content: scroll)
                    .designOffset(y: metrics.space.height - ScrollTicker.height)
            }
        }
        .frame(width: metrics.scaledSize.width, height: metrics.scaledSize.height)
        .clipped()
    }

    // MARK: - Header

    private var header: some View {
        let title = titleOverride ?? display.header

        return ZStack(alignment: .topLeading) {
            // Height is bounded as well as width: the source art is taller than the
            // 90pt header, so sizing by width alone let it run underneath the display
            // content and get clipped mid-logo.
            StarLogo(width: Layout.logoWidth, height: Layout.logoHeight)
                .designPosition(x: Layout.logoX, y: Layout.logoY)

            if let bottom = title.bottom {
                StarText(
                    title.top,
                    font: .regular,
                    size: Layout.titleSize,
                    color: StarColor.title
                )
                .designPosition(x: Layout.titleX, y: Layout.titleTopY)

                StarText(
                    bottom,
                    font: .regular,
                    size: Layout.titleSize,
                    color: StarColor.title
                )
                .designPosition(x: Layout.titleX, y: Layout.titleBottomY)
            } else {
                StarText(
                    title.top,
                    font: .regular,
                    size: Layout.titleSize,
                    color: StarColor.title
                )
                .designPosition(x: Layout.titleX, y: Layout.titleSingleY)
            }

            if display.showsNOAALogo {
                PixelImage(
                    url: WeatherStarResources.url("noaa.gif", in: .logos),
                    width: Layout.noaaWidth
                )
                .designPosition(x: Layout.noaaX, y: Layout.noaaY)
            }

            // Clock and date are right-aligned in a fixed-width column, and re-render
            // on their own timeline so the tick does not rebuild the whole display.
            if display.showsClock {
                StarClock(
                    width: Layout.clockWidth,
                    size: Layout.clockSize,
                    clockY: Layout.clockY,
                    dateY: Layout.dateY,
                    interval: clockInterval,
                    format: clockFormat
                )
                .designPosition(x: clockX, y: 0)
            }
        }
    }
}

/// The bottom ticker, which cycles facts about the current conditions and turns red
/// when a hazard is active.
///
/// The line changes on its own wall-clock timer rather than off the active display's
/// base count. Base delay varies enormously between displays — 9000 ms for Current
/// Conditions versus 350 ms for Radar — so driving the ticker from it made the text
/// sit still for half a minute on one display and flash through every line in a
/// second on another.
public struct ScrollTicker: View {
    @Environment(\.starMetrics) private var metrics

    static let height: CGFloat = 77
    private static let textSize: CGFloat = 32
    private static let sideMargin: CGFloat = 55
    /// Seconds a line is held still before and after it scrolls.
    private static let holdDuration: TimeInterval = 2.5
    /// Design points per second the text travels, matching upstream's feel.
    private static let scrollSpeed: CGFloat = 60

    private let content: ScrollContent

    /// Measured once per content change. As a computed property this re-ran Core Text
    /// over every line on every frame at 60fps, which was the hottest path in the app
    /// on real Apple TV hardware.
    @State private var segments: [Segment] = []

    public init(content: ScrollContent) {
        self.content = content
    }

    private var isHazard: Bool { content.hazardHeadline != nil }

    private var viewportWidth: CGFloat {
        metrics.space.width - 2 * Self.sideMargin
    }

    /// One entry per ticker line, with the distance it needs to travel and how long
    /// its turn lasts. A line that already fits simply holds still.
    private struct Segment {
        let text: String
        let distance: CGFloat
        let duration: TimeInterval
    }

    /// Built from measured text widths, so the marquee is a pure function of elapsed
    /// time — no layout feedback loop and no per-frame measurement.
    @MainActor
    private func makeSegments() -> [Segment] {
        let lines = content.hazardHeadline.map { [$0] } ?? content.lines
        guard !lines.isEmpty else { return [] }

        return lines.map { line in
            let width = StarFont.regular.textWidth(line, size: Self.textSize)
            let distance = max(0, width - viewportWidth)
            let travel = distance > 0 ? TimeInterval(distance / Self.scrollSpeed) : 0
            return Segment(
                text: line,
                distance: distance,
                duration: Self.holdDuration * 2 + travel
            )
        }
    }

    /// One line of ticker text, rasterised into a single layer so scrolling it is a
    /// transform rather than six text passes per frame.
    private func cachedLine(_ text: String) -> some View {
        StarText(
            text,
            font: .regular,
            size: Self.textSize,
            color: StarColor.body,
            lineLimit: 1
        )
        // Laid out at full width so it is never condensed, then translated.
        .fixedSize()
        .drawingGroup()
        .id(text)
    }

    /// Which line is showing and how far it has scrolled, for a point in time.
    private func state(at date: Date) -> (text: String, offset: CGFloat) {
        guard !segments.isEmpty else { return ("", 0) }

        let cycle = segments.reduce(0) { $0 + $1.duration }
        guard cycle > 0 else { return (segments[0].text, 0) }

        var elapsed = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
        for segment in segments {
            if elapsed < segment.duration {
                // Hold, then travel at a constant rate, then hold again.
                let scrolling = elapsed - Self.holdDuration
                let travel = segment.duration - Self.holdDuration * 2
                guard segment.distance > 0, scrolling > 0 else {
                    return (segment.text, 0)
                }
                let progress = min(max(scrolling / max(travel, 0.001), 0), 1)
                return (segment.text, -segment.distance * CGFloat(progress))
            }
            elapsed -= segment.duration
        }
        return (segments[0].text, 0)
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            if isHazard {
                StarColor.hazardBackground
            }

            StarText(
                content.header,
                font: .small,
                size: 26,
                color: StarColor.dateTime
            )
            .designPosition(x: Self.sideMargin, y: 6)

            // 30fps rather than display-rate: at 60pt/s of travel the difference is
            // imperceptible.
            //
            // Only the *offset* changes per frame. The line itself is rasterised once and
            // then translated, because `StarText` is six Core Text passes per label — an
            // outline, a shadow and the fill — and re-running them thirty times a second on
            // a full-width line of scaled-up type was the single most expensive thing the
            // app did. On a Mac it showed as ~9% CPU for a still picture; on an Apple TV at
            // 4K it was the difference between smooth and about four frames a second.
            //
            // `.id(current.text)` is what makes the caching work: the view keeps its
            // identity while the line is unchanged, so the rasterisation is reused, and a
            // new one is built only when the ticker moves to the next line.
            TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
                let current = state(at: timeline.date)

                cachedLine(current.text)
                    .designOffset(x: current.offset)
                    .designFrame(width: viewportWidth, alignment: .leading)
                    .clipped()
                    .designPosition(x: Self.sideMargin, y: 34)
            }
        }
        .designFrame(width: metrics.space.width, height: Self.height)
        .clipped()
        .task(id: MarqueeKey(content: content, width: viewportWidth)) {
            segments = makeSegments()
        }
    }

    /// Identity for the measurement task: re-measure only when the text or the
    /// available width actually changes.
    private struct MarqueeKey: Equatable {
        let lines: [String]
        let hazard: String?
        let width: CGFloat

        init(content: ScrollContent, width: CGFloat) {
            lines = content.lines
            hazard = content.hazardHeadline
            self.width = width
        }
    }
}
