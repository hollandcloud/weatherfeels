import CoreGraphics
import Foundation
import ImageIO
import OSLog

/// Fetches and processes the national radar composite.
///
/// Source is the Iowa Environmental Mesonet's NEXRAD base-reflectivity composite,
/// the same archive ws4kp uses. Each frame is cropped to the area around the
/// location, recoloured to the WeatherStar palette, then scaled up with
/// nearest-neighbour so it keeps the blocky look of the original hardware.
public actor RadarService {
    public static let shared = RadarService()

    private let logger = Logger(subsystem: "net.weatherstar.kit", category: "Radar")
    private let session: URLSession

    private static let host = "mesonet.agron.iastate.edu"

    /// The composite is resampled to this size before cropping, matching upstream's
    /// `RADAR_FULL_SIZE` so the projection constants below stay valid.
    private static let fullSize = CGSize(width: 2550, height: 1600)
    /// Crop taken around the location, in full-size pixels.
    private static let sourceSize = CGSize(width: 240, height: 163)

    /// Where the location sits inside that crop — the middle.
    ///
    /// Upstream uses a literal `{x: 240, y: 138}` here (`RADAR_OFFSET` in
    /// `radar-constants.mjs`; its `* 2` in `getXYFromLatitudeLongitudeDoppler` is undone
    /// by the `/ 2` in `radar-processor.mjs`, so it is applied at this scale). Against a
    /// 240×163 crop that puts the location at 100% across and 85% down — the very
    /// bottom-right corner — so the window actually shows the area north-west of you.
    /// Upstream centres its *base map* (`- TILE_SIZE.y / 2` in
    /// `getXYFromLatitudeLongitudeMap`) but never the radar window.
    ///
    /// Half the crop puts the location in the middle, which is what "Local Radar" should
    /// mean. This is a deliberate divergence from upstream.
    private static let sourceOffset = CGPoint(
        x: sourceSize.width / 2,
        y: sourceSize.height / 2
    )
    /// Size the crop is stretched to for display.
    private static let finalSize = CGSize(width: 640, height: 367)

    /// Linear projection of the composite, from `radar-utils.mjs`.
    private static let anchorLatitude: Double = 51
    private static let anchorLongitude: Double = -129.138
    private static let pixelsPerDegreeLatitude: Double = 61.4481
    private static let pixelsPerDegreeLongitude: Double = 42.1768

    /// Number of frames the animation cycles.
    public static let frameCount = 6

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Geographic bounds of the crop for a location. The radar display uses these to
    /// crop the base map to exactly the same window, so the two layers line up.
    public static func bounds(
        latitude: Double,
        longitude: Double
    ) -> (minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double) {
        let origin = cropOrigin(latitude: latitude, longitude: longitude)
        return (
            minLatitude: anchorLatitude - (origin.y + sourceSize.height) / pixelsPerDegreeLatitude,
            maxLatitude: anchorLatitude - origin.y / pixelsPerDegreeLatitude,
            minLongitude: origin.x / pixelsPerDegreeLongitude + anchorLongitude,
            maxLongitude: (origin.x + sourceSize.width) / pixelsPerDegreeLongitude + anchorLongitude
        )
    }

    /// Top-left corner of the crop, clamped inside the composite.
    private static func cropOrigin(latitude: Double, longitude: Double) -> CGPoint {
        let x = (longitude - anchorLongitude) * pixelsPerDegreeLongitude - sourceOffset.x
        let y = (anchorLatitude - latitude) * pixelsPerDegreeLatitude - sourceOffset.y
        return CGPoint(
            x: Calc.coerce(0, x, fullSize.width - sourceSize.width),
            y: Calc.coerce(0, y, fullSize.height - sourceSize.height)
        )
    }

    // MARK: - Fetching

    /// The most recent frames for a location, oldest first.
    public func frames(latitude: Double, longitude: Double) async throws -> [RadarFrame] {
        let urls = try await recentFrameURLs()
        guard !urls.isEmpty else { return [] }

        let origin = Self.cropOrigin(latitude: latitude, longitude: longitude)

        // Process concurrently, then restore chronological order.
        var processed: [Date: CGImage] = [:]
        await withTaskGroup(of: (Date, CGImage?).self) { group in
            for (timestamp, url) in urls {
                group.addTask {
                    (timestamp, await self.processFrame(url: url, cropOrigin: origin))
                }
            }
            for await (timestamp, image) in group {
                if let image { processed[timestamp] = image }
            }
        }

        return processed
            .sorted { $0.key < $1.key }
            .map { RadarFrame(timestamp: $0.key, image: $0.value) }
    }

    /// Scrape the archive index for the newest composite PNGs.
    ///
    /// Frames roll over at UTC midnight, so when today's index has fewer than the
    /// frame count, yesterday's is consulted too.
    private func recentFrameURLs() async throws -> [(Date, URL)] {
        var collected: [(Date, URL)] = []
        let now = Date()

        for dayOffset in 0...1 {
            guard let day = Calendar(identifier: .gregorian).date(
                byAdding: .day, value: -dayOffset, to: now
            ) else { continue }

            let listed = try? await frameURLs(for: day)
            collected.append(contentsOf: listed ?? [])
            if collected.count >= Self.frameCount { break }
        }

        return collected
            .sorted { $0.0 < $1.0 }
            .suffix(Self.frameCount)
    }

    private func frameURLs(for day: Date) async throws -> [(Date, URL)] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.year, .month, .day], from: day)
        guard let year = components.year,
              let month = components.month,
              let dayOfMonth = components.day
        else { return [] }

        let path = String(
            format: "https://%@/archive/data/%04d/%02d/%02d/GIS/uscomp/?F=0&P=n0r*.png",
            Self.host, year, month, dayOfMonth
        )
        guard let indexURL = URL(string: path) else { return [] }

        let (data, response) = try await session.data(from: indexURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8)
        else { return [] }

        // Filenames encode the observation time: n0r_YYYYMMDDHHMM.png
        var results: [(Date, URL)] = []
        for match in html.matches(of: /n0r_(?<stamp>\d{12})\.png/) {
            let stamp = String(match.output.stamp)
            guard let timestamp = Self.parseStamp(stamp),
                  let url = URL(string: "n0r_\(stamp).png", relativeTo: indexURL)?.absoluteURL
            else { continue }
            results.append((timestamp, url))
        }
        return results
    }

    private static func parseStamp(_ stamp: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmm"
        return formatter.date(from: stamp)
    }

    // MARK: - Processing

    /// Download one composite, crop it, recolour it and scale it up.
    private func processFrame(url: URL, cropOrigin: CGPoint) async -> CGImage? {
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            logger.warning("Radar frame unavailable: \(url.lastPathComponent, privacy: .public)")
            return nil
        }

        // Normalise to the reference size the projection constants assume.
        guard let normalised = Self.redraw(image, to: Self.fullSize),
              let cropped = normalised.cropping(
                  to: CGRect(origin: cropOrigin, size: Self.sourceSize)
              )
        else { return nil }

        guard let recoloured = Self.recolour(cropped) else { return nil }
        return Self.redraw(recoloured, to: Self.finalSize, interpolation: .none)
    }

    /// Draw an image at a different size, controlling interpolation.
    private static func redraw(
        _ image: CGImage,
        to size: CGSize,
        interpolation: CGInterpolationQuality = .none
    ) -> CGImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = interpolation
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return context.makeImage()
    }

    /// Map the NWS radar palette onto the WeatherStar's muted one, and drop the
    /// background and lowest returns to transparent.
    ///
    /// Ported from `removeDopplerRadarImageNoise` in `radar-utils.mjs`. Working on
    /// raw bytes rather than per-pixel Core Graphics calls keeps this fast enough to
    /// run on six frames at once.
    private static func recolour(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        guard let context = pixels.withUnsafeMutableBytes({ buffer in
            CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }) else { return nil }

        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Re-read: the draw above wrote through the buffer pointer.
        pixels = [UInt8](
            UnsafeBufferPointer(
                start: context.data!.assumingMemoryBound(to: UInt8.self),
                count: width * height * 4
            )
        )

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let rgb = (pixels[index], pixels[index + 1], pixels[index + 2])
            let mapped = palette(for: rgb)
            pixels[index] = mapped.0
            pixels[index + 1] = mapped.1
            pixels[index + 2] = mapped.2
            pixels[index + 3] = mapped.3
        }

        return pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let output = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return output.makeImage()
        }
    }

    /// The source-to-display colour table, including the values that become
    /// transparent (background, and the lowest two reflectivity bins).
    private static func palette(
        for rgb: (UInt8, UInt8, UInt8)
    ) -> (UInt8, UInt8, UInt8, UInt8) {
        switch rgb {
        case (0, 0, 0), (0, 236, 236), (1, 160, 246), (0, 0, 246):
            (0, 0, 0, 0)
        case (0, 255, 0):
            (49, 210, 22, 255)
        case (0, 200, 0):
            (0, 142, 0, 255)
        case (0, 144, 0):
            (20, 90, 15, 255)
        case (255, 255, 0):
            (10, 40, 10, 255)
        case (231, 192, 0):
            (196, 179, 70, 255)
        case (255, 144, 0):
            (190, 72, 19, 255)
        case (214, 0, 0), (255, 0, 0):
            (171, 14, 14, 255)
        case (192, 0, 0), (255, 0, 255):
            (115, 31, 4, 255)
        default:
            // Anything unrecognised is treated as background.
            (0, 0, 0, 0)
        }
    }
}
