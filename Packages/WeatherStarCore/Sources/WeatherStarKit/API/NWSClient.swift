import Foundation
import OSLog

public enum NWSError: Error, LocalizedError, Sendable {
    case invalidURL(String)
    case httpStatus(Int, url: String)
    case decoding(String, underlying: String)
    case noStationsAvailable
    case allStationsExhausted
    case missingGridData

    public var errorDescription: String? {
        switch self {
        case let .invalidURL(url):
            "Invalid URL: \(url)"
        case let .httpStatus(code, url):
            "HTTP \(code) from \(url)"
        case let .decoding(type, underlying):
            "Could not decode \(type): \(underlying)"
        case .noStationsAvailable:
            "No weather stations found near this location"
        case .allStationsExhausted:
            "All nearby weather stations failed to return usable data"
        case .missingGridData:
            "The forecast grid for this location is unavailable"
        }
    }
}

/// Client for api.weather.gov and the auxiliary NOAA hosts the displays need.
///
/// The NWS API requires a descriptive `User-Agent` and rate-limits aggressively, so
/// requests are retried with backoff and responses are cached in a shared
/// `URLCache`. Nothing here is user-identifying — no keys, no analytics.
public actor NWSClient {
    public static let shared = NWSClient()

    public static let apiBase = URL(string: "https://api.weather.gov")!

    private let session: URLSession
    private let decoder: JSONDecoder
    private let logger = Logger(subsystem: "net.weatherstar.kit", category: "NWSClient")

    /// Retry schedule from `utils/fetch.mjs`: short pauses that add up to roughly
    /// a minute before a display gives up and shows its failure state.
    private let retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(5)]
    private let requestTimeout: TimeInterval = 15

    public init(userAgent: String? = nil) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.urlCache = URLCache(
            memoryCapacity: 8 * 1024 * 1024,
            diskCapacity: 64 * 1024 * 1024,
            diskPath: "ws4k-nws"
        )
        configuration.httpAdditionalHeaders = [
            "User-Agent": userAgent ?? Self.defaultUserAgent,
            "Accept": "application/geo+json,application/json;q=0.9,*/*;q=0.8",
        ]
        session = URLSession(configuration: configuration)

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = NWSDate.parse(raw) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Unrecognized date format: \(raw)"
                )
            }
            return date
        }
    }

    /// NWS asks that clients identify themselves with contact information.
    private static var defaultUserAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "weatherfeels/\(version) (https://github.com/netbymatt/ws4kp)"
    }

    // MARK: - Core request

    /// GET and decode, retrying transient failures. `stillWaiting` fires before the
    /// first retry so a display can show its "retrying" state.
    public func get<T: Decodable & Sendable>(
        _ type: T.Type,
        from url: URL,
        query: [String: String] = [:],
        retries: Int = 3,
        stillWaiting: (@Sendable () -> Void)? = nil
    ) async throws -> T {
        let data = try await getData(from: url, query: query, retries: retries, stillWaiting: stillWaiting)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            logger.error("Decode \(String(describing: type)) failed: \(error.localizedDescription)")
            throw NWSError.decoding(String(describing: type), underlying: error.localizedDescription)
        }
    }

    public func getData(
        from url: URL,
        query: [String: String] = [:],
        retries: Int = 3,
        stillWaiting: (@Sendable () -> Void)? = nil
    ) async throws -> Data {
        var resolved = url
        if !query.isEmpty {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
                throw NWSError.invalidURL(url.absoluteString)
            }
            components.queryItems = (components.queryItems ?? [])
                + query.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let built = components.url else {
                throw NWSError.invalidURL(url.absoluteString)
            }
            resolved = built
        }

        var lastError: Error = NWSError.httpStatus(0, url: resolved.absoluteString)

        for attempt in 0...retries {
            if attempt == 1 { stillWaiting?() }
            if attempt > 0 {
                try? await Task.sleep(for: retryDelays[min(attempt - 1, retryDelays.count - 1)])
            }
            try Task.checkCancellation()

            do {
                let (data, response) = try await session.data(from: resolved)
                guard let http = response as? HTTPURLResponse else { return data }

                switch http.statusCode {
                case 200..<300:
                    return data
                case 404, 400:
                    // Permanent for this URL — retrying cannot help.
                    throw NWSError.httpStatus(http.statusCode, url: resolved.absoluteString)
                default:
                    lastError = NWSError.httpStatus(http.statusCode, url: resolved.absoluteString)
                }
            } catch let error as NWSError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }

        logger.warning("Giving up on \(resolved.absoluteString, privacy: .public)")
        throw lastError
    }

    /// Non-throwing variant matching upstream's `safeJson`, for displays that
    /// degrade rather than fail when one source is unavailable.
    public func tryGet<T: Decodable & Sendable>(
        _ type: T.Type,
        from url: URL,
        query: [String: String] = [:],
        retries: Int = 3,
        stillWaiting: (@Sendable () -> Void)? = nil
    ) async -> T? {
        try? await get(type, from: url, query: query, retries: retries, stillWaiting: stillWaiting)
    }

    // MARK: - Endpoints

    public func point(latitude: Double, longitude: Double) async throws -> PointResponse {
        let path = String(format: "points/%.4f,%.4f", latitude, longitude)
        return try await get(PointResponse.self, from: Self.apiBase.appending(path: path))
    }

    /// Observation stations near a point, nearest first, with upstream's filter applied.
    public func stations(for point: PointResponse) async throws -> [StationFeature] {
        guard let urlString = point.properties.observationStations,
              let url = URL(string: urlString)
        else { throw NWSError.noStationsAvailable }

        let collection = try await get(StationCollection.self, from: url)
        let filtered = collection.features.filter(\.passesStationFilter)
        // The API already returns these nearest-first; keep that order but fall back
        // to the unfiltered list if the filter removed everything.
        return filtered.isEmpty ? collection.features : filtered
    }

    /// Recent observations for a station. Five are requested because the displays
    /// backfill missing elements from older reports and derive the pressure trend.
    public func observations(
        stationURL: String,
        limit: Int = 5,
        stillWaiting: (@Sendable () -> Void)? = nil
    ) async throws -> ObservationCollection {
        guard let url = URL(string: stationURL)?.appending(path: "observations") else {
            throw NWSError.invalidURL(stationURL)
        }
        return try await get(
            ObservationCollection.self,
            from: url,
            query: ["limit": String(limit)],
            stillWaiting: stillWaiting
        )
    }

    /// Forecast for a URL from the points response.
    ///
    /// `units` is passed through to the API, which honours it for the numeric fields
    /// *and* for the narrative text. Requesting the user's own system is what keeps
    /// "High near 88" from reading "High near 31" next to a Fahrenheit display.
    public func forecast(
        _ urlString: String,
        units: UnitSystem,
        stillWaiting: (@Sendable () -> Void)? = nil
    ) async throws -> ForecastResponse {
        guard let url = URL(string: urlString) else { throw NWSError.invalidURL(urlString) }
        return try await get(
            ForecastResponse.self,
            from: url,
            query: ["units": units.rawValue],
            stillWaiting: stillWaiting
        )
    }

    public func activeAlerts(latitude: Double, longitude: Double) async throws -> AlertCollection {
        try await get(
            AlertCollection.self,
            from: Self.apiBase.appending(path: "alerts/active"),
            query: ["point": String(format: "%.4f,%.4f", latitude, longitude)]
        )
    }

    /// Forecast for an arbitrary grid point, used by the travel and regional displays.
    public func forecastForGrid(
        office: String,
        x: Int,
        y: Int,
        hourly: Bool = false,
        units: UnitSystem
    ) async throws -> ForecastResponse {
        let path = "gridpoints/\(office)/\(x),\(y)/forecast" + (hourly ? "/hourly" : "")
        return try await get(
            ForecastResponse.self,
            from: Self.apiBase.appending(path: path),
            query: ["units": units.rawValue]
        )
    }
}

/// Lenient parser for the date shapes NWS returns across its endpoints.
enum NWSDate {
    // Formatters are configured once at init and only ever read afterwards.
    // Parsing an immutable Foundation formatter is thread-safe, so sharing these
    // avoids rebuilding a formatter for every date in a large forecast payload.
    nonisolated(unsafe) private static let withFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Some endpoints (notably alert timestamps) omit the colon in the zone offset.
    private static let fallback: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        return formatter
    }()

    static func parse(_ raw: String) -> Date? {
        withFractional.date(from: raw)
            ?? plain.date(from: raw)
            ?? fallback.date(from: raw)
    }
}
