import SwiftUI
import WeatherStarKit

/// The "Local on the 8s" bumper: the card that went up as national programming cut away to
/// the local forecast.
///
/// In the WeatherStar's own vocabulary — the blue field, the orange-to-purple stripe of its
/// header, Star4000 lettering — so it reads as the channel introducing itself rather than as
/// an app announcement.
struct EightsBumper: View {
    @Environment(\.starMetrics) private var metrics
    @Environment(\.starContentWidth) private var contentWidth

    /// "Tampa, FL", or nothing before a place is chosen.
    let place: String?
    let time: String

    private static let stripeTop = Color(hex: 0xC05C03)
    private static let stripeBottom = Color(hex: 0x4A223E)

    var body: some View {
        let height = metrics.space.height
        ZStack {
            LinearGradient(
                colors: [StarColor.backgroundTop, StarColor.backgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                LinearGradient(
                    colors: [Self.stripeTop, Self.stripeBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .designFrame(width: contentWidth, height: 6)
                .designPadding(.bottom, 18)

                StarText("Local", font: .large, size: 60, color: StarColor.title, alignment: .center)
                    .designFrame(width: contentWidth, alignment: .center)
                StarText("on the 8s", font: .large, size: 60, color: StarColor.title, alignment: .center)
                    .designFrame(width: contentWidth, alignment: .center)

                LinearGradient(
                    colors: [Self.stripeTop, Self.stripeBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .designFrame(width: contentWidth, height: 6)
                .designPadding(.top, 18)

                if let place {
                    StarText(
                        "Your local forecast for \(place)",
                        font: .regular,
                        size: 28,
                        alignment: .center,
                        lineLimit: 1,
                        minimumScaleFactor: 0.6
                    )
                    .designFrame(width: contentWidth - 60, alignment: .center)
                    .designPadding(.top, 22)
                }
                Spacer(minLength: 0)
                StarText(time, font: .small, size: 28, color: StarColor.dateTime, alignment: .center)
                    .designFrame(width: contentWidth, alignment: .center)
                    .designPadding(.bottom, 24)
            }
        }
        .designFrame(width: contentWidth, height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Local on the 8s\(place.map { ", for \($0)" } ?? "")")
    }
}
