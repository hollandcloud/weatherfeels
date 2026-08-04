import SwiftUI
import WeatherStarKit

/// Colors measured from upstream's background PNGs, so the procedural version
/// reproduces the original art rather than approximating it.
private enum BG {
    /// Navy field behind the header.
    static let navy = Color(hex: 0x1C0A57)
    /// Top of the orange header stripe.
    static let stripeTop = Color(hex: 0xC05C03)
    /// Bottom of the header stripe, where it fades toward the navy field.
    static let stripeBottom = Color(hex: 0x4A223E)
    /// The "sunset" wash down the sides of the body area.
    static let sunsetTop = Color(hex: 0x2E1250)
    static let sunsetBottom = Color(hex: 0xC05C02)
    /// Almanac's faster, brighter version of the same wash.
    static let sunsetBrightBottom = Color(hex: 0xC86901)

    /// Blue panel interior on background 1.
    static let boxFill = Color(hex: 0x21285A)
    /// Glowing edge around that panel.
    static let boxGlow = Color(hex: 0x2652B2)

    /// Extended-forecast day panels.
    static let panelTop = Color(hex: 0x5B54C8)
    static let panelBottom = Color(hex: 0x0101C8)
    static let panelBorderDark = Color(hex: 0x141414)
    static let panelBorderLight = Color(hex: 0x837ABD)

    /// Almanac body.
    static let almanacBody = Color(hex: 0x3C3C3C)
    /// Regional map body.
    static let regionalBody = Color(hex: 0x233270)
    /// Hazards fill.
    static let hazard = Color(hex: 0x702323)

    /// Footer band and its highlight rules.
    static let footer = Color(hex: 0x233270)
    static let footerDarkRule = Color(hex: 0x141414)
    static let footerLightRule = Color(hex: 0xAFAFAF)
}

/// Key vertical positions in the 480pt design canvas, measured from the originals.
private enum Metrics {
    static let stripeTop: CGFloat = 30
    static let stripeBottom: CGFloat = 90
    /// Right end of the stripe at its top edge; the edge slopes left going down.
    static let stripeRightAtTop: CGFloat = 500
    static let stripeRightAtBottom: CGFloat = 450

    static let bodyTop: CGFloat = 90
    static let bodyBottom: CGFloat = 399

    static let footerDarkRule: CGFloat = 399
    static let footerLightRule: CGFloat = 401
    static let footerTop: CGFloat = 403

    /// Background 1's blue panel.
    static let boxLeft: CGFloat = 52
    static let boxRightInset: CGFloat = 56
    static let boxGlowWidth: CGFloat = 10
    static let boxGlowBlur: CGFloat = 7

    /// Background 2's three day panels: 174 wide with a 20pt gap.
    static let panelTop: CGFloat = 100
    static let panelBottom: CGFloat = 397
    static let panelWidth: CGFloat = 174
    static let panelGap: CGFloat = 20
    static let panelFirstLeft: CGFloat = 38
    static let panelBorderDarkWidth: CGFloat = 2
    static let panelBorderLightWidth: CGFloat = 4

    static let almanacGradientBottom: CGFloat = 189
}

/// The WeatherStar background, drawn as vector art.
///
/// Upstream ships these as 640×480 PNGs. Drawing them instead means they stay sharp
/// when the canvas is scaled — on a 4K TV the canvas is 4.5×, where an upscaled
/// bitmap would visibly soften. Every coordinate below is in design points and is
/// multiplied by the current scale, so the geometry is identical at any size.
public struct StarBackground: View {
    @Environment(\.starMetrics) private var metrics

    private let style: StarBackgroundStyle

    public init(style: StarBackgroundStyle) {
        self.style = style
    }

    public var body: some View {
        Canvas(opaque: true, rendersAsynchronously: false) { context, size in
            draw(in: &context, size: size)
        }
        .drawingGroup()
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let scale = metrics.scale
        /// Design points to output points.
        func s(_ value: CGFloat) -> CGFloat { value * scale }

        // Hazards is a flat field with no frame at all.
        if style == .seven {
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(BG.hazard))
            return
        }

        drawNavyField(&context, size: size, s: s)
        drawBody(&context, size: size, s: s)
        drawHeaderStripe(&context, size: size, s: s)
        drawFooter(&context, size: size, s: s)

