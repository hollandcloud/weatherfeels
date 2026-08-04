import CoreText
import OSLog
import SwiftUI
import WeatherStarResources

/// The four Star4000 typefaces the WeatherStar uses.
///
/// The converted TTFs carry PostScript names that differ from the CSS aliases
/// upstream declares via `@font-face`, so the real names are bound here.
public enum StarFont: String, Sendable, CaseIterable {
    /// Body text. CSS calls this `Star4000`.
    case regular = "STAR4"
    /// Condensed text used for the clock and column headers. CSS: `Star4000 Small`.
    case small = "STAR4Small"
    /// Heavy face for temperatures and table rows. CSS: `Star4000 Large`.
    case large = "Star4000LargeCM"
    /// Wide face used in the Current Conditions left column. CSS: `Star4000 Extended`.
    case extended = "STAR4Extended"

    var fileName: String {
        switch self {
        case .regular: "Star4000.ttf"
        case .small: "Star4000 Small.ttf"
        case .large: "Star4000 Large.ttf"
        case .extended: "Star4000 Extended.ttf"
        }
    }


    /// Width of a string in design points at the given size.
    ///
    /// Measured with Core Text rather than by laying the text out in SwiftUI, so the
    /// marquee can compute its scroll distance and duration up front instead of
    /// waiting for a layout pass to report back.
    @MainActor
    public func textWidth(_ string: String, size: CGFloat) -> CGFloat {
        StarFontLoader.registerFonts()
        let font = CTFontCreateWithName(rawValue as CFString, size, nil)
        let attributed = NSAttributedString(
            string: string,
            attributes: [kCTFontAttributeName as NSAttributedString.Key: font]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }

    /// Height of wrapped text in design points, for a given wrap width.
    ///
    /// The scrolling displays need their true content height to work out how far and
    /// how long to scroll. Measuring the rendered view returned the *clipped* viewport
    /// height instead, so nothing ever scrolled; computing it here from the same font
    /// metrics SwiftUI uses avoids the round-trip entirely.
    @MainActor
    public func textHeight(
        _ string: String,
        size: CGFloat,
        width: CGFloat,
        lineSpacing: CGFloat = 0
    ) -> CGFloat {
        guard !string.isEmpty, width > 0 else { return 0 }
        StarFontLoader.registerFonts()

        let font = CTFontCreateWithName(rawValue as CFString, size, nil)
        var attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font
        ]

        // Line spacing has to go through a paragraph style or the framesetter ignores it.
        if lineSpacing > 0 {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = lineSpacing
            attributes[.paragraphStyle] = paragraph
        }

        let attributed = NSAttributedString(string: string, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: width, height: .greatestFiniteMagnitude),
            nil
        )
        return ceil(suggested.height)
    }

    /// A SwiftUI font at a design-space size, scaled for the current output.
    public func font(size: CGFloat, scale: CGFloat = 1) -> Font {
        // Registering by PostScript name means Core Text rasterizes the outlines at
        // the final size, which is what keeps text sharp when scaled up for 4K.
        .custom(rawValue, fixedSize: size * scale)
    }
}

/// Registers the bundled fonts with Core Text.
///
/// SwiftPM resources are not covered by `UIAppFonts`/`ATSApplicationFontsPath`, so
/// registration has to happen in code. Safe to call more than once.
public enum StarFontLoader {
    private static let logger = Logger(subsystem: "net.weatherstar.ui", category: "Fonts")
    @MainActor private static var didRegister = false

    @MainActor
    public static func registerFonts() {
        guard !didRegister else { return }
        didRegister = true

        for font in StarFont.allCases {
            guard let url = WeatherStarResources.url(font.fileName, in: .fonts) else {
                logger.error("Missing font resource \(font.fileName, privacy: .public)")
                continue
            }

            var error: Unmanaged<CFError>?
            let registered = CTFontManagerRegisterFontsForURL(
                url as CFURL,
                .process,
                &error
            )

            if !registered {
                // A duplicate registration is benign — another target may have
                // registered the same file already.
                let description = error?.takeRetainedValue().localizedDescription ?? "unknown"
                logger.warning(
                    "Font \(font.fileName, privacy: .public) not registered: \(description, privacy: .public)"
                )
            }
        }
    }

    /// Verify each face resolves, for diagnostics and tests.
    @MainActor
    public static func availableFonts() -> [StarFont: Bool] {
        registerFonts()
        var result: [StarFont: Bool] = [:]
        for font in StarFont.allCases {
            let ctFont = CTFontCreateWithName(font.rawValue as CFString, 32, nil)
            let resolved = CTFontCopyPostScriptName(ctFont) as String
            result[font] = resolved == font.rawValue
        }
        return result
    }
}
