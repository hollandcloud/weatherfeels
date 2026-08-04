import SwiftUI
import WeatherStarKit

/// CRT scanline overlay, optionally with the slow drift and roll bar of a taped
/// broadcast.
///
/// Lines are spaced in *design* space — 480 of them down the canvas, matching the
/// original raster — then scaled with everything else. Deriving spacing from the
/// design height rather than from output pixels is what prevents the moiré banding
/// you get when a fixed 1px pattern is resampled to an arbitrary screen size.
///
/// This is the `Canvas` overlay used for the static and animated modes; the full CRT tube
/// is a Metal shader in `CRTEffect`. Keeping a drawn version matters because it works
/// wherever there is no metallib — notably the package's own snapshot tests — and because
/// it is far cheaper than the shader when nothing needs to move.
public struct Scanlines: View {
    @Environment(\.starMetrics) private var metrics

    private let mode: ScanlineMode
    private let isAnimated: Bool

    public init(mode: ScanlineMode, animated: Bool = false) {
        self.mode = mode
        isAnimated = animated
    }

    /// Design-space thickness of one dark line. The pattern period is twice this.
    ///
    /// Exposed so the CRT shader can use the same spacing. Its first version hard-coded a
    /// 2-point period, which at 4K is nearly seven times finer than this — fine enough to
    /// cut chunks out of every glyph in the ticker, so the text read as broken rather than
    /// scanlined.
    static func designThickness(for mode: ScanlineMode) -> CGFloat {
        switch mode {
        case .off: 0
        case .hairline: 0.5
        case .thin: 1
        case .medium: 1.5
        case .thick: 2
        }
    }

    private var lineThickness: CGFloat { Self.designThickness(for: mode) }

    private var opacity: Double {
        switch mode {
        case .off: 0
        case .hairline: 0.18
        case .thin: 0.24
        case .medium: 0.30
        case .thick: 0.36
        }
    }

    /// Seconds for the line pattern to travel one full period.
    private static let driftPeriod: Double = 6
    /// Seconds for the roll bar to cross the screen once.
    private static let rollPeriod: Double = 9
    /// 24fps. The motion is a slow drift, so a display refresh buys nothing visible, and
    /// this overlay covers the whole screen on a 4K set.
    static let frameInterval: Double = 1.0 / 24.0

    public var body: some View {
        if mode == .off {
            Color.clear.allowsHitTesting(false)
        } else if isAnimated {
            animated.allowsHitTesting(false)
        } else {
            canvas
                .drawingGroup()
                .allowsHitTesting(false)
        }
    }

    /// Animated by *translating* a drawing made once, not by redrawing it.
    ///
    /// The first version re-ran the `Canvas` closure every frame, which rebuilt a path of
    /// several hundred rectangles and rasterised it on the CPU at whatever the output
    /// resolution is. On a real Apple TV at 4K that was severely slow — fine in the
    /// simulator, where the Mac's CPU hides it.
    ///
    /// Here the pattern and the roll bar are constant views, so they rasterise once and
    /// each frame only changes an `offset`, which is a transform on an existing layer.
    private var animated: some View {
        GeometryReader { proxy in
            let period = max(1, metrics.s(lineThickness) * 2)
            let barHeight = proxy.size.height * 0.14

            TimelineView(.animation(minimumInterval: Self.frameInterval, paused: false)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let drift = period * ((time / Self.driftPeriod).truncatingRemainder(dividingBy: 1))
                let travel = (time / Self.rollPeriod).truncatingRemainder(dividingBy: 1)

                ZStack(alignment: .top) {
                    // Drawn one period taller at each end so translating it never exposes
                    // a seam.
                    linePattern(size: proxy.size, period: period)
                        .offset(y: drift - period)

                    rollBar(height: barHeight)
                        .offset(y: -barHeight + travel * (proxy.size.height + barHeight * 2))
                }
            }
        }
    }

    /// The line pattern, rasterised once and reused for every frame.
    private func linePattern(size: CGSize, period: CGFloat) -> some View {
        let thickness = period / 2
        return Canvas(opaque: false, rendersAsynchronously: false) { context, canvasSize in
            guard thickness >= 0.75 else {
                context.fill(
                    Path(CGRect(origin: .zero, size: canvasSize)),
                    with: .color(.black.opacity(opacity / 2))
                )
                return
            }
            var path = Path()
            var y: CGFloat = 0
            while y < canvasSize.height {
                path.addRect(CGRect(x: 0, y: y, width: canvasSize.width, height: thickness))
                y += period
            }
            context.fill(path, with: .color(.black.opacity(opacity)))
        }
        .frame(width: size.width, height: size.height + period * 2)
        .drawingGroup()
    }

    /// The soft band that creeps down a CRT filmed off a screen — a plain gradient, so it
    /// costs a transform per frame rather than a redraw.
    private func rollBar(height: CGFloat) -> some View {
        LinearGradient(
            colors: [.white.opacity(0), .white.opacity(0.045), .white.opacity(0)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: height)
    }

    /// The static overlay: drawn once and cached by the caller's `.drawingGroup()`.
    private var canvas: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let thickness = metrics.s(lineThickness)
            let period = thickness * 2

            // A sub-pixel line would alias badly; once the scale drops that far,
            // fall back to a flat wash at equivalent density.
            guard thickness >= 0.75 else {
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(.black.opacity(opacity / 2))
                )
                return
            }

            var path = Path()
            var y: CGFloat = 0
            while y < size.height {
                path.addRect(CGRect(x: 0, y: y, width: size.width, height: thickness))
                y += period
            }
            context.fill(path, with: .color(.black.opacity(opacity)))
        }
    }
}
