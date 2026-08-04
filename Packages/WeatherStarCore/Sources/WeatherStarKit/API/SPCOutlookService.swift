import Foundation
import OSLog

/// Fetches the Storm Prediction Center's convective outlooks and reports the risk
/// category covering a point.
///
/// Source is SPC's own GeoJSON products, the same ones ws4kp reads. The point-in-
/// polygon test happens locally, so nothing about the user's location is sent
/// anywhere beyond the plain file request.
public actor SPCOutlookService {
    public static let shared = SPCOutlookService()

    private let logger = Logger(subsystem: "net.weatherstar.kit", category: "SPCOutlook")
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Categorical outlook for days 1 through 3.
    private func url(day: Int) -> URL? {
        URL(string: "https://www.spc.noaa.gov/products/outlook/day\(day)otlk_cat.nolyr.geojson")
    }

    /// SPC labels categories by a short code; these are the display names.
    private static let categoryNames: [String: String] = [
        "TSTM": "General Thunderstorms",
        "MRGL": "Marginal Risk",
        "SLGT": "Slight Risk",
        "ENH": "Enhanced Risk",
        "MDT": "Moderate Risk",
        "HIGH": "High Risk",
    ]

    /// Ordering so the most severe overlapping polygon wins.
    private static let severity = ["TSTM", "MRGL", "SLGT", "ENH", "MDT", "HIGH"]

    /// Highest-severity outlook covering the point, checking days 1–3 in order.
    /// Returns nil when no outlook covers it, which is the common case.
    public func outlook(latitude: Double, longitude: Double) async -> SPCOutlookData? {
        for day in 1...3 {
            guard let url = url(day: day) else { continue }
            guard let collection = await fetch(url) else { continue }

            var best: (code: String, rank: Int)?
            for feature in collection.features {
                guard let code = feature.properties.label ?? feature.properties.dn.map(String.init)
                else { continue }
                guard let rings = feature.geometry?.polygons else { continue }
                guard Self.contains(
                    latitude: latitude,
                    longitude: longitude,
                    rings: rings
                ) else { continue }

                let rank = Self.severity.firstIndex(of: code) ?? -1
                if best == nil || rank > best!.rank {
                    best = (code, rank)
                }
            }

            if let best {
                return SPCOutlookData(
                    risk: Self.categoryNames[best.code] ?? best.code,
                    day: day,
                    validText: "Day \(day) Convective Outlook"
                )
            }
        }

        return nil
    }

    private func fetch(_ url: URL) async -> OutlookCollection? {
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else { return nil }
            return try JSONDecoder().decode(OutlookCollection.self, from: data)
        } catch {
            logger.warning("SPC outlook fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    private struct OutlookCollection: Decodable {
        var features: [OutlookFeature]
    }

    private struct OutlookFeature: Decodable {
        var geometry: NWSGeometry?
        var properties: Properties

        struct Properties: Decodable {
            /// SPC uses `LABEL` for the category code.
            var label: String?
            /// Older products carry a numeric `DN` instead.
            var dn: Int?

            private enum CodingKeys: String, CodingKey {
                case label = "LABEL"
                case dn = "DN"
            }
        }
    }

    /// Ray-casting point-in-polygon over a set of rings.
    ///
    /// SPC outlook shapes are given as polygons whose first ring is the outer
    /// boundary and any later rings are holes, so an odd number of containing rings
    /// means the point is inside.
    static func contains(
        latitude: Double,
        longitude: Double,
        rings: [[(longitude: Double, latitude: Double)]]
    ) -> Bool {
        var inside = false
        for ring in rings where isInside(latitude: latitude, longitude: longitude, ring: ring) {
            inside.toggle()
        }
        return inside
    }

    private static func isInside(
        latitude: Double,
        longitude: Double,
        ring: [(longitude: Double, latitude: Double)]
    ) -> Bool {
        guard ring.count > 2 else { return false }
        var inside = false
        var j = ring.count - 1

        for i in ring.indices {
            let a = ring[i]
            let b = ring[j]
            // Count crossings of a horizontal ray extending from the point.
            if (a.latitude > latitude) != (b.latitude > latitude) {
                let slope = (b.longitude - a.longitude) / (b.latitude - a.latitude)
                let crossing = a.longitude + (latitude - a.latitude) * slope
                if longitude < crossing { inside.toggle() }
            }
            j = i
        }

        return inside
    }
}
