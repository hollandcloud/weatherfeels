import SwiftUI
import WeatherStarKit

/// CRT scanline overlay.
///
/// Lines are spaced in *design* space — 480 of them down the canvas, matching the
/// original raster — then scaled with everything else. Deriving spacing from the
/// design height rather than from output pixels is what prevents the moiré banding
/// you get when a fixed 1px pattern is resampled to an arbitrary screen size.
public struct Scanlines: View {
    @Environment(\.starMetrics) private var metrics

    private let mode: ScanlineMode

    public init(mode: ScanlineMode) {
        self.mode = mode
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

    public var body: some View {
        if mode == .off {
            Color.clear.allowsHitTesting(false)
        } else {
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
            .drawingGroup()
            .allowsHitTesting(false)
        }
    }
}
