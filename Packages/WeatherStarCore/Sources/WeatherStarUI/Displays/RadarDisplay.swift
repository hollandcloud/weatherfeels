import SwiftUI
import WeatherStarKit

/// Radar: the animated composite over a base map, with the places on it named.
///
/// The engine drives `screenIndex` through the frames on radar's own faster timing,
/// which is what produces the loop-then-pause animation the original hardware shows.
struct RadarDisplay: View {
    @Environment(\.starMetrics) private var metrics
    @Environment(\.starContentWidth) private var contentWidth

    let data: RadarData?
    let screenIndex: Int
    let center: SavedLocation?
    let timeZone: TimeZone

    enum Layout {
        static let height: CGFloat = 367
        /// The radar window's full width, which is the wide canvas's.
        ///
        /// Both layers are always drawn at this width and centred, and the standard canvas
        /// simply shows less of them. Stretching them to whichever width the canvas has would
        /// change the scale between canvases — and the frames and the base map would have to be
        /// stretched in exactly the same way, every time, to stay registered.
        static let fullWidth: CGFloat = RadarService.imageSize.width
        static let timestampY: CGFloat = 330
    }

    private var currentFrame: RadarFrame? {
        guard let frames = data?.frames, !frames.isEmpty else { return nil }
        return frames[min(max(screenIndex, 0), frames.count - 1)]
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack {
                if let center {
                    RadarBaseMap(center: center)
                }

                if let frame = currentFrame {
                    // Nearest-neighbour keeps the radar's blocky bins intact when scaled.
                    Image(decorative: frame.image, scale: 1)
                        .interpolation(.none)
                        .antialiased(false)
                        .resizable()
                        .designFrame(width: Layout.fullWidth, height: Layout.height)
                }
            }
            // Narrower than its contents on the standard canvas, which centres them: the
            // location stays in the middle of the window either way.
            .designFrame(width: contentWidth, height: Layout.height)
            .clipped()

            if let center {
                RadarLabels(center: center, visibleWidth: contentWidth)
            }

            if let frame = currentFrame {
                StarText(
                    Self.timestampText(frame.timestamp, in: timeZone),
                    font: .small,
                    size: 28,
                    color: StarColor.dateTime
                )
                .designPosition(x: 20, y: Layout.timestampY)

                RadarLegend()
                    .designPosition(
                        x: contentWidth - RadarLegend.width - 20,
                        y: Layout.timestampY + 6
                    )
            } else {
                StarText("Radar unavailable", font: .regular, size: 32)
                    .designPosition(x: 64, y: 150)
            }
        }
        .designFrame(width: contentWidth, height: Layout.height, alignment: .topLeading)
        .clipped()
    }

    private static func timestampText(_ date: Date, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date).uppercased()
    }
}

/// Where a coordinate falls in the radar window, in design points across its full width.
struct RadarWindow {
    let bounds: (minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double)

    init(center: SavedLocation) {
        bounds = RadarService.bounds(latitude: center.latitude, longitude: center.longitude)
    }

    func point(latitude: Double, longitude: Double) -> CGPoint {
        CGPoint(
            x: (longitude - bounds.minLongitude) / (bounds.maxLongitude - bounds.minLongitude)
                * RadarDisplay.Layout.fullWidth,
            y: (bounds.maxLatitude - latitude) / (bounds.maxLatitude - bounds.minLatitude)
                * RadarDisplay.Layout.height
        )
    }
}

/// The base map for the window, drawn from vectors at the screen's own resolution.
///
/// Drawn from the same bounds as the frames are requested with, so the map and the returns
/// stay registered wherever the user is.
private struct RadarBaseMap: View {
    @Environment(\.starMetrics) private var metrics
    @Environment(\.displayScale) private var displayScale

    let center: SavedLocation

    @State private var rendered: CGImage?

    /// Output pixels per design point, capped so a 4K television does not get a map wider
    /// than any GPU texture needs to be.
    private var pixelsPerPoint: CGFloat {
        min(max(metrics.scale * displayScale, 1), 4096 / RadarDisplay.Layout.fullWidth)
    }

    private struct RenderKey: Equatable {
        let location: String
        let pixelsPerPoint: CGFloat
    }

