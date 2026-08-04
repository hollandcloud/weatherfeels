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
/// Drawn with `Canvas` rather than a Metal shader. SwiftPM does not compile `.metal`
/// files in a package target — it reports them as unhandled resources — so a shader would
/// have to be added to each of the three app targets and reached through
/// `ShaderLibrary.default`. That also puts it out of reach of the snapshot tests, which
/// render outside any app bundle, and a missing shader function traps at render time. Two
/// fills per frame gets the same look and stays verifiable everywhere.
public struct Scanlines: View {
    @Environment(\.starMetrics) private var metrics

    private let mode: ScanlineMode
    private let isAnimated: Bool

    public init(mode: ScanlineMode, animated: Bool = false) {
        self.mode = mode
        isAnimated = animated
    }

    /// Design-space thickness of one dark line. The pattern period is twice this.
    private var lineThickness: CGFloat {
        switch mode {
        case .off: 0
        case .hairline: 0.5
        case .thin: 1
        case .medium: 1.5
        case .thick: 2
        }
    }

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
            TimelineView(.animation(minimumInterval: Self.frameInterval, paused: false)) { timeline in
                // No `.drawingGroup()` here: it adds an offscreen pass, which pays for
                // itself on a static overlay and costs on one that redraws every frame.
                canvas(at: timeline.date.timeIntervalSinceReferenceDate)
            }
            .allowsHitTesting(false)
        } else {
            canvas(at: nil)
                .drawingGroup()
                .allowsHitTesting(false)
        }
    }

    private func canvas(at time: Double?) -> some View {
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

            let phase = time.map {
                period * (($0 / Self.driftPeriod).truncatingRemainder(dividingBy: 1))
            } ?? 0

            // Begin one period above the top so the drifting pattern has no seam.
            var path = Path()
            var y = phase - period
            while y < size.height {
                path.addRect(CGRect(x: 0, y: y, width: size.width, height: thickness))
                y += period
            }
            context.fill(path, with: .color(.black.opacity(opacity)))

            if let time {
                drawRollBar(in: &context, size: size, time: time)
            }
        }
    }

    /// The soft horizontal band that creeps down a CRT filmed off a screen.
    private func drawRollBar(
        in context: inout GraphicsContext,
        size: CGSize,
        time: Double
    ) {
        let travel = (time / Self.rollPeriod).truncatingRemainder(dividingBy: 1)
        let height = size.height * 0.14
        // Enters above the top and leaves below the bottom, so it never pops.
        let y = -height + travel * (size.height + height * 2)

        context.fill(
            Path(CGRect(x: 0, y: y, width: size.width, height: height)),
            with: .linearGradient(
                Gradient(colors: [
                    .white.opacity(0),
                    .white.opacity(0.045),
                    .white.opacity(0),
                ]),
                startPoint: CGPoint(x: 0, y: y),
                endPoint: CGPoint(x: 0, y: y + height)
            )
        )
    }
}
