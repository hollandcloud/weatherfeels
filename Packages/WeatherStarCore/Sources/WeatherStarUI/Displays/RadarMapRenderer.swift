import CoreGraphics
import WeatherStarKit

/// Draws the radar's base map for one window into an image.
///
/// The colours are the ones measured off the raster map this replaced — the grey land, the
/// blue water and black ink of ws4kp's base map — so the display looks the same, only sharp.
///
/// Rendered once per location and screen density rather than drawn live in a `Canvas`: the
/// radar display redraws on every frame of its animation, and a map that never changes has
/// no business being re-stroked forty thousand points at a time.
enum RadarMapRenderer {
    static let water = CGColor(srgbRed: 0x2F / 255.0, green: 0x60 / 255.0, blue: 0xA9 / 255.0, alpha: 1)
    static let land = CGColor(srgbRed: 0x7E / 255.0, green: 0x7E / 255.0, blue: 0x7E / 255.0, alpha: 1)
    static let ink = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

    /// Line weights in design points, so they keep their heft at any resolution.
    private enum Weight {
        static let coast: CGFloat = 1.1
        static let lakes: CGFloat = 0.9
        static let borders: CGFloat = 1.6
        static let states: CGFloat = 0.8
    }

    /// The map for a window, `size` design points at `pixelsPerPoint`.
    ///
    /// North is up and the projection is the same linear longitude-and-latitude one the radar
    /// frames are requested in, so a point on the map and the echo over it are the same place.
    static func image(
        map: VectorMap? = .bundled,
        bounds: (minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double),
        size: CGSize,
        pixelsPerPoint: CGFloat
    ) -> CGImage? {
        guard let map else { return nil }
        let width = max(1, Int((size.width * pixelsPerPoint).rounded()))
        let height = max(1, Int((size.height * pixelsPerPoint).rounded()))
        guard let colourSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: colourSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        let window = CGRect(
            x: bounds.minLongitude,
            y: bounds.minLatitude,
            width: bounds.maxLongitude - bounds.minLongitude,
            height: bounds.maxLatitude - bounds.minLatitude
        )
        guard window.width > 0, window.height > 0 else { return nil }
        // A bitmap context's origin is bottom-left, so latitude needs no flip to put north up.
        let scaleX = CGFloat(width) / window.width
        let scaleY = CGFloat(height) / window.height
        let culling = window.insetBy(dx: -0.5, dy: -0.5)

        func path(_ layer: VectorMap.Layer, closed: Bool) -> CGPath {
            let path = CGMutablePath()
            for item in map.layers[layer] ?? [] {
                // Lines can have a zero-width box, which never intersects anything.
                guard item.bounds.insetBy(dx: -0.01, dy: -0.01).intersects(culling) else { continue }
                let points = item.points.map {
                    CGPoint(x: ($0.x - window.minX) * scaleX, y: ($0.y - window.minY) * scaleY)
                }
                path.addLines(between: points)
                if closed { path.closeSubpath() }
            }
            return path
        }

        context.setFillColor(water)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setLineJoin(.round)
        context.setLineCap(.round)

        let land = path(.land, closed: true)
        context.addPath(land)
        context.setFillColor(self.land)
        context.fillPath(using: .evenOdd)

        let lakes = path(.lakes, closed: true)
        context.addPath(lakes)
        context.setFillColor(water)
        context.fillPath(using: .evenOdd)

        context.setStrokeColor(ink)
        for (layer, weight, closed) in [
            (VectorMap.Layer.states, Weight.states, false),
            (.lakes, Weight.lakes, true),
            (.land, Weight.coast, true),
            (.borders, Weight.borders, false),
        ] {
            context.addPath(layer == .land ? land : layer == .lakes ? lakes : path(layer, closed: closed))
            context.setLineWidth(weight * pixelsPerPoint)
            context.strokePath()
        }

        return context.makeImage()
    }
}
