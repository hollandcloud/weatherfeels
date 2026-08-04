import SwiftUI
import WeatherStarKit

/// The fixed coordinate space a display is authored in.
///
/// Upstream's CSS positions everything against one of three pixel canvases. Keeping
/// those as *design* spaces means the ported layout code reads like the original,
/// while the actual rendering happens at whatever resolution the screen provides.
public struct DesignSpace: Sendable, Hashable {
    public let size: CGSize
    public let mode: LayoutMode

    /// The original WeatherStar 4000 canvas.
    public static let standard = DesignSpace(size: CGSize(width: 640, height: 480), mode: .standard)
    /// Upstream's widescreen variant — fills a 16:9 TV with no pillarboxing.
    public static let wide = DesignSpace(size: CGSize(width: 854, height: 480), mode: .wide)
    /// Upstream's tall variant for phones held upright.
    public static let portrait = DesignSpace(size: CGSize(width: 640, height: 1137), mode: .portrait)

    public var width: CGFloat { size.width }
    public var height: CGFloat { size.height }
    public var aspectRatio: CGFloat { size.width / size.height }

    /// Height available to a display's main area once the bottom ticker is placed.
    public var scrollHeight: CGFloat {
        mode == .portrait ? 967 : 310
    }

    /// Horizontal inset of the inner "blue box" panel.
    public var blueBoxMargin: CGFloat { 64 }

    /// Content is authored against 640pt regardless of mode; the wide canvas simply
    /// adds margins on either side. This is that margin.
    public var contentInset: CGFloat {
        mode == .wide ? (size.width - 640) / 2 : 0
    }
}

/// Resolved scaling between a `DesignSpace` and the actual view size.
public struct StarMetrics: Sendable, Hashable {
    public let space: DesignSpace
    /// Multiplier from design points to output points.
    public let scale: CGFloat
    /// Letterbox/pillarbox offset that centers the canvas in the container.
    public let origin: CGPoint
    /// Size the scaled canvas occupies.
    public let scaledSize: CGSize

    public static let identity = StarMetrics(
        space: .standard,
        scale: 1,
        origin: .zero,
        scaledSize: CGSize(width: 640, height: 480)
    )

    /// Scale a design-space length to output points.
    public func s(_ value: CGFloat) -> CGFloat { value * scale }

    /// Scale a design-space size.
    public func s(_ size: CGSize) -> CGSize {
        CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// Fit `space` inside `container`, preserving aspect ratio and centering.
    public init(space: DesignSpace, container: CGSize) {
        self.space = space
        let widthScale = container.width / space.width
        let heightScale = container.height / space.height
        // `min` preserves the aspect ratio; the design space is chosen to match the
        // container closely, so leftover bars are small or absent.
        let resolved = max(min(widthScale, heightScale), 0.01)
        scale = resolved
        scaledSize = CGSize(width: space.width * resolved, height: space.height * resolved)
        origin = CGPoint(
            x: (container.width - scaledSize.width) / 2,
            y: (container.height - scaledSize.height) / 2
        )
    }

    public init(space: DesignSpace, scale: CGFloat, origin: CGPoint, scaledSize: CGSize) {
        self.space = space
        self.scale = scale
        self.origin = origin
        self.scaledSize = scaledSize
    }
}

extension DesignSpace {
    /// Pick the design space that wastes the least screen area, honoring an explicit
    /// user choice when one is set.
    ///
    /// On a 4K TV (3840×2160, 1.78) this returns `.wide`, which scales 4.5× to fill
    /// the panel edge to edge.
    public static func resolve(for mode: LayoutMode, container: CGSize) -> DesignSpace {
        switch mode {
        case .standard: return .standard
        case .wide: return .wide
        case .portrait: return .portrait
        case .auto:
            guard container.width > 0, container.height > 0 else { return .standard }
            let aspect = container.width / container.height

            // Clearly taller than square: use the portrait canvas.
            if aspect < 0.85 { return .portrait }
            // Widescreen and beyond: use the wide canvas.
            if aspect > 1.45 { return .wide }
            return .standard
        }
    }
}

// MARK: - Environment

private struct StarMetricsKey: EnvironmentKey {
    static let defaultValue = StarMetrics.identity
}

private struct StarContentWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 640
}

extension EnvironmentValues {
    /// Scaling in effect for the enclosing display. Read this instead of hard-coding
    /// pixel sizes so content stays sharp at any resolution.
    public var starMetrics: StarMetrics {
        get { self[StarMetricsKey.self] }
        set { self[StarMetricsKey.self] = newValue }
    }

    /// Design-space width available to the current display's content.
    ///
    /// This is 640 for a display laid out at the original width — even on the 854pt
    /// wide canvas, where the frame shifts it right by the margin — and the full
    /// canvas width for displays that expand. Read this rather than
    /// `starMetrics.space.width`, which is the *canvas* width and would stretch a
    /// 640pt layout across the whole wide canvas.
    public var starContentWidth: CGFloat {
        get { self[StarContentWidthKey.self] }
        set { self[StarContentWidthKey.self] = newValue }
    }
}

// MARK: - Design-space layout modifiers
//
// These multiply design-space values by the current scale at *layout* time. That
// matters: `.scaleEffect` would rasterize text at 1× and upscale the bitmap, which
// looks soft on a 4K TV. Scaling the font size and frame instead means Core Text
// rasterizes at the final resolution.

extension View {
    /// Frame given in design-space points.
    public func designFrame(
        width: CGFloat? = nil,
        height: CGFloat? = nil,
        alignment: Alignment = .center
    ) -> some View {
        modifier(DesignFrameModifier(width: width, height: height, alignment: alignment))
    }

    /// Absolute position given in design-space points, measured from the top-left of
    /// the canvas — the same origin upstream's CSS uses.
    public func designPosition(x: CGFloat, y: CGFloat) -> some View {
        modifier(DesignPositionModifier(x: x, y: y))
    }

    /// Offset given in design-space points.
    public func designOffset(x: CGFloat = 0, y: CGFloat = 0) -> some View {
        modifier(DesignOffsetModifier(x: x, y: y))
    }

    /// Padding given in design-space points.
    public func designPadding(_ edges: Edge.Set = .all, _ length: CGFloat) -> some View {
        modifier(DesignPaddingModifier(edges: edges, length: length))
    }
}

private struct DesignFrameModifier: ViewModifier {
    @Environment(\.starMetrics) private var metrics
    let width: CGFloat?
    let height: CGFloat?
    let alignment: Alignment

    func body(content: Content) -> some View {
        content.frame(
            width: width.map(metrics.s),
            height: height.map(metrics.s),
            alignment: alignment
        )
    }
}

private struct DesignPositionModifier: ViewModifier {
    @Environment(\.starMetrics) private var metrics
    let x: CGFloat
    let y: CGFloat

    func body(content: Content) -> some View {
        // `.position` centers on the point, but design coordinates describe a
        // top-left origin, so anchor to topLeading and offset instead.
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .offset(x: metrics.s(x), y: metrics.s(y))
    }
}

private struct DesignOffsetModifier: ViewModifier {
    @Environment(\.starMetrics) private var metrics
    let x: CGFloat
    let y: CGFloat

    func body(content: Content) -> some View {
        content.offset(x: metrics.s(x), y: metrics.s(y))
    }
}

private struct DesignPaddingModifier: ViewModifier {
    @Environment(\.starMetrics) private var metrics
    let edges: Edge.Set
    let length: CGFloat

    func body(content: Content) -> some View {
        content.padding(edges, metrics.s(length))
    }
}
