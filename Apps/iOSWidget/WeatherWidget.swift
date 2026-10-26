import SwiftUI
import WeatherStarKit
import WeatherStarUI
import WidgetKit

/// The home screen and StandBy widget.
///
/// The widget fetches its own weather for the place the app shares with it, so it stays current
/// when the app has not been opened for hours. It refreshes every half hour, which is about how
/// often a station reports and well inside the budget WidgetKit gives a widget.
@main
struct WeatherFeelsWidgets: WidgetBundle {
    var body: some Widget {
        CurrentConditionsWidget()
    }
}

struct ConditionsEntry: TimelineEntry {
    let date: Date
    let weather: WidgetWeather?
}

struct ConditionsProvider: TimelineProvider {
    private static let refresh: TimeInterval = 30 * 60

    func placeholder(in context: Context) -> ConditionsEntry {
        ConditionsEntry(date: .now, weather: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (ConditionsEntry) -> Void) {
        // The gallery preview: a fixed sample, so it never waits on the network.
        guard !context.isPreview else {
            completion(ConditionsEntry(date: .now, weather: .sample))
            return
        }
        Task {
            completion(ConditionsEntry(date: .now, weather: await Self.current()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<ConditionsEntry>) -> Void) {
        Task {
            let entry = ConditionsEntry(date: .now, weather: await Self.current())
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(Self.refresh))))
        }
    }

    private static func current() async -> WidgetWeather? {
        guard let shared = SharedContainer.shared() else { return nil }
        return await WidgetWeatherService.fetch(location: shared.location, units: shared.units)
    }
}

struct CurrentConditionsWidget: Widget {
    init() {
        StarFontLoader.registerFonts()
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "net.weatherstar.current-conditions", provider: ConditionsProvider()) { entry in
            ConditionsWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) { WeatherWidgetBackground() }
        }
        .configurationDisplayName("Current Conditions")
        .description("The current conditions where you are, WeatherStar style.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        // The layouts carry their own margins, sized for the Star4000 faces; the system's
        // would double them, and the large table would lose rows it has room for.
        .contentMarginsDisabled()
        // StandBy drops a widget's background by default, which would leave the text on
        // black. The blue field is the point.
        .containerBackgroundRemovable(false)
    }
}

struct ConditionsWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ConditionsEntry

    var body: some View {
        WeatherWidgetView(weather: entry.weather, size: size)
    }

    /// StandBy shows the small size.
    private var size: WeatherWidgetView.Size {
        switch family {
        case .systemMedium: .medium
        case .systemLarge: .large
        default: .small
        }
    }
}

extension WidgetWeather {
    static let sample = WidgetWeather(
        place: "Tampa, FL", temperature: "79\u{00B0}", condition: "Mostly Cloudy",
        icon: "https://api.weather.gov/icons/land/day/bkn", observedAt: nil,
        readings: [
            .init("Wind:", "E 9"), .init("Humidity:", "68%"), .init("Dewpoint:", "68\u{00B0}"),
            .init("Visibility:", "10 mi."), .init("Pressure:", "30.01 in.hg"), .init("Heat Index:", "82\u{00B0}"),
        ]
    )
}
