import CoreGraphics
import Foundation
import ImageIO
import OSLog

/// A box in Web Mercator (EPSG:3857), in metres.
public struct MercatorBox: Equatable, Sendable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    /// Half the width of the Web Mercator world, in metres.
    public static let extent = 20_037_508.342789244
}

/// Radar images for the zoomable radar map.
///
/// One image per frame for whatever part of the map is in view, from IEM's time-enabled WMS
/// for the `n0q` composite — the same source and the same request pattern as the WeatherStar
/// "Local Radar", only in Web Mercator to lie on Apple's map.
///
/// The map started out on NOAA nowCOAST, drawing its mosaic as map tiles. Preloading a
/// twelve-frame loop as tiles is a couple of hundred requests in a few seconds, and nowCOAST's
/// CloudFront front end answered the second session with `403 Request blocked` for every
/// request from that address, capabilities included. A phone on a carrier's shared address
/// could lose the map that way for somebody else's use of it. One image per frame per settled
/// view is a dozen requests, which is what a WMS is built for; IEM serves the `n0q` composite
/// without a published limit, and this keeps the load on it to the size the WeatherStar
/// display already puts there. The cost is coverage: `n0q` is the lower 48 only.
public actor RadarMapSource {
    public static let shared = RadarMapSource()

    private let logger = Logger(subsystem: "net.weatherstar.kit", category: "RadarMap")
    private let session: URLSession

    private static let host = "mesonet.agron.iastate.edu"
    /// The composite is made every five minutes.
    public static let frameStep: TimeInterval = 300

    /// Where `n0q` has data — the lower 48 — in Web Mercator, from IEM's world file
    /// (126°W to 65°W, 23°N to 50°N).
    public static let coverage = MercatorBox(
        minX: mercatorX(longitude: -126), minY: mercatorY(latitude: 23),
        maxX: mercatorX(longitude: -65), maxY: mercatorY(latitude: 50)
    )

    /// Whether any of a box has radar to show. Outside it the server answers with a clear
    /// image, which would read as clear skies rather than as no radar.
    public static func covers(_ box: MercatorBox) -> Bool {
        box.minX < coverage.maxX && box.maxX > coverage.minX
            && box.minY < coverage.maxY && box.maxY > coverage.minY
    }

    static func mercatorX(longitude: Double) -> Double {
        longitude * MercatorBox.extent / 180
    }

    static func mercatorY(latitude: Double) -> Double {
        log(tan((90 + latitude) * .pi / 360)) * MercatorBox.extent / .pi
    }

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.httpAdditionalHeaders = ["User-Agent": NWSClient.defaultUserAgent]
        self.session = URLSession(configuration: configuration)
    }

    /// The most recent `count` frame times, oldest first, five minutes apart.
    ///
    /// The newest comes from the metadata IEM publishes beside the composite. Without it, the
    /// last five-minute mark at least ten minutes old — about how far behind the composite
    /// runs — so a metadata hiccup costs at most the newest frame.
    public func frameTimes(count: Int) async -> [Date] {
        let newest = await newestFrameTime()
        return (0..<count).map {
            newest.addingTimeInterval(-Double(count - 1 - $0) * Self.frameStep)
        }
    }

    private func newestFrameTime() async -> Date {
        let fallback = Self.roundedDown(Date().addingTimeInterval(-600))
        guard let url = URL(string: "https://\(Self.host)/data/gis/images/4326/USCOMP/n0q_0.json"),
              let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let metadata = try? JSONDecoder().decode(CompositeMetadata.self, from: data),
              let valid = ISO8601DateFormatter().date(from: metadata.meta.valid)
        else {
            logger.warning("Radar metadata unavailable; assuming the composite is ten minutes behind")
            return fallback
        }
        return valid
    }

    private struct CompositeMetadata: Decodable {
        struct Meta: Decodable { let valid: String }
        let meta: Meta
    }

    static func roundedDown(_ date: Date) -> Date {
        let seconds = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: seconds - seconds.truncatingRemainder(dividingBy: frameStep))
    }

    /// One frame for a box, `width` by `height` pixels, or `nil` if it could not be had.
    public func image(box: MercatorBox, width: Int, height: Int, time: Date) async -> CGImage? {
        guard let url = Self.imageURL(box: box, width: width, height: height, time: time),
              let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            logger.warning("Radar map frame unavailable for \(time, privacy: .public)")
            return nil
        }
        return image
    }

    /// The WMS request for one frame of a box.
    public static func imageURL(box: MercatorBox, width: Int, height: Int, time: Date) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/cgi-bin/wms/nexrad/n0q-t.cgi"
        let bbox = [box.minX, box.minY, box.maxX, box.maxY]
            .map { String(format: "%.1f", $0) }
            .joined(separator: ",")
        components.queryItems = [
            .init(name: "SERVICE", value: "WMS"),
            .init(name: "VERSION", value: "1.1.1"),
            .init(name: "REQUEST", value: "GetMap"),
            .init(name: "LAYERS", value: "nexrad-n0q-wmst"),
            .init(name: "STYLES", value: ""),
            .init(name: "SRS", value: "EPSG:3857"),
            .init(name: "BBOX", value: bbox),
            .init(name: "WIDTH", value: String(max(width, 1))),
            .init(name: "HEIGHT", value: String(max(height, 1))),
            .init(name: "FORMAT", value: "image/png"),
            .init(name: "TRANSPARENT", value: "true"),
            .init(name: "TIME", value: ISO8601DateFormatter().string(from: time)),
        ]
        return components.url
    }
}
