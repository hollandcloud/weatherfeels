import CoreText
import Foundation
import SwiftUI
import WeatherStarResources

/// The corner logo and the startup title, overridable at build time.
///
/// Deliberately *not* a user setting. Branding is a property of a build — whoever ships a
/// copy decides what mark it carries — so it is read from `Info.plist`, which means a fork
/// changes it in `project.yml` and never touches Swift.
///
/// Everything is optional and falls back to the bundled WeatherStar 4000+ artwork, so a
/// stock build looks exactly as it did before this existed.
///
/// ```yaml
/// # project.yml, per target or in the shared base
/// INFOPLIST_KEY_WS4KLogoImageName: MyCornerLogo   # an image in the app's asset catalog
/// INFOPLIST_KEY_WS4KLogoLines: WEATHER|FEELS      # or let the badge be drawn from text
/// INFOPLIST_KEY_WS4KStartupTitle: My Weather      # startup screen, first line
/// INFOPLIST_KEY_WS4KStartupSubtitle: Channel      # startup screen, second line
/// ```
public enum StarBranding {
    /// Name of an image in the *app's* asset catalog to use as the corner logo.
    ///
    /// Looked up in the main bundle rather than the package's, because that is where a
    /// fork's own artwork will live. Nil falls back to `logo-corner.png` from the package.
    public static let logoImageName: String? = string(for: "WS4KLogoImageName")

    /// Lines to draw in the corner badge, in place of the bundled artwork.
    ///
    /// Separated by `|`, so a two-line mark is `WEATHER|FEELS`. Drawn rather than supplied
    /// as an image because the badge is a rounded rectangle and some centred text: asking a
    /// fork for a PNG means asking it to match the blue, the border weight and the pixel
    /// font, and to do it again at every resolution. Text is scaled to whatever the display
    /// is being rendered at, so it stays sharp on a 4K panel.
    ///
    /// Takes second place to `logoImageName`: a build that went to the trouble of supplying
    /// real artwork should get it.
    public static let logoLines: [String]? = {
        guard let value = string(for: "WS4KLogoLines") else { return nil }
        let lines = value
            .split(whereSeparator: { $0 == "|" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines
    }()

    /// Startup screen title, which upstream shows as "WeatherStar" / "4000+".
    public static let startupTitle: String = string(for: "WS4KStartupTitle") ?? "WeatherStar"
    public static let startupSubtitle: String? = {
        // An explicitly empty string means "one line only", which is different from the
        // key being absent.
        guard let value = Bundle.main.object(forInfoDictionaryKey: "WS4KStartupSubtitle") as? String
        else { return "4000+" }
        return value.isEmpty ? nil : value
    }()

    /// Whether this build replaces the bundled corner mark, by either route.
    public static var hasCustomLogo: Bool { logoImageName != nil || logoLines != nil }

    private static func string(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return value
    }
}

/// The corner logo: a build's own asset if it declared one, otherwise the bundled art.
struct StarLogo: View {
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        if let lines = StarBranding.logoLines, StarBranding.logoImageName == nil {
            StarLogoBadge(lines: lines, width: width, height: height)
        } else if let name = StarBranding.logoImageName {
            // `.interpolation(.none)` to match the bundled pixel art. A fork supplying a
            // smooth vector or photographic mark can ignore that and it will still scale
            // correctly; nearest-neighbour only matters when the source really is pixels.
            Image(name)
                .interpolation(.none)
                .antialiased(false)
                .resizable()
                .scaledToFit()
                .designFrame(width: width, height: height)
        } else {
            PixelImage(
                url: WeatherStarResources.url("logo-corner.png", in: .logos),
                width: width,
                height: height
            )
        }
    }
}

/// The corner mark, drawn: a rounded blue plate, a white keyline, and centred text.
///
/// Proportions are taken from the bundled `logo-corner.png` (85x67 with a two-pixel
/// keyline), so a drawn badge sits in the same place and reads at the same weight as the
/// artwork it replaces.
private struct StarLogoBadge: View {
    @Environment(\.starMetrics) private var metrics

    let lines: [String]
    let width: CGFloat
    let height: CGFloat

    /// Sampled from the bundled artwork rather than guessed.
    private static let plate = Color(red: 29 / 255, green: 127 / 255, blue: 255 / 255)

