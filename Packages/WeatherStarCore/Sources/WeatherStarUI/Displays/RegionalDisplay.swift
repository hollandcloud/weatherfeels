import SwiftUI
import WeatherStarKit
import WeatherStarResources

/// Projection between latitude/longitude and the bundled 2550×1600 base map.
///
/// Upstream's map is a simple equirectangular image, so the mapping is linear.
/// Constants are taken verbatim from `regionalforecast-utils.mjs` so cities land in
/// the same places they do in ws4kp.
enum RegionalProjection {
    /// Base map dimensions and anchor.
    static let mapSize = CGSize(width: 2550, height: 1600)
    private static let anchorLatitude: Double = 50.5
    private static let anchorLongitude: Double = -127.5
    private static let pixelsPerDegreeLatitude: Double = 55.2
    private static let pixelsPerDegreeLongitude: Double = 41.775

    /// Degrees per display point, which fixes how much area the display covers.
    private static let displayPointsPerDegreeLongitude: Double = 57
    private static let displayPointsPerDegreeLatitude: Double = 70

    /// Pixel position on the base map for a coordinate.
    static func mapPoint(latitude: Double, longitude: Double) -> CGPoint {
        CGPoint(
            x: (longitude - anchorLongitude) * pixelsPerDegreeLongitude,
            y: (anchorLatitude - latitude) * pixelsPerDegreeLatitude
        )
    }

    /// Geographic bounds of the visible window, centered on the user's location.
    static func bounds(
        centerLatitude: Double,
        centerLongitude: Double,
        displaySize: CGSize
    ) -> (minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double) {
        let degreesWide = displaySize.width / displayPointsPerDegreeLongitude
        let degreesTall = displaySize.height / displayPointsPerDegreeLatitude
        return (
            centerLatitude - degreesTall / 2,
            centerLatitude + degreesTall / 2,
            centerLongitude - degreesWide / 2,
            centerLongitude + degreesWide / 2
        )
    }

    /// Position of a city within the display window.
    static func displayPoint(
        latitude: Double,
        longitude: Double,
        minLongitude: Double,
        maxLatitude: Double
    ) -> CGPoint {
        CGPoint(
            x: (longitude - minLongitude) * displayPointsPerDegreeLongitude,
            y: (maxLatitude - latitude) * displayPointsPerDegreeLatitude
        )
    }
}

/// Regional Observations: nearby cities plotted on a map, cycling through current
/// conditions and the next two forecast periods. Layout from
/// `_regional-forecast.scss`.
struct RegionalDisplay: View {
    @Environment(\.starMetrics) private var metrics
    @Environment(\.starContentWidth) private var contentWidth

    let screen: RegionalScreen
    let center: SavedLocation

    private enum Layout {
        static let viewportHeight: CGFloat = 282
        /// The plotted point sits inside the label group at this offset.
        static let labelOffsetX: CGFloat = -40
        static let labelOffsetY: CGFloat = -35
        static let iconOffsetX: CGFloat = 48
        static let iconOffsetY: CGFloat = 18
        static let iconHeight: CGFloat = 32
        static let temperatureOffsetY: CGFloat = 20
        /// Sized to stop short of the icon beside it. Three-digit readings condense
        /// rather than run under the artwork.
        static let temperatureWidth: CGFloat = 44
        static let labelWidth: CGFloat = 140
        /// Full vertical extent of a marker: city name, then icon and temperature.
        static let markerHeight: CGFloat = 50
        /// Minimum spacing between two markers. Requiring the full marker boxes not to
        /// intersect dropped nearly every city in a dense region like central Florida,
        /// which is worse than a little overlap; this keeps the map populated while
        /// still rejecting labels that would land on top of each other.
        static let minimumSeparation = CGSize(width: 56, height: 40)
    }

    private var viewportSize: CGSize {
        CGSize(width: contentWidth, height: Layout.viewportHeight)
    }

    private var bounds: (
        minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double
    ) {
        RegionalProjection.bounds(
            centerLatitude: center.latitude,
            centerLongitude: center.longitude,
            displaySize: viewportSize
        )
    }

    /// A city that survived placement, with the marker origin it was placed at.
    private struct PlacedMarker: Identifiable {
        let observation: RegionalObservation
        let origin: CGPoint
        var id: String { observation.id }
    }

