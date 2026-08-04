import Foundation

// Models for the National Weather Service API (api.weather.gov).
// Nearly every numeric field arrives as a `QuantitativeValue` whose `value` may be
// null, so optionality here is load-bearing rather than defensive.

/// A measured value with its WMO unit code. `value` is null whenever the station
/// did not report that element.
public struct QuantitativeValue: Codable, Sendable, Hashable {
    public var value: Double?
    public var unitCode: String?
    public var qualityControl: String?

    public init(value: Double?, unitCode: String? = nil, qualityControl: String? = nil) {
        self.value = value
        self.unitCode = unitCode
        self.qualityControl = qualityControl
    }
}

/// GeoJSON geometry. Only Point and Polygon appear in the endpoints we use.
public struct NWSGeometry: Codable, Sendable, Hashable {
    public var type: String
    /// Point coordinates as `[longitude, latitude]`, when `type == "Point"`.
    public var point: (longitude: Double, latitude: Double)? {
        guard type == "Point", let flat = flattenedCoordinates, flat.count >= 2 else { return nil }
        return (flat[0], flat[1])
    }

    /// Polygon rings, when `type == "Polygon"`. Used for hazard and outlook shapes.
    public var polygons: [[(longitude: Double, latitude: Double)]]?

    private var flattenedCoordinates: [Double]?

    private enum CodingKeys: String, CodingKey {
        case type, coordinates
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)

        // `coordinates` nests to a different depth per geometry type, so try each shape.
        if let flat = try? container.decode([Double].self, forKey: .coordinates) {
            flattenedCoordinates = flat
        } else if let rings = try? container.decode([[[Double]]].self, forKey: .coordinates) {
            polygons = rings.map { ring in
                ring.compactMap { $0.count >= 2 ? ($0[0], $0[1]) : nil }
            }
        } else if let multi = try? container.decode([[[[Double]]]].self, forKey: .coordinates) {
            polygons = multi.flatMap { polygon in
                polygon.map { ring in
                    ring.compactMap { $0.count >= 2 ? ($0[0], $0[1]) : nil }
                }
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        if let flattenedCoordinates {
            try container.encode(flattenedCoordinates, forKey: .coordinates)
        } else if let polygons {
            try container.encode(
                polygons.map { $0.map { [$0.longitude, $0.latitude] } },
                forKey: .coordinates
            )
        }
    }

    public static func == (lhs: NWSGeometry, rhs: NWSGeometry) -> Bool {
        lhs.type == rhs.type && lhs.flattenedCoordinates == rhs.flattenedCoordinates
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(type)
        hasher.combine(flattenedCoordinates)
    }
}

// MARK: - /points/{lat},{lon}

public struct PointResponse: Codable, Sendable {
    public var properties: Properties

    public struct Properties: Codable, Sendable {
        public var gridId: String?
        public var gridX: Int?
        public var gridY: Int?
        public var forecast: String?
        public var forecastHourly: String?
        public var forecastGridData: String?
        public var observationStations: String?
        public var relativeLocation: RelativeLocation?
        public var forecastZone: String?
        public var county: String?
        public var timeZone: String?
        public var radarStation: String?
    }

    public struct RelativeLocation: Codable, Sendable {
        public var geometry: NWSGeometry?
        public var properties: Properties?

        public struct Properties: Codable, Sendable {
            public var city: String?
            public var state: String?
        }
    }
}

// MARK: - Observation stations

public struct StationCollection: Codable, Sendable {
    public var features: [StationFeature]
}

public struct StationFeature: Codable, Sendable, Identifiable {
    /// Full API URL for the station, used as the base for `/observations`.
    public var id: String
    public var geometry: NWSGeometry?
    public var properties: Properties

    public struct Properties: Codable, Sendable {
        public var stationIdentifier: String
        public var name: String
        public var timeZone: String?
    }

