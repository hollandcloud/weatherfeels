import SwiftUI
import WeatherStarKit

/// The home screen and StandBy widget: the current conditions in WeatherStar dress.
///
/// Here rather than in the widget extension so it can be drawn by the snapshot tests on a Mac,
/// and so it uses the same Star4000 text and pixel icons as the displays. Laid out in points:
/// the design-space scale is one, since a widget is drawn at the size it is shown.
public struct WeatherWidgetView: View {
    public enum Size: Sendable {
        case small
        case medium
        case large
    }

    let weather: WidgetWeather?
    let size: Size

    public init(weather: WidgetWeather?, size: Size) {
        self.weather = weather
        self.size = size
    }

    static let stripeTop = Color(hex: 0xC05C03)
    static let stripeBottom = Color(hex: 0x4A223E)

    /// One design point to one point.
    private static let metrics = StarMetrics(
        space: .standard, scale: 1, origin: .zero, scaledSize: CGSize(width: 640, height: 480)
    )

    public var body: some View {
        Group {
            if let weather {
                switch size {
                case .small: small(weather)
                case .medium: medium(weather)
                case .large: large(weather)
                }
            } else {
                placeholder
            }
        }
        .environment(\.starMetrics, Self.metrics)
    }

    private func small(_ weather: WidgetWeather) -> some View {
        VStack(spacing: 2) {
            StarText(place(weather), font: .small, size: 15, color: StarColor.title, alignment: .center, shadowOffset: 1.5, outlineWidth: 1, lineLimit: 1, minimumScaleFactor: 0.6)
            HStack(spacing: 4) {
                icon(weather, height: 48)
                StarText(weather.temperature, font: .large, size: 40, shadowOffset: 2, outlineWidth: 1, lineLimit: 1, minimumScaleFactor: 0.6)
            }
            StarText(weather.condition, font: .regular, size: 16, alignment: .center, shadowOffset: 1.5, outlineWidth: 1, lineLimit: 2, minimumScaleFactor: 0.6)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(weather.place): \(weather.temperature), \(weather.condition)")
    }

    private func medium(_ weather: WidgetWeather) -> some View {
        summary(weather)
            .padding(.horizontal, 16)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(weather.place): \(weather.temperature), \(weather.condition)")
    }

    /// The medium widget over the rest of the Current Conditions panel.
    private func large(_ weather: WidgetWeather) -> some View {
        VStack(spacing: 0) {
            summary(weather)
            if !weather.readings.isEmpty {
                LinearGradient(colors: [Self.stripeTop, Self.stripeBottom], startPoint: .top, endPoint: .bottom)
                    .frame(height: 3)
                    .padding(.vertical, 12)
                // The large widget runs from 382pt tall down to 324 on the smallest phones: the
                // table steps down a size, then gives up its last rows one at a time, rather
                // than run off the end.
                ViewThatFits(in: .vertical) {
                    table(weather.readings, size: 18, spacing: 8)
                    ForEach(Array(stride(from: weather.readings.count, through: 1, by: -1)), id: \.self) { count in
                        table(Array(weather.readings.prefix(count)), size: 15, spacing: 4)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            (["\(weather.place): \(weather.temperature), \(weather.condition)"]
                + weather.readings.map { "\($0.label) \($0.value)" })
                .joined(separator: ". ")
        )
    }

    private func table(_ readings: [WidgetWeather.Reading], size: CGFloat, spacing: CGFloat) -> some View {
        VStack(spacing: spacing) {
            ForEach(readings, id: \.label) { reading in
                HStack(spacing: 0) {
                    StarText(reading.label, font: .large, size: size, shadowOffset: 1.5, outlineWidth: 1, lineLimit: 1, minimumScaleFactor: 0.6)
                    Spacer(minLength: 8)
                    StarText(reading.value, font: .large, size: size, alignment: .trailing, shadowOffset: 1.5, outlineWidth: 1, lineLimit: 1, minimumScaleFactor: 0.8)
                        .layoutPriority(1)
                }
            }
        }
        .padding(.horizontal, 8)
    }

    /// Icon and temperature beside the place, condition and time: the medium widget, and the
    /// top of the large one.
    private func summary(_ weather: WidgetWeather) -> some View {
        HStack(spacing: 12) {
            VStack(spacing: 2) {
                icon(weather, height: 62)
                StarText(weather.temperature, font: .large, size: 44, shadowOffset: 2, outlineWidth: 1, lineLimit: 1, minimumScaleFactor: 0.6)
            }
            VStack(alignment: .leading, spacing: 4) {
                StarText("Current Conditions", font: .small, size: 13, color: StarColor.dateTime, shadowOffset: 1, outlineWidth: 0.5, lineLimit: 1)
                StarText(place(weather), font: .regular, size: 20, color: StarColor.title, shadowOffset: 1.5, outlineWidth: 1, lineLimit: 1, minimumScaleFactor: 0.6)
                StarText(weather.condition, font: .regular, size: 20, shadowOffset: 1.5, outlineWidth: 1, lineLimit: 2, minimumScaleFactor: 0.6)
                if let observed = weather.observedAt {
                    StarText(
                        "Observed \(observed.formatted(date: .omitted, time: .shortened))",
                        font: .small, size: 12, color: StarColor.dateTime, shadowOffset: 1, outlineWidth: 0.5, lineLimit: 1
                    )
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            StarText("weatherfeels", font: .regular, size: 18, color: StarColor.title, alignment: .center, shadowOffset: 1.5, outlineWidth: 1)
            StarText("Open the app to choose a place", font: .small, size: 13, alignment: .center, shadowOffset: 1, outlineWidth: 0.5)
        }
        .padding(8)
    }

    /// The condition's WeatherStar icon, decoded on the spot.
    ///
    /// Not `PixelImage`, which decodes in a task: WidgetKit draws a widget's view once, and
    /// never waits for a task to finish, so the icon would never appear. A widget does not
    /// animate either, so the first frame is all it needs.
    @ViewBuilder
    private func icon(_ weather: WidgetWeather, height: CGFloat) -> some View {
        if let url = IconMapper.largeIcon(for: weather.icon).url,
           let frame = ImageDecoder.decodeSynchronously(url)?.frames.first?.image {
            Image(decorative: frame, scale: 1)
                .interpolation(.none)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: height)
        }
    }

    /// "Tampa, FL" reads as "Tampa": the state costs space a widget does not have.
    private func place(_ weather: WidgetWeather) -> String {
        weather.place.split(separator: ",").first.map(String.init) ?? weather.place
    }
}

/// The widget's background: the WeatherStar blue field under its header stripe.
public struct WeatherWidgetBackground: View {
    public init() {}

    public var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [StarColor.backgroundTop, StarColor.backgroundBottom], startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [WeatherWidgetView.stripeTop, WeatherWidgetView.stripeBottom], startPoint: .top, endPoint: .bottom)
                .frame(height: 5)
        }
    }
}
