import CoreGraphics
import Foundation
import ImageIO
import OSLog

/// Fetches the radar loop around a location.
///
/// Source is the Iowa Environmental Mesonet's `n0q` NEXRAD reflectivity composite, asked for
/// through IEM's time-enabled WMS: one small image per frame, already cut to the window around
/// the location. Each frame is recoloured from reflectivity to the WeatherStar palette.
///
/// This replaced a port of ws4kp's approach, which was wrong in a way that took a while to
/// see. ws4kp downloads the whole national `n0r` composite and finds the location on it with
/// hand-tuned constants — an anchor at 51°N 129.138°W. IEM's own world file for that image puts
/// its corner at 50°N 126°W. ws4kp's odd `RADAR_OFFSET` happened to cancel most of the error;
/// centring the window, a deliberate fix here, removed the cancellation, and from then on the
/// radar was cut from somewhere about 290 km east-south-east of the user and drawn over a base
/// map centred on them. The base map came from the same constants, so the two agreed with each
/// other, and the tests, which checked the projection against itself, passed. The image was also
/// point-sampled down to 2550 pixels wide before cropping, keeping about one pixel in four, so
/// small cells simply vanished.
///
/// Asking the server for a box removes both problems: there is no projection to get wrong and
/// nothing to resample. `n0q` is also the better product — 8-bit, half-dBZ reflectivity at about
/// half a kilometre. `n0r`, 4-bit in 5 dBZ steps, has only been a copy derived from it since
/// the NWS stopped sending N0R in 2021.
public actor RadarService {
    public static let shared = RadarService()

    private let logger = Logger(subsystem: "net.weatherstar.kit", category: "Radar")
    private let session: URLSession

    private static let host = "mesonet.agron.iastate.edu"

    /// Size of each frame in pixels, and the shape of the window on the ground.
    ///
    /// The wide canvas's full width, so one set of frames serves both canvases: the standard
    /// canvas shows the middle 640 points of it, at the same scale, with the location still in
    /// the centre.
    public static let imageSize = CGSize(width: 854, height: 367)

    /// How much ground the full window spans east to west.
    ///
    /// The standard canvas's 640-point view of it is about 560 km across — close to the area
    /// ws4kp's window covered, so "Local Radar" still means a region rather than a county.
    static let windowWidthKilometres: Double = 750

    /// Where the composite has data: the lower 48 only.
    ///
    /// From IEM's world file — the image runs from 126°W to 65°W and 23°N to 50°N. Outside it
    /// there is no radar to show, so rather than drawing an empty window the display drops out
    /// of the rotation, the way any display with no data does.
    static let coverage = (minLatitude: 23.0, maxLatitude: 50.0, minLongitude: -126.0, maxLongitude: -65.0)

    /// Number of frames the animation cycles.
    public static let frameCount = 6
    /// The composite is made every five minutes.
    static let frameStep: TimeInterval = 300

    private static let kilometresPerDegreeLatitude = 111.32

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        // IEM asks that automated clients identify themselves, as the NWS does.
        configuration.httpAdditionalHeaders = ["User-Agent": NWSClient.defaultUserAgent]
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Geometry

    /// Geographic bounds of the radar window for a location, with the location at its centre.
    ///
    /// The east-west span is widened by `1 / cos(latitude)`: a degree of longitude shrinks
    /// towards the pole, so a fixed span in degrees would show a wider area of Minnesota than of
    /// Florida, and stretch it. The radar display and its base map are both drawn from these
    /// bounds, so the two layers stay registered.
    public static func bounds(
        latitude: Double,
        longitude: Double
    ) -> (minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double) {
        let heightKilometres = windowWidthKilometres * imageSize.height / imageSize.width
        let halfHeight = heightKilometres / 2 / kilometresPerDegreeLatitude
        let kilometresPerDegreeLongitude = kilometresPerDegreeLatitude
            * max(cos(latitude * .pi / 180), 0.1)
        let halfWidth = windowWidthKilometres / 2 / kilometresPerDegreeLongitude
        return (
            minLatitude: latitude - halfHeight,
            maxLatitude: latitude + halfHeight,
            minLongitude: longitude - halfWidth,
            maxLongitude: longitude + halfWidth
        )
    }

    /// Whether the composite covers a location at all.
    public static func covers(latitude: Double, longitude: Double) -> Bool {
        (coverage.minLatitude...coverage.maxLatitude).contains(latitude)
            && (coverage.minLongitude...coverage.maxLongitude).contains(longitude)
    }

    // MARK: - Fetching

    /// The most recent frames for a location, oldest first.
    ///
    /// Empty outside the composite's coverage. A frame the server has nothing for — a time it
    /// has not made yet, or an outage, both of which come back as a blank image rather than an
    /// error — is left out, so the loop never pauses on an empty step.
    public func frames(latitude: Double, longitude: Double) async throws -> [RadarFrame] {
        guard Self.covers(latitude: latitude, longitude: longitude) else { return [] }

        let newest = await newestFrameTime()
        let times = (0..<Self.frameCount).map {
            newest.addingTimeInterval(-Double(Self.frameCount - 1 - $0) * Self.frameStep)
        }
        let bounds = Self.bounds(latitude: latitude, longitude: longitude)

        var processed: [Date: CGImage] = [:]
        await withTaskGroup(of: (Date, CGImage?).self) { group in
            for time in times {
                guard let url = Self.frameURL(bounds: bounds, time: time) else { continue }
                group.addTask {
                    (time, await self.processFrame(url: url))
                }
            }
            for await (time, image) in group {
                if let image { processed[time] = image }
            }
        }

        return processed
            .sorted { $0.key < $1.key }
            .map { RadarFrame(timestamp: $0.key, image: $0.value) }
    }

    /// The time of the newest composite, from the metadata IEM publishes beside it.
    ///
    /// Falls back to the last five-minute mark at least ten minutes old — about how far behind
    /// the composite usually runs — so a metadata hiccup costs at most the newest frame.
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

    /// A WMS request for one frame of the window.
    static func frameURL(
        bounds: (minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double),
        time: Date
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/cgi-bin/wms/nexrad/n0q-t.cgi"
        let box = [bounds.minLongitude, bounds.minLatitude, bounds.maxLongitude, bounds.maxLatitude]
            .map { String(format: "%.4f", $0) }
            .joined(separator: ",")
        let stamp = ISO8601DateFormatter().string(from: time)
        components.queryItems = [
            .init(name: "SERVICE", value: "WMS"),
            .init(name: "VERSION", value: "1.1.1"),
            .init(name: "REQUEST", value: "GetMap"),
            .init(name: "LAYERS", value: "nexrad-n0q-wmst"),
            .init(name: "STYLES", value: ""),
            .init(name: "SRS", value: "EPSG:4326"),
            .init(name: "BBOX", value: box),
            .init(name: "WIDTH", value: String(Int(imageSize.width))),
            .init(name: "HEIGHT", value: String(Int(imageSize.height))),
            .init(name: "FORMAT", value: "image/png"),
            .init(name: "TRANSPARENT", value: "true"),
            .init(name: "TIME", value: stamp),
        ]
        return components.url
    }

    // MARK: - Processing

    /// Download one frame and recolour it, or `nil` if there is nothing in it to show.
    private func processFrame(url: URL) async -> CGImage? {
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            logger.warning("Radar frame unavailable: \(url.absoluteString, privacy: .public)")
            return nil
        }
        return Self.recolour(image)
    }

    /// Map IEM's reflectivity colours onto the WeatherStar's muted palette.
    ///
    /// Returns `nil` for a frame with no echoes in it at all. A clear sky over the whole
    /// window does happen, but every pixel being empty is far more often the server answering a
    /// time it has no composite for — which it does with a blank image, not an error.
    static func recolour(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }

        var echoes = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let mapped: (UInt8, UInt8, UInt8, UInt8)
            if pixels[index + 3] == 0 {
                mapped = (0, 0, 0, 0)
            } else {
                let colour = UInt32(pixels[index]) << 16
                    | UInt32(pixels[index + 1]) << 8
                    | UInt32(pixels[index + 2])
                mapped = NEXRADPalette.reflectivity[colour].map { weatherStarColour(dBZ: $0) }
                    ?? (0, 0, 0, 0)
            }
            if mapped.3 > 0 { echoes += 1 }
            pixels[index] = mapped.0
            pixels[index + 1] = mapped.1
            pixels[index + 2] = mapped.2
            pixels[index + 3] = mapped.3
        }
        guard echoes > 0 else { return nil }

        return pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
    }

    /// The WeatherStar colour for a reflectivity.
    ///
    /// The same eight colours ws4kp maps the NWS's 5 dBZ bands to, now keyed by the value
    /// itself. Below 20 dBZ is clear: those returns are mostly drizzle too light to matter,
    /// ground clutter and birds, and the original hardware never drew them either.
    public static func weatherStarColour(dBZ: Double) -> (UInt8, UInt8, UInt8, UInt8) {
        switch dBZ {
        case ..<20: (0, 0, 0, 0)
        case ..<25: (49, 210, 22, 255)
        case ..<30: (0, 142, 0, 255)
        case ..<35: (20, 90, 15, 255)
        case ..<40: (10, 40, 10, 255)
        case ..<45: (196, 179, 70, 255)
        case ..<50: (190, 72, 19, 255)
        case ..<60: (171, 14, 14, 255)
        default: (115, 31, 4, 255)
        }
    }
}