    public var latitude: Double? { geometry?.point?.latitude }
    public var longitude: Double? { geometry?.point?.longitude }
}

extension StationFeature {
    /// Upstream skips stations whose identifier starts with a letter that tends to
    /// denote a non-reporting or non-US site. Ported from `utils/string.mjs`.
    private static let skippedPrefixes: Set<Character> = [
        "U", "C", "H", "W", "Y", "T", "S", "M", "O", "L", "A",
        "F", "B", "N", "V", "R", "D", "E", "I", "G", "J",
    ]

    public var passesStationFilter: Bool {
        let id = properties.stationIdentifier
        guard id.count == 4, id.allSatisfy({ $0.isUppercase && $0.isLetter }) else { return false }
        guard let first = id.first else { return false }
        return !Self.skippedPrefixes.contains(first)
    }
}

// MARK: - Observations

public struct ObservationCollection: Codable, Sendable {
    public var features: [ObservationFeature]
}

public struct ObservationFeature: Codable, Sendable {
    public var properties: WeatherObservation
}

public struct WeatherObservation: Codable, Sendable {
    public var timestamp: Date?
    public var rawMessage: String?
    public var textDescription: String?
    public var icon: String?
    public var temperature: QuantitativeValue?
    public var dewpoint: QuantitativeValue?
    public var windDirection: QuantitativeValue?
    public var windSpeed: QuantitativeValue?
    public var windGust: QuantitativeValue?
    public var barometricPressure: QuantitativeValue?
    public var seaLevelPressure: QuantitativeValue?
    public var visibility: QuantitativeValue?
    public var relativeHumidity: QuantitativeValue?
    public var heatIndex: QuantitativeValue?
    public var windChill: QuantitativeValue?
    public var cloudLayers: [CloudLayer]?

    public struct CloudLayer: Codable, Sendable {
        public var base: QuantitativeValue?
        public var amount: String?
    }

    /// Lowest reported cloud base, which the displays label "Ceiling".
    public var ceiling: QuantitativeValue? { cloudLayers?.first?.base }

    public init() {}
}

// MARK: - Forecast

public struct ForecastResponse: Codable, Sendable {
    public var properties: Properties

    public struct Properties: Codable, Sendable {
        public var updated: Date?
        public var periods: [ForecastPeriod]
    }
}

public struct ForecastPeriod: Codable, Sendable, Identifiable {
    public var number: Int
    public var name: String?
    public var startTime: Date
    public var endTime: Date
    public var isDaytime: Bool
    /// Present as a plain number because the API always returns an integer here.
    public var temperature: Double?
    public var temperatureUnit: String?
    public var temperatureTrend: String?
    public var probabilityOfPrecipitation: QuantitativeValue?
    public var dewpoint: QuantitativeValue?
    public var relativeHumidity: QuantitativeValue?
    /// Free text such as `"10 mph"` or `"5 to 10 mph"`.
    public var windSpeed: String?
    public var windDirection: String?
    public var icon: String?
    public var shortForecast: String?
    public var detailedForecast: String?

    public var id: Int { number }

    /// Numeric wind speed in the unit the string reports, taking the high end of a range.
    public var windSpeedValue: Double? {
        guard let windSpeed else { return nil }
        let numbers = windSpeed.split(whereSeparator: { !$0.isNumber })
            .compactMap { Double($0) }
        return numbers.max()
    }
}

// MARK: - Alerts

public struct AlertCollection: Codable, Sendable {
    public var features: [AlertFeature]
}

public struct AlertFeature: Codable, Sendable, Identifiable {
    public var id: String
    public var geometry: NWSGeometry?
    public var properties: Properties

    public struct Properties: Codable, Sendable {
        public var event: String
        public var headline: String?
        public var description: String?
        public var instruction: String?
        public var severity: String?
        public var urgency: String?
        public var certainty: String?
        public var onset: Date?
        public var ends: Date?
        public var expires: Date?
        public var areaDesc: String?
        public var messageType: String?
    }
}

extension AlertFeature {
    /// Rank used to order the hazard display and pick the scroll's headline.
    public var severityRank: Int {
        switch properties.severity?.lowercased() {
        case "extreme": 0
        case "severe": 1
        case "moderate": 2
        case "minor": 3
        default: 4
        }
    }
}
