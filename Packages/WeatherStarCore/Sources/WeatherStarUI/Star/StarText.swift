import SwiftUI

/// The WeatherStar palette, from `styles/scss/shared/_colors.scss`.
public enum StarColor {
    public static let title = Color.yellow
    public static let dateTime = Color.white
    public static let body = Color.white
    public static let shadow = Color.black
    public static let columnHeaderText = Color.yellow
    public static let columnHeaderBackground = Color(red: 32 / 255, green: 0, blue: 87 / 255)

    public static let backgroundTop = Color(red: 0x10 / 255, green: 0x20 / 255, blue: 0x80 / 255)
    public static let backgroundBottom = Color(red: 0x00 / 255, green: 0x10 / 255, blue: 0x40 / 255)

    public static let loadingGradient = [
        Color(red: 0x09 / 255, green: 0x24 / 255, blue: 0x6f / 255),
        Color(red: 0x36 / 255, green: 0x4a / 255, blue: 0xc0 / 255),
        Color(red: 0x4f / 255, green: 0x99 / 255, blue: 0xf9 / 255),
        Color(red: 0x8f / 255, green: 0xfd / 255, blue: 0xfa / 255),
    ]

    public static let extendedLow = Color(red: 0x80 / 255, green: 0x80 / 255, blue: 1)
    public static let windChill = Color(red: 0x80 / 255, green: 0x80 / 255, blue: 1)
    public static let heatIndex = Color(red: 0xee / 255, green: 0, blue: 0)
    public static let blueBox = Color(red: 0x26 / 255, green: 0x23 / 255, blue: 0x5a / 255)
    public static let hazardBackground = Color(red: 112 / 255, green: 35 / 255, blue: 35 / 255)

    // Status colors for the display picker.
    public static let statusLoading = Color(red: 1, green: 1, blue: 0)
    public static let statusReady = Color(red: 0, green: 1, blue: 0)
    public static let statusFailed = Color(red: 1, green: 0, blue: 0)
    public static let statusDisabled = Color(white: 0xC0 / 255)
}

/// Text rendered the way the WeatherStar draws it: a hard black outline plus an
/// offset drop shadow, which is what makes the type legible over the blue gradient.
///
/// Reproduces the `text-shadow` mixin in `shared/_utils.scss` — an eight-direction
/// 1.5pt outline and a 3pt drop shadow, both scaled with the canvas.
public struct StarText: View {
    @Environment(\.starMetrics) private var metrics

    private let content: String
    private let font: StarFont
    private let size: CGFloat
    private let color: Color
    private let alignment: TextAlignment
    private let shadowOffset: CGFloat
    private let outlineWidth: CGFloat
    private let lineSpacing: CGFloat?
    private let lineLimit: Int?
    private let minimumScaleFactor: CGFloat

    public init(
        _ content: String,
        font: StarFont = .regular,
        size: CGFloat = 32,
        color: Color = StarColor.body,
        alignment: TextAlignment = .leading,
        shadowOffset: CGFloat = 3,
        outlineWidth: CGFloat = 1.5,
        lineSpacing: CGFloat? = nil,
        lineLimit: Int? = nil,
        // The Star4000 faces run about 8% wider per character than the metrics
        // upstream's fixed-pixel CSS columns were laid out against. Allowing a
        // little condensing lets a long station name or condition fit its cell
        // instead of running over the next column.
        minimumScaleFactor: CGFloat = 1
    ) {
        self.content = content
        self.font = font
        self.size = size
        self.color = color
        self.alignment = alignment
        self.shadowOffset = shadowOffset
        self.outlineWidth = outlineWidth
        self.lineSpacing = lineSpacing
        self.lineLimit = lineLimit
        self.minimumScaleFactor = minimumScaleFactor
    }

    /// Outline offsets, in design points before scaling.
    ///
    /// Four diagonals rather than the CSS mixin's eight directions. Each layer is a
    /// separate text rasterization, and at 4K on real Apple TV hardware ten of them per
    /// label was a measurable cost. The diagonals at ±1.5pt overlap enough to cover the
    /// cardinal directions for strokes this thick, so the outline reads the same while
    /// costing 40% fewer passes.
    private var outlineOffsets: [CGPoint] {
        let w = outlineWidth
        return [
            CGPoint(x: -w, y: -w), CGPoint(x: w, y: -w),
            CGPoint(x: w, y: w), CGPoint(x: -w, y: w),
        ]
    }

    public var body: some View {
        ZStack(alignment: alignment.stackAlignment) {
            // Drop shadow sits furthest back.
            layer(color: StarColor.shadow)
                .offset(x: metrics.s(shadowOffset), y: metrics.s(shadowOffset))

            // Eight-direction outline.
            ForEach(Array(outlineOffsets.enumerated()), id: \.offset) { _, point in
                layer(color: StarColor.shadow)
                    .offset(x: metrics.s(point.x), y: metrics.s(point.y))
            }

            layer(color: color)
        }
        // The outline copies extend past the glyph box, but the stack reports the
        // text's own size, so surrounding layout is unaffected.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func layer(color: Color) -> some View {
        // Every copy takes identical modifiers so the outline stays registered with
        // the fill even when the text is condensed or wrapped.
        Text(content)
            .font(font.font(size: size, scale: metrics.scale))
            .foregroundStyle(color)
            .multilineTextAlignment(alignment)
            .lineSpacing(lineSpacing.map(metrics.s) ?? 0)
            .lineLimit(lineLimit)
            .minimumScaleFactor(minimumScaleFactor)
    }
}

extension TextAlignment {
    var stackAlignment: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// Text drawn without the outline — used inside the hazard panel, where upstream
/// drops the outline and keeps only the drop shadow.
public struct StarPlainText: View {
    @Environment(\.starMetrics) private var metrics

    private let content: String
    private let font: StarFont
    private let size: CGFloat
    private let color: Color
    private let alignment: TextAlignment
    private let lineSpacing: CGFloat?

    public init(
        _ content: String,
        font: StarFont = .regular,
        size: CGFloat = 32,
        color: Color = StarColor.body,
        alignment: TextAlignment = .leading,
        lineSpacing: CGFloat? = nil
    ) {
        self.content = content
        self.font = font
        self.size = size
        self.color = color
        self.alignment = alignment
        self.lineSpacing = lineSpacing
    }

    public var body: some View {
        Text(content)
            .font(font.font(size: size, scale: metrics.scale))
            .foregroundStyle(color)
            .multilineTextAlignment(alignment)
            .lineSpacing(lineSpacing.map(metrics.s) ?? 0)
            .shadow(color: StarColor.shadow, radius: 0, x: metrics.s(3), y: metrics.s(3))
    }
}
