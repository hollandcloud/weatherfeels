import CoreGraphics
import Foundation

/// Everything resolved about a location before any display loads.
public struct WeatherParameters: Sendable {
    public var location: SavedLocation
    public var point: PointResponse
    public var stations: [StationFeature]
    /// Time zone the NWS reports for the point; all displayed times use it.
    public var timeZone: TimeZone

    public var latitude: Double { location.latitude }
    public var longitude: Double { location.longitude }

    /// Forecast office and grid coordinates, when the point response supplied them.
    public var grid: (office: String, x: Int, y: Int)? {
        guard let office = point.properties.gridId,
              let x = point.properties.gridX,
              let y = point.properties.gridY
        else { return nil }
        return (office, x, y)
    }

    /// City name the NWS associates with the point, for the header.
    public var cityName: String {
        point.properties.relativeLocation?.properties?.city ?? location.name
    }
}

// MARK: - Current Conditions

public struct CurrentConditionsData: Sendable {
    public var stationIdentifier: String
    public var locationName: String
    /// Already unit-converted and formatted for display.
    public var temperature: String
    public var condition: String
    public var icon: WeatherIcon
    public var wind: String
    public var windGust: String?
    public var humidity: String
    public var dewpoint: String
    public var ceiling: String
    public var visibility: String
    public var pressure: String
    /// "Heat Index" or "Wind Chill" when one applies.
    public var apparentLabel: String?
    public var apparentValue: String?
    public var observedAt: Date?
    /// True when the newest observation is old enough that the header says "Recent".
    public var isStale: Bool

    /// Numeric temperature, kept for the scroll ticker and the hourly "like" column.
    public var temperatureValue: Double?
}

// MARK: - Latest Observations

public struct ObservationRow: Sendable, Identifiable {
    public var id: String { stationIdentifier }
    public var stationIdentifier: String
    public var location: String
    public var temperature: String
    public var apparent: String
    public var weather: String
    public var wind: String
    public var isHeatIndex: Bool
    public var isWindChill: Bool
}

// MARK: - Hourly Forecast

public struct HourlyRow: Sendable, Identifiable, Equatable {
    public var id: Date { time }
    public var time: Date
    public var hourLabel: String
    public var icon: WeatherIcon
    public var temperature: String
    public var apparent: String
    public var wind: String
    public var isHeatIndex: Bool
    public var isWindChill: Bool

    /// Raw values for the Hourly Graph.
    public var temperatureValue: Double?
    public var apparentValue: Double?
    public var precipitationChance: Double?
    public var dewpointValue: Double?
    /// Percent sky cover, classified from the forecast icon's cloud-amount token.
    public var skyCoverValue: Double?
}

// MARK: - Travel Forecast

public struct TravelRow: Sendable, Identifiable, Equatable {
    public var id: String { city }
    public var city: String
    public var icon: WeatherIcon?
    public var low: String
    public var high: String
    /// Set when the city's forecast could not be loaded.
    public var isUnavailable: Bool
}

// MARK: - Regional Observations

public struct RegionalObservation: Sendable, Identifiable {
    public var id: String { city }
    public var city: String
    public var icon: WeatherIcon
    public var temperature: String
    public var latitude: Double
    public var longitude: Double
}

/// One of the three screens the Regional display cycles: current, then two
/// forecast periods.
public struct RegionalScreen: Sendable, Identifiable {
    public var id: Int { index }
    public var index: Int
    public var title: String
    public var observations: [RegionalObservation]
}

// MARK: - Local Forecast

public struct LocalForecastData: Sendable {
    /// One entry per forecast period, already prefixed with the period name.
    public var paragraphs: [String]
}

// MARK: - Extended Forecast

public struct ExtendedDay: Sendable, Identifiable {
    public var id: String { dayName }
    public var dayName: String
    public var icon: WeatherIcon
    /// Raw short forecast. Wrapping is left to the layout, which knows the real
    /// text metrics — truncating by character count here overflowed the panel.
    public var condition: String
    public var low: String
    public var high: String
}

// MARK: - Almanac

public struct AlmanacDay: Sendable, Identifiable {
    public var id: Int { offset }
    public var offset: Int
    public var dayName: String
    public var sunrise: String
    public var sunset: String
    public var moonrise: String
    public var moonset: String
}

public struct AlmanacData: Sendable {
    public var days: [AlmanacDay]
    public var moonPhases: [MoonPhaseEvent]
}

// MARK: - Hazards

public struct HazardItem: Sendable, Identifiable {
    public var id: String
    public var event: String
    public var detail: String
}

// MARK: - Scroll ticker

/// Content for the bottom ticker, which cycles through several facts about the
/// current conditions and any active hazard.
public struct ScrollContent: Sendable {
    public var header: String
    public var lines: [String]
    /// A hazard headline takes over the ticker and turns it red.
    public var hazardHeadline: String?
}

// MARK: - SPC Outlook

public struct SPCOutlookData: Sendable {
    /// Categorical risk level for the point, e.g. "Slight", or nil when none applies.
    public var risk: String?
    public var day: Int
    public var validText: String
}

// MARK: - Radar

public struct RadarFrame: Sendable, Identifiable {
    public var id: Date { timestamp }
    public var timestamp: Date
    /// Composited radar image, already colour-mapped to the WeatherStar palette.
    public var image: CGImage

    public init(timestamp: Date, image: CGImage) {
        self.timestamp = timestamp
        self.image = image
    }
}

public struct RadarData: Sendable {
    public var frames: [RadarFrame]
    public var baseMap: CGImage?
}