    /// Place markers nearest-first, dropping any that would collide with one already
    /// placed or fall outside the map window.
    ///
    /// Cities cluster tightly in some regions — around Orlando, Daytona Beach's
    /// temperature landed on top of Orlando's name. Upstream has the same problem;
    /// skipping a colliding label keeps the map readable rather than stacking text.
    private var placedMarkers: [PlacedMarker] {
        var placed: [PlacedMarker] = []
        var occupied: [CGPoint] = []

        for observation in screen.observations {
            let point = RegionalProjection.displayPoint(
                latitude: observation.latitude,
                longitude: observation.longitude,
                minLongitude: bounds.minLongitude,
                maxLatitude: bounds.maxLatitude
            )
            let origin = CGPoint(
                x: point.x + Layout.labelOffsetX,
                y: point.y + Layout.labelOffsetY
            )

            // Drop markers that would be cut off by the display edges. The label sits
            // above and left of the plotted point, so the top edge is the tight one.
            guard origin.y >= 0,
                  origin.y + Layout.markerHeight <= Layout.viewportHeight,
                  origin.x >= 0,
                  origin.x + Layout.labelWidth <= contentWidth
            else { continue }

            // Reject only markers that are close in *both* axes; a city directly
            // above or beside another still reads fine.
            let tooClose = occupied.contains { other in
                abs(other.x - origin.x) < Layout.minimumSeparation.width
                    && abs(other.y - origin.y) < Layout.minimumSeparation.height
            }
            guard !tooClose else { continue }

            occupied.append(origin)
            placed.append(PlacedMarker(observation: observation, origin: origin))
        }

        return placed
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RegionalBaseMap(bounds: bounds, viewportSize: viewportSize)

            // Reversed so the nearest city — the one the user actually cares about —
            // is drawn last and wins wherever labels still graze each other.
            ForEach(placedMarkers.reversed()) { placed in
                marker(placed.observation)
                    .designPosition(x: placed.origin.x, y: placed.origin.y)
            }
        }
        .designFrame(
            width: contentWidth,
            height: Layout.viewportHeight,
            alignment: .topLeading
        )
        .clipped()
    }

    private func marker(_ observation: RegionalObservation) -> some View {
        ZStack(alignment: .topLeading) {
            // Held to one line: a wrapped name ("West Palm Beach", "Cape Coral")
            // dropped its second line straight onto the temperature below it.
            StarText(
                observation.city,
                font: .regular,
                size: 20,
                lineLimit: 1,
                minimumScaleFactor: 0.7
            )
            .designFrame(width: Layout.labelWidth, alignment: .leading)

            PixelImage(observation.icon, height: Layout.iconHeight)
                .designOffset(x: Layout.iconOffsetX, y: Layout.iconOffsetY)

            StarText(
                observation.temperature,
                font: .large,
                size: 28,
                color: StarColor.title,
                alignment: .trailing,
                lineLimit: 1,
                minimumScaleFactor: 0.8
            )
            .designFrame(width: Layout.temperatureWidth, alignment: .trailing)
            .designOffset(y: Layout.temperatureOffsetY)
        }
        .designFrame(width: Layout.labelWidth, alignment: .topLeading)
    }
}

/// Crops the bundled base map to the visible geographic window.
///
/// Cropping the source rather than transforming a full-size image means only the
/// visible pixels are resampled, and the map stays aligned with the plotted cities
/// at any output resolution.
private struct RegionalBaseMap: View {
    @Environment(\.starMetrics) private var metrics
    @Environment(\.starContentWidth) private var contentWidth

    let bounds: (minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double)
    let viewportSize: CGSize

    @State private var cropped: CGImage?

    var body: some View {
        Group {
            if let cropped {
                Image(decorative: cropped, scale: 1)
                    .interpolation(.medium)
                    .resizable()
                    .designFrame(width: viewportSize.width, height: viewportSize.height)
            } else {
                // The regional body colour, so the panel is never blank.
                Color(hex: 0x233270)
                    .designFrame(width: viewportSize.width, height: viewportSize.height)
            }
        }
        .task(id: "\(bounds.minLongitude),\(bounds.maxLatitude)") {
            cropped = await Self.crop(bounds: bounds)
        }
    }

    private static func crop(
        bounds: (minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double)
    ) async -> CGImage? {
        guard let url = WeatherStarResources.url("basemap.webp", in: .maps),
              let decoded = ImageDecoder.decodeSynchronously(url),
              let full = decoded.frames.first?.image
        else { return nil }

        let topLeft = RegionalProjection.mapPoint(
            latitude: bounds.maxLatitude,
            longitude: bounds.minLongitude
        )
        let bottomRight = RegionalProjection.mapPoint(
            latitude: bounds.minLatitude,
            longitude: bounds.maxLongitude
        )

        // Clamp so a location near the edge of the map does not crop out of bounds.
        let rect = CGRect(
            x: max(0, topLeft.x),
            y: max(0, topLeft.y),
            width: min(bottomRight.x - topLeft.x, CGFloat(full.width) - max(0, topLeft.x)),
            height: min(bottomRight.y - topLeft.y, CGFloat(full.height) - max(0, topLeft.y))
        )
        guard rect.width > 1, rect.height > 1 else { return nil }
        return full.cropping(to: rect)
    }
}
