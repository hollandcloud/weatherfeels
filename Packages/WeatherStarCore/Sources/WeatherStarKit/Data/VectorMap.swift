import CoreGraphics
import Foundation
import WeatherStarResources

/// The radar display's base map — coastlines, lakes and borders — as vectors.
///
/// Built from Natural Earth by `Tools/MakeRadarMap.py`, which documents the file format. It
/// replaced a crop of a 2550×1600 raster of the whole country, blown up about three times and
/// placed with hand-tuned constants. As vectors the map is sharp at any size, and it is drawn
/// in exactly the coordinates the radar frames are requested in, so the two layers register by
/// construction rather than by calibration.
public struct VectorMap: Sendable {
    public enum Layer: UInt8, Sendable, CaseIterable {
        /// Closed rings, filled. Includes the coast.
        case land = 0
        /// Closed rings, filled as water over the land.
        case lakes = 1
        /// Open lines between countries.
        case borders = 2
        /// Open lines between states and provinces.
        case states = 3
    }

    /// One ring or line, in degrees: `x` is longitude, `y` latitude.
    public struct Path: Sendable {
        public let points: [CGPoint]
        /// Bounding box, in degrees, so whole paths outside a window can be skipped.
        public let bounds: CGRect
    }

    public let layers: [Layer: [Path]]

    /// The map bundled with the app, decoded once.
    public static let bundled: VectorMap? = WeatherStarResources.url("radarmap.bin", in: .maps)
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap(decode)

    private static let magic = Data("WSMAP\u{01}".utf8)

    public static func decode(_ data: Data) -> VectorMap? {
        var reader = Reader(data: data)
        guard reader.take(magic.count) == magic,
              let originLongitude = reader.float(),
              let originLatitude = reader.float(),
              let step = reader.float(),
              let layerCount = reader.byte()
        else { return nil }

        var layers: [Layer: [Path]] = [:]
        for _ in 0..<layerCount {
            guard let raw = reader.byte(), let pathCount = reader.uint32() else { return nil }
            var paths: [Path] = []
            paths.reserveCapacity(Int(pathCount))
            for _ in 0..<pathCount {
                guard let pointCount = reader.uint32() else { return nil }
                var points: [CGPoint] = []
                points.reserveCapacity(Int(pointCount))
                var minX = Double.infinity, minY = Double.infinity
                var maxX = -Double.infinity, maxY = -Double.infinity
                for _ in 0..<pointCount {
                    guard let x = reader.uint16(), let y = reader.uint16() else { return nil }
                    let longitude = Double(originLongitude) + Double(x) * Double(step)
                    let latitude = Double(originLatitude) + Double(y) * Double(step)
                    points.append(CGPoint(x: longitude, y: latitude))
                    minX = min(minX, longitude); maxX = max(maxX, longitude)
                    minY = min(minY, latitude); maxY = max(maxY, latitude)
                }
                paths.append(Path(
                    points: points,
                    bounds: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                ))
            }
            // An unknown kind from a newer map is skipped rather than failing the whole file.
            if let layer = Layer(rawValue: raw) {
                layers[layer] = paths
            }
        }
        return VectorMap(layers: layers)
    }

    /// Little-endian reads over the file, failing softly at the end of the data.
    private struct Reader {
        let data: Data
        var offset = 0

        mutating func take(_ count: Int) -> Data? {
            guard offset + count <= data.count else { return nil }
            defer { offset += count }
            return data.subdata(in: data.startIndex + offset..<data.startIndex + offset + count)
        }

        mutating func byte() -> UInt8? { take(1)?.first }

        mutating func uint16() -> UInt16? {
            take(2).map { UInt16($0[$0.startIndex]) | UInt16($0[$0.startIndex + 1]) << 8 }
        }

        mutating func uint32() -> UInt32? {
            take(4).map { bytes in
                (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[bytes.startIndex + $1]) << (8 * $1) }
            }
        }

        mutating func float() -> Float? {
            uint32().map { Float(bitPattern: $0) }
        }
    }
}