    var body: some View {
        Group {
            if let rendered {
                Image(decorative: rendered, scale: 1)
                    .resizable()
            } else {
                Color(cgColor: RadarMapRenderer.water)
            }
        }
        .designFrame(width: RadarDisplay.Layout.fullWidth, height: RadarDisplay.Layout.height)
        .task(id: RenderKey(location: center.id, pixelsPerPoint: pixelsPerPoint)) {
            rendered = RadarMapRenderer.image(
                bounds: RadarWindow(center: center).bounds,
                size: CGSize(width: RadarDisplay.Layout.fullWidth, height: RadarDisplay.Layout.height),
                pixelsPerPoint: pixelsPerPoint
            )
        }
    }
}

/// A named place on the radar.
struct RadarLabel: Identifiable, Equatable {
    let name: String
    /// The place itself, in the visible window's design points.
    let point: CGPoint
    /// Where the name is drawn, beside the point.
    let textFrame: CGRect
    /// The user's own location, marked differently from the towns around it.
    let isHome: Bool
    var id: String { name }
}

/// Which towns to name, and where their names go.
///
/// The original radar named the towns around the viewer, which is most of what makes a
/// radar useful: an echo means something once it is "just west of Lakeland". The user's own
/// place is always named; the rest are taken nearest first and dropped when their name would
/// collide with one already placed, or with the timestamp and the legend along the bottom.
enum RadarLabelLayout {
    static let fontSize: CGFloat = 20
    static let maximum = 8
    /// Nearer than this to the user's place, a town is the same place and is not named twice.
    static let sameplaceKilometres: Double = 20

    /// A town that can be named.
    struct Town: Sendable {
        let name: String
        let latitude: Double
        let longitude: Double
    }

    /// Every town the radar can name: the regional map's cities, and the observation
    /// stations the station table marks as a town's principal one.
    ///
    /// The regional list alone is too sparse at this scale — around Tampa it names Orlando and
    /// Daytona Beach and nothing between. Stations of priority 1 and 2 add Lakeland, Sarasota,
    /// Melbourne and their like; lower priorities are airfields and districts ("Central
    /// Colorado"), which read badly as place names.
    static let towns: [Town] = {
        var seen = Set<String>()
        var towns: [Town] = []
        for city in BundledData.regionalCities where seen.insert(city.city).inserted {
            towns.append(Town(name: city.city, latitude: city.latitude, longitude: city.longitude))
        }
        for station in BundledData.stations.values.sorted(by: { $0.id < $1.id })
        where (station.priority ?? .max) <= 2 {
            guard let name = station.city, seen.insert(name).inserted else { continue }
            towns.append(Town(name: name, latitude: station.lat, longitude: station.lon))
        }
        return towns
    }()

    @MainActor
    static func place(
        center: SavedLocation,
        visibleWidth: CGFloat,
        towns: [Town] = towns,
        measure: (String) -> CGFloat = { StarFont.regular.textWidth($0, size: fontSize) }
    ) -> [RadarLabel] {
        let window = RadarWindow(center: center)
        let shift = (RadarDisplay.Layout.fullWidth - visibleWidth) / 2
        let height = RadarDisplay.Layout.height
        let visible = CGRect(x: 0, y: 0, width: visibleWidth, height: height).insetBy(dx: 8, dy: 8)
        // The timestamp's corner and the legend's.
        let reserved = [
            CGRect(x: 0, y: RadarDisplay.Layout.timestampY - 6, width: 190, height: 50),
            CGRect(
                x: visibleWidth - RadarLegend.width - 30,
                y: RadarDisplay.Layout.timestampY - 6,
                width: RadarLegend.width + 30,
                height: 50
            ),
        ]

        func label(_ name: String, latitude: Double, longitude: Double, isHome: Bool) -> RadarLabel? {
            let full = window.point(latitude: latitude, longitude: longitude)
            let point = CGPoint(x: full.x - shift, y: full.y)
            guard visible.contains(point) else { return nil }
            let width = measure(name)
            let textHeight = fontSize * 1.15
            // To the right of the mark, or to its left when that would run off the edge.
            var frame = CGRect(x: point.x + 8, y: point.y - textHeight / 2, width: width, height: textHeight)
            if frame.maxX > visible.maxX {
                frame.origin.x = point.x - 8 - width
            }
            guard visible.contains(frame) else { return nil }
            return RadarLabel(name: name, point: point, textFrame: frame, isHome: isHome)
        }

        var placed: [RadarLabel] = []
        func fits(_ candidate: RadarLabel) -> Bool {
            let footprint = candidate.textFrame.union(
                CGRect(x: candidate.point.x - 5, y: candidate.point.y - 5, width: 10, height: 10)
            ).insetBy(dx: -4, dy: -2)
            return !reserved.contains { $0.intersects(footprint) }
                && !placed.contains { $0.textFrame.insetBy(dx: -4, dy: -2).intersects(footprint) }
        }

        let homeName = center.name.split(separator: ",").first.map(String.init) ?? center.name
        if let home = label(homeName, latitude: center.latitude, longitude: center.longitude, isHome: true),
           fits(home) {
            placed.append(home)
        }

        let nearestFirst = towns
            .map { town in
                (town, Calc.haversineKilometers(
                    lat1: center.latitude, lon1: center.longitude,
                    lat2: town.latitude, lon2: town.longitude
                ))
            }
            .filter { $0.1 > sameplaceKilometres }
            .sorted { $0.1 < $1.1 }

        for (town, _) in nearestFirst where placed.count < maximum {
            guard !placed.contains(where: { $0.name == town.name }),
                  let candidate = label(town.name, latitude: town.latitude, longitude: town.longitude, isHome: false),
                  fits(candidate)
            else { continue }
            placed.append(candidate)
        }
        return placed
    }
}

