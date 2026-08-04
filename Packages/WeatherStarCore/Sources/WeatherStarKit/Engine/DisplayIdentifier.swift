import Foundation

/// The displays in the rotation, in the order the WeatherStar cycles them.
///
/// The raw values match upstream's element ids so a shared permalink or an existing
/// ws4kp configuration maps across unchanged. `order` is upstream's `navId`.
public enum DisplayIdentifier: String, Codable, Sendable, CaseIterable, Identifiable {
    case hazards = "hazards"
    case currentWeather = "current-weather"
    case latestObservations = "latest-observations"
    case hourly = "hourly"
    case hourlyGraph = "hourly-graph"
    case travel = "travel"
    case regionalForecast = "regional-forecast"
    case localForecast = "local-forecast"
    case extendedForecast = "extended-forecast"
    case almanac = "almanac"
    case spcOutlook = "spc-outlook"
    case radar = "radar"

    public var id: String { rawValue }

    /// Position in the rotation. Matches upstream's `navId`.
    public var order: Int {
        switch self {
        case .hazards: 0
        case .currentWeather: 1
        case .latestObservations: 2
        case .hourly: 3
        case .hourlyGraph: 4
        case .travel: 5
        case .regionalForecast: 6
        case .localForecast: 7
        case .extendedForecast: 8
        case .almanac: 9
        case .spcOutlook: 10
        case .radar: 11
        }
    }

    /// Title shown in the settings list.
    public var name: String {
        switch self {
        case .hazards: "Hazards"
        case .currentWeather: "Current Conditions"
        case .latestObservations: "Latest Observations"
        case .hourly: "Hourly Forecast"
        case .hourlyGraph: "Hourly Graph"
        case .travel: "Travel Forecast"
        case .regionalForecast: "Regional Observations"
        case .localForecast: "Local Forecast"
        case .extendedForecast: "Extended Forecast"
        case .almanac: "Almanac"
        case .spcOutlook: "SPC Outlook"
        case .radar: "Radar"
        }
    }

    /// Header text drawn at the top of the display. Two lines when `bottom` is set.
    public var header: (top: String, bottom: String?) {
        switch self {
        case .hazards: ("Hazards", nil)
        case .currentWeather: ("Current", "Conditions")
        case .latestObservations: ("Latest", "Observations")
        case .hourly: ("Hourly Forecast", nil)
        case .hourlyGraph: ("Hourly", "Graph")
        case .travel: ("Travel Forecast", "For ")
        case .regionalForecast: ("Regional", "Observations")
        case .localForecast: ("Local", "Forecast")
        case .extendedForecast: ("Extended", "Forecast")
        case .almanac: ("Almanac", nil)
        case .spcOutlook: ("SPC Outlook", nil)
        case .radar: ("Local", "Radar")
        }
    }

    /// Whether the display is in the rotation on a fresh install.
    /// Hourly and Travel are off by default upstream; we keep that.
    public var isEnabledByDefault: Bool {
        switch self {
        case .hourly, .travel, .hourlyGraph, .spcOutlook: false
        default: true
        }
    }

    /// Displays enabled on first launch.
    public static var defaultEnabled: [DisplayIdentifier] {
        allCases.filter(\.isEnabledByDefault)
    }

    /// Rotation order.
    public static var rotationOrder: [DisplayIdentifier] {
        allCases.sorted { $0.order < $1.order }
    }

    /// Which background art the display uses. Drawn procedurally so it stays sharp
    /// at any resolution; the number matches upstream's `backgrounds/N.png`.
    public var backgroundStyle: StarBackgroundStyle {
        switch self {
        case .extendedForecast: .two
        case .almanac: .three
        case .hazards: .seven
        case .regionalForecast: .five
        case .hourlyGraph: .chart
        default: .one
        }
    }

    /// Hazards is drawn without the standard header/clock, like upstream.
    public var drawsHeader: Bool { self != .hazards }

    /// Whether the header shows the clock and date.
    ///
    /// The Hourly Graph omits them (upstream passes `hasTime: false`) because its
    /// legend occupies that corner instead.
    public var showsClock: Bool { self != .hourlyGraph }

    /// Whether the display uses the full width of the wide canvas.
    ///
    /// Upstream marks these `can-enhance`: under `.wide.enhanced` they reset to
    /// `left: 0; width: 854px`, while every other display keeps its 640pt layout
    /// shifted right by the 107pt margin. Without this distinction the wide canvas
    /// just adds dead space to the right of a 640pt layout.
    public var expandsToWideCanvas: Bool {
        switch self {
        case .currentWeather, .latestObservations, .localForecast,
             .regionalForecast, .almanac, .hazards, .radar:
            true
        default:
            false
        }
    }

    /// Whether the bottom conditions ticker shows over this display.
    public var showsScroll: Bool {
        switch self {
        case .hazards, .radar: false
        default: true
        }
    }

    /// The NOAA logo appears on displays sourced directly from observations.
    public var showsNOAALogo: Bool {
        switch self {
        case .currentWeather, .latestObservations, .localForecast: true
        default: false
        }
    }
}

/// Loading state for one display, mirroring `status.mjs`.
public enum DisplayStatus: Sendable, Hashable {
    case loading
    case loaded
    case failed
    case noData
    case disabled
    case retrying

    /// Color used for the status text in the display picker.
    public var isUsable: Bool { self == .loaded }
}

/// Which procedural background a display draws.
public enum StarBackgroundStyle: Sendable, Hashable {
    case one
    case two
    case three
    case five
    case seven
    case chart
}
