import SwiftUI
import WeatherStarKit

/// A local ad card, in the rotation's ad break.
///
/// Laid out the way a WeatherStar-era local spot was: the business's name in the title face,
/// a line about it, a few selling points, and the telephone number large enough to read from
/// the sofa. In one of five themes, each a pair of colours from the period's palette, under the
/// same orange-to-purple stripe the displays carry. An image from the server sits beside the
/// text, or fills the card on its own when the manifest says so.
struct AdCardScreen: View {
    @Environment(\.starMetrics) private var metrics
    @Environment(\.starContentWidth) private var contentWidth

    let card: AdCard
    let image: CGImage?

    private static let stripeTop = Color(hex: 0xC05C03)
    private static let stripeBottom = Color(hex: 0x4A223E)

    static func colours(for theme: AdCard.Theme) -> (top: Color, bottom: Color) {
        switch theme {
        case .blue: (StarColor.backgroundTop, StarColor.backgroundBottom)
        case .red: (Color(hex: 0x8A1C1C), Color(hex: 0x3A0909))
        case .green: (Color(hex: 0x1E6B2E), Color(hex: 0x0B2E14))
        case .gold: (Color(hex: 0x9A6A00), Color(hex: 0x3D2A00))
        case .purple: (Color(hex: 0x4B2A8A), Color(hex: 0x1C0F3A))
        }
    }

    var body: some View {
        let height = metrics.space.height
        let colours = Self.colours(for: card.theme)

        ZStack {
            LinearGradient(colors: [colours.top, colours.bottom], startPoint: .top, endPoint: .bottom)

            if card.imageMode == .full, let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .designFrame(width: contentWidth, height: height)
            } else {
                content(height: height)
            }
        }
        .designFrame(width: contentWidth, height: height)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            ["Advertisement", card.business, card.headline, card.lines.joined(separator: ". "), card.phone, card.footer]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: ". ")
        )
    }

    private func content(height: CGFloat) -> some View {
        let margin: CGFloat = 40
        let width = contentWidth - 2 * margin
        let hasImage = image != nil

        return VStack(spacing: 0) {
            stripe.designPadding(.top, 26)

            StarText(card.business, font: .large, size: 48, color: StarColor.title, alignment: .center, lineLimit: 1, minimumScaleFactor: 0.5)
                .designFrame(width: width, alignment: .center)
                .designPadding(.top, 12)

            if let headline = card.headline, !headline.isEmpty {
                StarText(headline, font: .regular, size: 30, alignment: .center, lineLimit: 1, minimumScaleFactor: 0.6)
                    .designFrame(width: width, alignment: .center)
                    .designPadding(.top, 4)
            }

            stripe.designPadding(.top, 12)

            HStack(alignment: .center, spacing: 0) {
                if let image, hasImage {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                        .designFrame(width: width * 0.4, height: height * 0.36)
                        .overlay(Rectangle().strokeBorder(StarColor.title.opacity(0.8), lineWidth: 2))
                        .designPadding(.trailing, 20)
                }
                VStack(alignment: hasImage ? .leading : .center, spacing: 6) {
                    ForEach(Array(card.lines.enumerated()), id: \.offset) { _, line in
                        StarText(line, font: .regular, size: 28, alignment: hasImage ? .leading : .center, lineLimit: 1, minimumScaleFactor: 0.6)
                    }
                }
                .designFrame(width: hasImage ? width * 0.6 - 20 : width, alignment: hasImage ? .leading : .center)
            }
            .designFrame(width: width)
            .frame(maxHeight: .infinity)

            if let phone = card.phone, !phone.isEmpty {
                StarText(phone, font: .large, size: 46, color: StarColor.title, alignment: .center, lineLimit: 1, minimumScaleFactor: 0.6)
                    .designFrame(width: width, alignment: .center)
            }
            if let footer = card.footer, !footer.isEmpty {
                StarText(footer, font: .small, size: 24, alignment: .center, lineLimit: 1, minimumScaleFactor: 0.6)
                    .designFrame(width: width, alignment: .center)
                    .designPadding(.top, 4)
            }
        }
        .designPadding(.bottom, 26)
        .designFrame(width: contentWidth, height: height)
    }

    private var stripe: some View {
        LinearGradient(colors: [Self.stripeTop, Self.stripeBottom], startPoint: .top, endPoint: .bottom)
            .designFrame(width: contentWidth, height: 6)
    }
}