private struct RadarLabels: View {
    let center: SavedLocation
    let visibleWidth: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(RadarLabelLayout.place(center: center, visibleWidth: visibleWidth)) { label in
                let size: CGFloat = label.isHome ? 9 : 7
                Rectangle()
                    .fill(label.isHome ? StarColor.title : StarColor.body)
                    .overlay(Rectangle().strokeBorder(.black, lineWidth: 1))
                    .designFrame(width: size, height: size)
                    .designPosition(x: label.point.x - size / 2, y: label.point.y - size / 2)

                StarText(
                    label.name,
                    font: .regular,
                    size: RadarLabelLayout.fontSize,
                    color: label.isHome ? StarColor.title : StarColor.body,
                    shadowOffset: 2,
                    lineLimit: 1
                )
                .designPosition(x: label.textFrame.minX, y: label.textFrame.minY)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The colour scale, light to heavy, in the radar's own colours.
private struct RadarLegend: View {
    static let width: CGFloat = 250
    private static let bands: [Double] = [20, 25, 30, 35, 40, 45, 50, 60]

    var body: some View {
        HStack(spacing: 0) {
            StarText("Light", font: .small, size: 20, shadowOffset: 2)
                .designPadding(.trailing, 6)
            ForEach(Self.bands, id: \.self) { dBZ in
                let colour = RadarService.weatherStarColour(dBZ: dBZ)
                Rectangle()
                    .fill(Color(red: Double(colour.0) / 255, green: Double(colour.1) / 255, blue: Double(colour.2) / 255))
                    .overlay(Rectangle().strokeBorder(.black, lineWidth: 1))
                    .designFrame(width: 14, height: 14)
            }
            StarText("Heavy", font: .small, size: 20, shadowOffset: 2)
                .designPadding(.leading, 6)
        }
        .accessibilityHidden(true)
    }
}

/// SPC Outlook: the convective risk category covering the location.
struct SPCOutlookDisplay: View {
    @Environment(\.starMetrics) private var metrics
    @Environment(\.starContentWidth) private var contentWidth

    let data: SPCOutlookData?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let data, let risk = data.risk {
                StarText(data.validText, font: .regular, size: 32, color: StarColor.title)
                    .designPadding(.bottom, 30)
                StarText("Risk Category:", font: .regular, size: 32)
                    .designPadding(.bottom, 8)
                StarText(risk, font: .large, size: 32, color: StarColor.title)
            } else {
                StarText("No Severe Weather", font: .regular, size: 32, color: StarColor.title)
                    .designPadding(.bottom, 12)
                StarText("Outlook For This Area", font: .regular, size: 32)
            }
        }
        .designOffset(x: 84, y: 40)
    }
}
