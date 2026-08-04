import Foundation
import OSLog
import WeatherStarResources

/// A city/station table shipped with the app, generated upstream by
/// `datagenerators/` and copied verbatim so results match ws4kp.

/// Metadata for an observation station, keyed by its 4-letter identifier.
/// Provides the friendlier city name the displays prefer over the raw NWS name.
public struct StationRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var lat: Double
    public var lon: Double
    public var state: String?
    public var city: String?
    /// Lower numbers are preferred when several stations serve the same area.
    public var priority: Int?
}

/// A grid point on the NWS forecast grid, as the generated tables record it.
public struct GridPoint: Codable, Sendable, Hashable {
    public var x: Int
    public var y: Int
    /// Weather Forecast Office, e.g. "MLB".
    public var wfo: String
}

/// One of the fixed national cities in the Travel Forecast rotation.
public struct TravelCity: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var point: GridPoint?

    public var id: String { name }

    private enum CodingKeys: String, CodingKey {
        case name = "Name"
        case latitude = "Latitude"
        case longitude = "Longitude"
        case point
    }
}

/// A city plotted on the Regional Observations map.
public struct RegionalCity: Codable, Sendable, Hashable, Identifiable {
    public var city: String
    public var latitude: Double
    public var longitude: Double
    public var point: GridPoint?

    public var id: String { city }

    private enum CodingKeys: String, CodingKey {
        case city, lat, lon, point
    }

    // The generated table stores lat/lon as strings for regional cities but as
    // numbers for travel cities, so accept either here.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        city = try container.decode(String.self, forKey: .city)
        point = try container.decodeIfPresent(GridPoint.self, forKey: .point)
        latitude = try container.decodeFlexibleDouble(forKey: .lat)
        longitude = try container.decodeFlexibleDouble(forKey: .lon)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(city, forKey: .city)
        try container.encode(latitude, forKey: .lat)
        try container.encode(longitude, forKey: .lon)
        try container.encodeIfPresent(point, forKey: .point)
    }
}

extension KeyedDecodingContainer {
    /// Decode a Double that may be encoded as a JSON string.
    func decodeFlexibleDouble(forKey key: Key) throws -> Double {
        if let value = try? decode(Double.self, forKey: key) { return value }
        let string = try decode(String.self, forKey: key)
        guard let value = Double(string) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "Expected a number or numeric string, got \(string)"
            )
        }
        return value
    }
}

/// Lazily-loaded accessors for the bundled tables.
///
/// Each table is parsed once on first use. A parse failure logs and yields an empty
/// table, which degrades the affected display rather than taking down the app.
public enum BundledData {
    private static let logger = Logger(subsystem: "net.weatherstar.kit", category: "BundledData")

    public static let stations: [String: StationRecord] = load(
        "stations.json", as: [String: StationRecord].self, fallback: [:]
    )

    public static let travelCities: [TravelCity] = load(
        "travelcities.json", as: [TravelCity].self, fallback: []
    )

    public static let regionalCities: [RegionalCity] = correctNames(
        load("regionalcities.json", as: [RegionalCity].self, fallback: [])
    )

    /// Corrections for mislabelled entries in the upstream generated table.
    ///
    /// `regionalcities.json` names the entry at 26.63°N, 81.96°W "Cape Cod", but those
    /// are Cape Coral, Florida's coordinates — Cape Cod is in Massachusetts at 41.7°N.
    /// Left alone it plots as "Cape Cod" in south-west Florida.
    private static let nameCorrections: [String: String] = [
        "Cape Cod": "Cape Coral",
    ]

    private static func correctNames(_ cities: [RegionalCity]) -> [RegionalCity] {
        cities.map { city in
            guard let corrected = nameCorrections[city.city] else { return city }
            var fixed = city
            fixed.city = corrected
            return fixed
        }
    }

    private static func load<T: Decodable>(
        _ fileName: String,
        as type: T.Type,
        fallback: T
    ) -> T {
        do {
            let data = try WeatherStarResources.data(fileName, in: .data)
            return try JSONDecoder().decode(type, from: data)
        } catch {
            logger.error("Could not load \(fileName): \(error.localizedDescription)")
            return fallback
        }
    }

    /// City name for a station identifier, preferring the curated table.
    public static func cityName(forStation identifier: String) -> String? {
        stations[identifier]?.city
    }

    /// Regional cities nearest a point, for the Regional Observations map.
    public static func regionalCities(
        near latitude: Double,
        longitude: Double,
        limit: Int
    ) -> [RegionalCity] {
        regionalCities
            .map { city in
                (
                    city,
                    Calc.haversineKilometers(
                        lat1: latitude, lon1: longitude,
                        lat2: city.latitude, lon2: city.longitude
                    )
                )
            }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map(\.0)
    }
}
