import Foundation
import OSLog
import WeatherStarResources

/// A NOAA tide prediction station.
public struct TideStation: Sendable, Equatable {
    public var id: String
    public var name: String
    public var state: String
    public var latitude: Double
    public var longitude: Double
}

/// One high or low water.
public struct TideEvent: Sendable, Equatable {
    public var time: Date
    /// Height above mean lower low water, in feet or metres as asked for.
    public var height: Double
    public var isHigh: Bool
}

/// What the Tides display shows: the station and the next two days of highs and lows.
public struct TidesData: Sendable, Equatable {
    public struct Day: Sendable, Equatable {
        /// "Monday", in the forecast location's time zone.
        public var name: String
        public var events: [TideEvent]
    }

    public var station: TideStation
    public var days: [Day]
    /// "ft" or "m".
    public var unit: String
}

/// High and low tide predictions from NOAA's Center for Operational Oceanographic Products and
/// Services, for the station nearest the forecast location.
///
/// The WeatherStar ran a tide display in coastal markets. Here it enters the rotation only when
/// a station is close enough to be the viewer's own coast; inland, the display has no data and
/// drops out the way any display without data does.
public actor TideService {
    public static let shared = TideService()

    private let logger = Logger(subsystem: "net.weatherstar.kit", category: "Tides")
    private let session: URLSession

    /// How far a station can be and still count as "your" tides. Thirty kilometres reaches the
    /// coast from a city a little inland — downtown Tampa to its bay, Charleston to its harbour
    /// — without claiming Orlando for the Atlantic.
    static let maximumDistanceKilometres: Double = 30

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.httpAdditionalHeaders = ["User-Agent": NWSClient.defaultUserAgent]
        self.session = URLSession(configuration: configuration)
    }

    /// Every station, from the table `Tools/MakeTideStations.py` builds.
    public static let stations: [TideStation] = {
        guard let url = WeatherStarResources.url("tidestations.json", in: .data),
              let data = try? Data(contentsOf: url),
              let rows = try? JSONDecoder().decode([[TideStationField]].self, from: data)
        else { return [] }
        return rows.compactMap { row in
            guard row.count == 5,
                  case .text(let id) = row[0], case .text(let name) = row[1],
                  case .text(let state) = row[2], case .number(let latitude) = row[3],
                  case .number(let longitude) = row[4]
            else { return nil }
            return TideStation(id: id, name: name, state: state, latitude: latitude, longitude: longitude)
        }
    }()

    /// The table's rows mix strings and numbers.
    private enum TideStationField: Decodable {
        case text(String)
        case number(Double)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                self = .number(number)
            } else {
                self = .text(try container.decode(String.self))
            }
        }
    }

    /// The nearest station within reach of a place, or `nil` if the place is inland.
    public static func nearestStation(
        latitude: Double, longitude: Double, in stations: [TideStation] = stations
    ) -> TideStation? {
        stations
            .map { station in
                (station, Calc.haversineKilometers(
                    lat1: latitude, lon1: longitude, lat2: station.latitude, lon2: station.longitude
                ))
            }
            .filter { $0.1 <= maximumDistanceKilometres }
            .min { $0.1 < $1.1 }?
            .0
    }

    /// Today's and tomorrow's highs and lows for the station nearest a place.
    public func tides(
        latitude: Double, longitude: Double, timeZone: TimeZone, metric: Bool, now: Date = Date()
    ) async throws -> TidesData? {
        guard let station = Self.nearestStation(latitude: latitude, longitude: longitude) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        guard let url = Self.predictionsURL(
            station: station.id, from: today, hours: 48, metric: metric
        ) else { return nil }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let events = try Self.parse(data)
        guard !events.isEmpty else {
            logger.warning("No tide predictions for station \(station.id, privacy: .public)")
            return nil
        }
        return TidesData(
            station: station,
            days: Self.group(events, from: today, days: 2, calendar: calendar),
            unit: metric ? "m" : "ft"
        )
    }

    /// The CO-OPS request: highs and lows, in GMT, from midnight local time.
    ///
    /// GMT rather than the station's local time, which is what `lst_ldt` gives: converting is
    /// then the app's own business, in the forecast location's time zone, rather than trusting
    /// the station's offset and daylight rule to match it.
    static func predictionsURL(station: String, from start: Date, hours: Int, metric: Bool) -> URL? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: start)
        let begin = String(
            format: "%04d%02d%02d %02d:%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0
        )
        var components = URLComponents(string: "https://api.tidesandcurrents.noaa.gov/api/prod/datagetter")
        components?.queryItems = [
            .init(name: "product", value: "predictions"),
            .init(name: "application", value: "weatherfeels"),
            .init(name: "begin_date", value: begin),
            .init(name: "range", value: String(hours)),
            .init(name: "datum", value: "MLLW"),
            .init(name: "station", value: station),
            .init(name: "time_zone", value: "gmt"),
            .init(name: "units", value: metric ? "metric" : "english"),
            .init(name: "interval", value: "hilo"),
            .init(name: "format", value: "json"),
        ]
        return components?.url
    }

    private struct PredictionsResponse: Decodable {
        struct Prediction: Decodable {
            let t: String
            let v: String
            let type: String
        }
        let predictions: [Prediction]?
    }

    /// Highs and lows from a CO-OPS response, oldest first.
    static func parse(_ data: Data) throws -> [TideEvent] {
        let response = try JSONDecoder().decode(PredictionsResponse.self, from: data)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return (response.predictions ?? [])
            .compactMap { prediction in
                guard let time = formatter.date(from: prediction.t), let height = Double(prediction.v) else {
                    return nil
                }
                return TideEvent(time: time, height: height, isHigh: prediction.type.uppercased() == "H")
            }
            .sorted { $0.time < $1.time }
    }

    /// Events split into local days, starting from `start`'s day.
    static func group(_ events: [TideEvent], from start: Date, days: Int, calendar: Calendar) -> [TidesData.Day] {
        let names = DateFormatter()
        names.locale = Locale(identifier: "en_US_POSIX")
        names.timeZone = calendar.timeZone
        names.dateFormat = "EEEE"
        return (0..<days).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let inDay = events.filter { calendar.isDate($0.time, inSameDayAs: day) }
            return TidesData.Day(name: names.string(from: day), events: inDay)
        }
    }
}
