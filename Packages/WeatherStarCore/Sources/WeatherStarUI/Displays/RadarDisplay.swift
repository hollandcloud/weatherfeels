import SwiftUI
import WeatherStarKit
import WeatherStarResources

/// Radar: the animated composite over a base map.
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

    private enum Layout {
        static let top: CGFloat = 0
        static let height: CGFloat = 367
        static let timestampY: CGFloat = 330
    }

    private var currentFrame: RadarFrame? {
        guard let frames = data?.frames, !frames.isEmpty else { return nil }
        return frames[min(max(screenIndex, 0), frames.count - 1)]
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let center {
                RadarBaseMap(center: center, viewportSize: viewportSize)
            }

            if let frame = currentFrame {
                // Nearest-neighbour keeps the radar's blocky bins intact when scaled.
                Image(decorative: frame.image, scale: 1)
                    .interpolation(.none)
                    .antialiased(false)
                    .resizable()
                    .designFrame(width: contentWidth, height: Layout.height)

                StarText(
                    Self.timestampText(frame.timestamp, in: timeZone),
                    font: .small,
                    size: 28,
                    color: StarColor.dateTime
                )
                .designPosition(x: 20, y: Layout.timestampY)
            } else {
                StarText("Radar unavailable", font: .regular, size: 32)
                    .designPosition(x: 64, y: 150)
            }
        }
        .designFrame(width: contentWidth, height: Layout.height, alignment: .topLeading)
        .clipped()
    }

    private var viewportSize: CGSize {
        CGSize(width: contentWidth, height: Layout.height)
    }

    private static func timestampText(_ date: Date, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date).uppercased()
    }
}

/// Base map cropped to exactly the radar frame's geographic window.
///
/// Both layers derive their bounds from `RadarService.bounds`, so the map and the
/// returns stay registered no matter where the user is.
private struct RadarBaseMap: View {
    @Environment(\.starMetrics) private var metrics
    @Environment(\.starContentWidth) private var contentWidth

    let center: SavedLocation
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
                Color(hex: 0x233270)
                    .designFrame(width: viewportSize.width, height: viewportSize.height)
            }
        }
        .task(id: center.id) {
            cropped = Self.crop(center: center)
        }
    }

    private static func crop(center: SavedLocation) -> CGImage? {
        let bounds = RadarService.bounds(
            latitude: center.latitude,
            longitude: center.longitude
        )

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