    /// The badge is *not* set in a Star4000 face.
    ///
    /// All four of them were tried and none is bold: they are the light, wide-spaced
    /// letterforms of a 1990 character generator, and at badge size on a busy picture they
    /// read as a thin outline where the original artwork reads as a solid mark. The artwork
    /// itself is not drawn in them either — its lettering is a bold condensed grotesque,
    /// which is what a broadcast logo of the period would have been set in.
    ///
    /// So the mark uses one too, and the pixel fonts stay where they belong: the picture.
    private static let faceCandidates = [
        "HelveticaNeue-CondensedBold",
        "HelveticaNeue-Bold",
        "Helvetica-Bold",
    ]

    /// First candidate the platform actually has, resolved once.
    private static let faceName: String = {
        for name in faceCandidates {
            let font = CTFontCreateWithName(name as CFString, 12, nil)
            if (CTFontCopyPostScriptName(font) as String) == name { return name }
        }
        // Every platform has this; the candidates above are only nicer.
        return "Helvetica-Bold"
    }()

    /// Width of `string` in the badge face, at `size`.
    private static func width(_ string: String, size: CGFloat) -> CGFloat {
        let font = CTFontCreateWithName(faceName as CFString, size, nil)
        let attributed = NSAttributedString(
            string: string,
            attributes: [kCTFontAttributeName as NSAttributedString.Key: font]
        )
        return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil)
    }

    /// Cap height in the badge face, at `size` — the ink the plate has to hold.
    ///
    /// Cap height rather than the line box, because the mark is set in capitals and the
    /// line box includes descender room that no glyph here uses. Sizing to the box leaves
    /// the plate looking half empty, which is exactly how the first attempt looked.
    private static func capHeight(size: CGFloat) -> CGFloat {
        CTFontGetCapHeight(CTFontCreateWithName(faceName as CFString, size, nil))
    }

    private var keyline: CGFloat { max(height * 0.045, 1.5) }
    private var corner: CGFloat { height * 0.13 }

    /// The largest type that fits the plate on *both* axes.
    ///
    /// Sizing from the height alone is what a first attempt does, and it looks wrong: the
    /// longest line then overflows the width, `minimumScaleFactor` claws it back, and the
    /// result is small text floating in a large plate with the vertical space it was
    /// allocated still reserved around it. Measuring the widest line with the real font and
    /// taking whichever axis binds first fills the badge the way the original artwork does.
    ///
    /// Width scales linearly with point size, so one measurement at a probe size gives the
    /// ratio for any size.
    /// The largest type that fits the plate on *both* axes, shared by every line.
    ///
    /// One size for all of them, not a per-line fit: the lines of a wordmark are set at the
    /// same size and the longest one sets it, which is why "WEATHER" fills the original
    /// badge and "STAR" does not. Letting each line scale to its own width would make the
    /// short ones balloon.
    ///
    /// Both axes are measured at a probe size and scaled, since both grow linearly with it.
    private var lineSize: CGFloat {
        let usableWidth = width - keyline * 2.4
        let usableHeight = height - keyline * 2.4

        let probe: CGFloat = 100
        let widest = lines.map { Self.width($0, size: probe) }.max() ?? probe
        // Cap height plus a little air between the lines.
        let perLine = Self.capHeight(size: probe) * 1.22

        let widthLimited = widest > 0 ? usableWidth / widest * probe : usableHeight
        let heightLimited = perLine > 0
            ? usableHeight / (perLine * CGFloat(lines.count)) * probe
            : usableHeight

        return max(min(widthLimited, heightLimited), 1)
    }

    var body: some View {
        let size = lineSize
        // Negative, to close the descender room under each line that no capital uses.
        return VStack(spacing: metrics.s(-size * 0.20)) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.custom(Self.faceName, size: metrics.s(size)))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    // The size above already fits; this only guards a face that measures
                    // slightly differently than it draws.
                    .minimumScaleFactor(0.7)
                    .designFrame(width: width - keyline * 2.4, alignment: .center)
            }
        }
        .designFrame(width: width, height: height)
        .background(
            RoundedRectangle(cornerRadius: metrics.s(corner), style: .continuous)
                .fill(Self.plate)
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.s(corner), style: .continuous)
                .strokeBorder(.white, lineWidth: metrics.s(keyline))
        )
        .accessibilityHidden(true)
    }
}
