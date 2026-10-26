import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
@testable import WeatherStarKit
import WeatherStarResources
@testable import WeatherStarUI

/// The radar's vector base map: that it loads, that it puts real places where they are, and
/// that the towns named on it never pile up.
@Suite("Radar map")
@MainActor
struct RadarMapTests {
    private let tampa = SavedLocation(name: "Tampa, FL", latitude: 27.9506, longitude: -82.4572)

    @Test("The bundled map decodes with every layer")
    func bundledMapDecodes() throws {
        let map = try #require(VectorMap.bundled)
        for layer in VectorMap.Layer.allCases {
            #expect(!(map.layers[layer] ?? []).isEmpty, "\(layer) is empty")
        }
    }

    @Test("A truncated map is rejected rather than half-read")
    func truncatedMapIsRejected() throws {
        let url = try #require(WeatherStarResources.url("radarmap.bin", in: .maps))
        let data = try Data(contentsOf: url)
        #expect(VectorMap.decode(data.prefix(data.count / 2)) == nil)
        #expect(VectorMap.decode(Data("not a map".utf8)) == nil)
    }

    /// Reads the colour of one coordinate off a rendered map.
    private func colour(
        at latitude: Double, _ longitude: Double, in image: CGImage, window: RadarWindow
    ) -> (UInt8, UInt8, UInt8) {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let point = window.point(latitude: latitude, longitude: longitude)
        let x = Int(point.x / RadarDisplay.Layout.fullWidth * CGFloat(width))
        let y = Int(point.y / RadarDisplay.Layout.height * CGFloat(height))
        let offset = (y * width + x) * 4
        return (pixels[offset], pixels[offset + 1], pixels[offset + 2])
    }

    /// Registration against the world rather than against the app's own arithmetic: inland
    /// Orlando must come out as land, the Gulf and Lake Okeechobee as water.
    @Test("Real places land on the right side of the coast")
    func placesRegister() throws {
        let window = RadarWindow(center: tampa)
        let image = try #require(RadarMapRenderer.image(
            bounds: window.bounds,
            size: CGSize(width: RadarDisplay.Layout.fullWidth, height: RadarDisplay.Layout.height),
            pixelsPerPoint: 2
        ))
        let land: (UInt8, UInt8, UInt8) = (0x7E, 0x7E, 0x7E)
        let water: (UInt8, UInt8, UInt8) = (0x2F, 0x60, 0xA9)

        let places: [(String, Double, Double, (UInt8, UInt8, UInt8))] = [
            ("Orlando", 28.5383, -81.3792, land),
            ("Lakeland", 28.0395, -81.9498, land),
            ("the Gulf off Clearwater", 27.95, -83.20, water),
            ("Lake Okeechobee", 26.95, -80.83, water),
            ("the Atlantic off Cape Canaveral", 28.40, -80.20, water),
        ]
        for (name, latitude, longitude, expected) in places {
            let found = colour(at: latitude, longitude, in: image, window: window)
            #expect(found == expected, "\(name) came out \(found), not \(expected)")
        }
    }

    @Test("Named towns never overlap, and stay clear of the timestamp and legend")
    func labelsDoNotCollide() {
        for width in [CGFloat(640), 854] {
            let labels = RadarLabelLayout.place(center: tampa, visibleWidth: width) {
                CGFloat($0.count) * 12
            }
            #expect(labels.first?.isHome == true, "the user's place is named first")
            #expect(labels.first?.name == "Tampa")
            #expect(labels.count > 2, "only \(labels.count) towns named around Tampa")
            for (index, label) in labels.enumerated() {
                #expect(label.textFrame.minX >= 0 && label.textFrame.maxX <= width, "\(label.name) runs off")
                #expect(label.textFrame.maxY < RadarDisplay.Layout.timestampY - 6
                    || (label.textFrame.minX > 190 && label.textFrame.maxX < width - 280),
                    "\(label.name) sits on the timestamp or legend")
                for other in labels[(index + 1)...] {
                    #expect(!label.textFrame.intersects(other.textFrame), "\(label.name) overlaps \(other.name)")
                }
            }
        }
    }
}

#if os(macOS)
/// The whole radar display, rendered for eyeballing to `/tmp/ws4k-snapshots/radar.png`.
@Suite("Radar snapshot")
@MainActor
struct RadarSnapshotTests {
    @Test("The radar display renders over its map")
    func radarRenders() throws {
        StarFontLoader.registerFonts()
        let tampa = SavedLocation(name: "Tampa, FL", latitude: 27.9506, longitude: -82.4572)

        // A synthetic frame: a band of storms north-east of the city, light at the edges.
        let size = RadarService.imageSize
        let context = try #require(CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        for (dBZ, inset) in [(22.0, 0.0), (32.0, 10.0), (42.0, 20.0), (52.0, 28.0)] {
            let colour = RadarService.weatherStarColour(dBZ: dBZ)
            context.setFillColor(
                red: CGFloat(colour.0) / 255, green: CGFloat(colour.1) / 255,
                blue: CGFloat(colour.2) / 255, alpha: 1
            )
            context.fillEllipse(in: CGRect(x: 520 + inset, y: 200 + inset, width: 90 - inset * 2, height: 60 - inset * 2))
        }
        let frame = try #require(context.makeImage())

        let metrics = StarMetrics(space: .standard, container: CGSize(width: 1280, height: 960))
        let view = RadarDisplay(
            data: RadarData(frames: [RadarFrame(timestamp: Date(timeIntervalSince1970: 1_793_030_100), image: frame)], baseMap: nil),
            screenIndex: 0,
            center: tampa,
            timeZone: TimeZone(identifier: "America/New_York")!
        )
        .environment(\.starMetrics, metrics)
        .environment(\.starContentWidth, 640)
        .frame(width: 640 * metrics.scale, height: 367 * metrics.scale)
        .background(Color.black)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)

        let directory = URL(fileURLWithPath: "/tmp/ws4k-snapshots")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let destination = CGImageDestinationCreateWithURL(
            directory.appendingPathComponent("radar.png") as CFURL, "public.png" as CFString, 1, nil
        ) {
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        #expect(image.width == Int(640 * metrics.scale))
    }
}
#endif
