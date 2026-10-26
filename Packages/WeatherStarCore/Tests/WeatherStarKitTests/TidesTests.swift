import Foundation
import ImageIO
import SwiftUI
import Testing
@testable import WeatherStarKit
@testable import WeatherStarUI

@Suite("Tides")
@MainActor
struct TidesTests {
    @Test("The bundled station table loads")
    func stationsLoad() {
        #expect(TideService.stations.count > 3000)
        #expect(TideService.stations.allSatisfy { !$0.id.isEmpty && !$0.name.isEmpty })
    }

    @Test("A coastal city finds its station; inland ones do not")
    func nearestStation() throws {
        let tampa = try #require(TideService.nearestStation(latitude: 27.9506, longitude: -82.4572))
        #expect(tampa.state == "FL")
        let distance = Calc.haversineKilometers(lat1: 27.9506, lon1: -82.4572, lat2: tampa.latitude, lon2: tampa.longitude)
        #expect(distance < 10, "\(tampa.name) is \(distance) km from downtown Tampa")
        #expect(TideService.nearestStation(latitude: 28.5383, longitude: -81.3792) == nil, "Orlando is inland")
        #expect(TideService.nearestStation(latitude: 39.7392, longitude: -104.9903) == nil, "Denver is inland")
    }

    /// A real CO-OPS answer for St. Petersburg, in GMT, as the service asks for it.
    private let response = Data("""
    { "predictions" : [
    {"t":"2026-10-26 05:37", "v":"3.068", "type":"H"},{"t":"2026-10-26 13:19", "v":"-0.101", "type":"L"},
    {"t":"2026-10-26 19:46", "v":"2.38", "type":"H"},{"t":"2026-10-27 00:36", "v":"1.566", "type":"L"},
    {"t":"2026-10-27 05:56", "v":"3.298", "type":"H"},{"t":"2026-10-27 14:05", "v":"-0.27", "type":"L"},
    {"t":"2026-10-27 20:49", "v":"2.197", "type":"H"},{"t":"2026-10-28 00:51", "v":"1.715", "type":"L"}
    ]}
    """.utf8)

    @Test("Predictions parse, and land in the location's own days")
    func parseAndGroup() throws {
        let events = try TideService.parse(response)
        #expect(events.count == 8)
        #expect(events.first?.isHigh == true)
        #expect(events.first?.height == 3.068)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26))!
        let days = TideService.group(events, from: today, days: 2, calendar: calendar)
        #expect(days.map(\.name) == ["Monday", "Tuesday"])
        // 00:36 GMT on the 27th is 8:36 PM on the 26th in Tampa: Monday's last low, not Tuesday's first.
        #expect(days[0].events.count == 4)
        #expect(days[0].events.last?.isHigh == false)
        #expect(days[1].events.count == 4)
    }

    @Test("Predictions are asked for in GMT, from local midnight")
    func requestShape() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26))!
        let url = try #require(TideService.predictionsURL(station: "8726520", from: midnight, hours: 48, metric: false))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        #expect(value("time_zone") == "gmt")
        #expect(value("begin_date") == "20261026 04:00", "midnight EDT is 04:00 GMT")
        #expect(value("interval") == "hilo")
        #expect(value("units") == "english")
    }

    #if os(macOS)
    @Test("The display renders")
    func displayRenders() throws {
        StarFontLoader.registerFonts()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26))!
        let data = TidesData(
            station: TideStation(id: "8726520", name: "St. Petersburg, Tampa Bay", state: "FL", latitude: 27.76, longitude: -82.63),
            days: TideService.group(try TideService.parse(response), from: today, days: 2, calendar: calendar),
            unit: "ft"
        )
        let metrics = StarMetrics(space: .standard, container: CGSize(width: 1280, height: 960))
        let view = StarDisplayFrame(display: .tides, clockFormat: { _ in ("10:42:08 AM", "MON OCT 26") }) {
            TidesDisplay(data: data, timeZone: calendar.timeZone)
        }
        .environment(\.starMetrics, metrics)
        .frame(width: metrics.scaledSize.width, height: metrics.scaledSize.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let directory = URL(fileURLWithPath: "/tmp/ws4k-snapshots")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let destination = CGImageDestinationCreateWithURL(
            directory.appendingPathComponent("tides.png") as CFURL, "public.png" as CFString, 1, nil
        ) {
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        #expect(image.width == Int(metrics.scaledSize.width))
    }
    #endif
}