        switch style {
        case .one, .chart:
            drawBluePanel(&context, size: size, s: s)
        case .two:
            drawDayPanels(&context, size: size, s: s)
        case .three, .five, .seven:
            break
        }
    }

    // MARK: - Frame

    private func drawNavyField(
        _ context: inout GraphicsContext,
        size: CGSize,
        s: (CGFloat) -> CGFloat
    ) {
        context.fill(
            Path(CGRect(x: 0, y: 0, width: size.width, height: s(Metrics.bodyTop))),
            with: .color(BG.navy)
        )
    }

    /// The body area between the header and the footer. Each background fills this
    /// differently; the sunset wash shows through wherever a panel does not cover it.
    private func drawBody(
        _ context: inout GraphicsContext,
        size: CGSize,
        s: (CGFloat) -> CGFloat
    ) {
        let top = s(Metrics.bodyTop)
        let bottom = s(Metrics.bodyBottom)
        let rect = CGRect(x: 0, y: top, width: size.width, height: bottom - top)

        switch style {
        case .five:
            context.fill(Path(rect), with: .color(BG.regionalBody))

        case .three:
            // Almanac: a brighter wash that resolves sooner, then a grey field.
            let gradientBottom = s(Metrics.almanacGradientBottom)
            context.fill(
                Path(CGRect(x: 0, y: top, width: size.width, height: gradientBottom - top)),
                with: .linearGradient(
                    Gradient(colors: [BG.sunsetTop, BG.sunsetBrightBottom]),
                    startPoint: CGPoint(x: 0, y: top),
                    endPoint: CGPoint(x: 0, y: gradientBottom)
                )
            )
            context.fill(
                Path(CGRect(x: 0, y: gradientBottom, width: size.width, height: bottom - gradientBottom)),
                with: .color(BG.almanacBody)
            )

        case .one, .two, .chart:
            context.fill(
                Path(rect),
                with: .linearGradient(
                    Gradient(colors: [BG.sunsetTop, BG.sunsetBottom]),
                    startPoint: CGPoint(x: 0, y: top),
                    endPoint: CGPoint(x: 0, y: bottom)
                )
            )

        case .seven:
            context.fill(Path(rect), with: .color(BG.hazard))
        }
    }

    /// The orange header stripe, whose right edge is cut on a diagonal.
    private func drawHeaderStripe(
        _ context: inout GraphicsContext,
        size: CGSize,
        s: (CGFloat) -> CGFloat
    ) {
        let top = s(Metrics.stripeTop)
        let bottom = s(Metrics.stripeBottom)

        // On the wide canvas the stripe grows with the frame, so the diagonal stays
        // the same distance from the right edge as it is at 640pt.
        let rightInsetTop = size.width - s(Metrics.stripeRightAtTop)
        let rightInsetBottom = size.width - s(Metrics.stripeRightAtBottom)

        var path = Path()
        path.move(to: CGPoint(x: 0, y: top))
        path.addLine(to: CGPoint(x: size.width - rightInsetTop, y: top))
        path.addLine(to: CGPoint(x: size.width - rightInsetBottom, y: bottom))
        path.addLine(to: CGPoint(x: 0, y: bottom))
        path.closeSubpath()

        context.fill(
            path,
            with: .linearGradient(
                Gradient(colors: [BG.stripeTop, BG.stripeBottom]),
                startPoint: CGPoint(x: 0, y: top),
                endPoint: CGPoint(x: 0, y: bottom)
            )
        )
    }

    /// Footer band, preceded by the dark and light rules that separate it.
    private func drawFooter(
        _ context: inout GraphicsContext,
        size: CGSize,
        s: (CGFloat) -> CGFloat
    ) {
        let rules: [(y: CGFloat, height: CGFloat, color: Color)] = [
            (Metrics.footerDarkRule, Metrics.footerLightRule - Metrics.footerDarkRule, BG.footerDarkRule),
            (Metrics.footerLightRule, Metrics.footerTop - Metrics.footerLightRule, BG.footerLightRule),
        ]

        for rule in rules {
            context.fill(
                Path(CGRect(x: 0, y: s(rule.y), width: size.width, height: max(s(rule.height), 1))),
                with: .color(rule.color)
            )
        }

        let footerTop = s(Metrics.footerTop)
        context.fill(
            Path(CGRect(x: 0, y: footerTop, width: size.width, height: size.height - footerTop)),
            with: .color(BG.footer)
        )
    }

    // MARK: - Panels

    /// Background 1's inset blue panel with its glowing edge.
    private func drawBluePanel(
        _ context: inout GraphicsContext,
        size: CGSize,
        s: (CGFloat) -> CGFloat
    ) {
        let rect = CGRect(
            x: s(Metrics.boxLeft),
            y: s(Metrics.bodyTop),
            width: size.width - s(Metrics.boxLeft) - s(Metrics.boxRightInset),
            height: s(Metrics.bodyBottom) - s(Metrics.bodyTop)
        )

        context.fill(Path(rect), with: .color(BG.boxFill))

        // A blurred stroke along the edge produces the glow that spills both inward
        // over the fill and outward over the sunset wash.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: s(Metrics.boxGlowBlur)))
            layer.stroke(
                Path(rect),
                with: .color(BG.boxGlow),
                lineWidth: s(Metrics.boxGlowWidth)
            )
        }
    }

    /// Background 2's three day panels, each a blue gradient in a two-tone border.
    private func drawDayPanels(
        _ context: inout GraphicsContext,
        size: CGSize,
        s: (CGFloat) -> CGFloat
    ) {
        let top = s(Metrics.panelTop)
        let bottom = s(Metrics.panelBottom)

        // Center the three-panel group so it stays put on the wider canvas.
        let groupWidth = 3 * Metrics.panelWidth + 2 * Metrics.panelGap
        let designWidth = size.width / max(s(1), 0.0001)
        let firstLeft = designWidth > 640
            ? (designWidth - groupWidth) / 2
            : Metrics.panelFirstLeft

        for index in 0..<3 {
            let left = s(firstLeft + CGFloat(index) * (Metrics.panelWidth + Metrics.panelGap))
            let outer = CGRect(x: left, y: top, width: s(Metrics.panelWidth), height: bottom - top)

            context.fill(Path(outer), with: .color(BG.panelBorderDark))

            let light = outer.insetBy(dx: s(Metrics.panelBorderDarkWidth), dy: s(Metrics.panelBorderDarkWidth))
            context.fill(Path(light), with: .color(BG.panelBorderLight))

            let inner = light.insetBy(dx: s(Metrics.panelBorderLightWidth), dy: s(Metrics.panelBorderLightWidth))
            context.fill(
                Path(inner),
                with: .linearGradient(
                    Gradient(colors: [BG.panelTop, BG.panelBottom]),
                    startPoint: CGPoint(x: 0, y: inner.minY),
                    endPoint: CGPoint(x: 0, y: inner.maxY)
                )
            )
        }
    }
}

extension Color {
    /// Build a color from a 0xRRGGBB literal, which keeps the measured values above
    /// readable next to the hex codes they came from.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
