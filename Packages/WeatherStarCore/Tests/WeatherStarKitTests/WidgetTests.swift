import Foundation
import ImageIO
import SwiftUI
import Testing
@testable import WeatherStarKit
@testable import WeatherStarUI

@Suite("Home screen widget")
@MainActor
struct WidgetTests {
    @Test("The app's place and units reach the widget through the shared container")
    func sharedRoundTrip() throws {
        let defaults = TemporaryDefaults.make("ws4k.widget")
        #expect(SharedContainer.shared(from: defaults) == nil, "nothing shared yet: the widget asks for a place")

        let tampa = SavedLocation(name: "Tampa, FL", latitude: 27.9506, longitude: -82.4572)
        SharedContainer.publish(location: tampa, units: .si, into: defaults)
        let shared = try #require(SharedContainer.shared(from: defaults))
        #expect(shared.location == tampa)
        #expect(shared.units == .si)

        SharedContainer.publish(location: nil, units: .us, into: defaults)
        #expect(SharedContainer.shared(from: defaults) == nil, "a cleared place is cleared for the widget too")
    }

    @Test("The large widget lists what the station reported, worded as the display words it")
    func readings() throws {
        let json = """
        {"temperature": {"value": 30}, "dewpoint": {"value": 20}, "windDirection": {"value": 90},
         "windSpeed": {"value": 16}, "relativeHumidity": {"value": 55.4}, "barometricPressure": {"value": 101620},
         "heatIndex": {"value": 33}}
        """
        let observation = try JSONDecoder().decode(WeatherObservation.self, from: Data(json.utf8))
        let readings = WidgetWeatherService.readings(observation, units: UnitConverters(system: .us))
        #expect(readings == [
            .init("Wind:", "E 10"),
            .init("Humidity:", "55%"),
            .init("Dewpoint:", "68\u{00B0}"),
            .init("Pressure:", "30.00 in.hg"),
            .init("Heat Index:", "91\u{00B0}"),
        ], "no visibility reported, so no visibility row")
    }

    #if os(macOS)
    @Test("The widget renders at each size, and as a placeholder")
    func widgetRenders() throws {
        StarFontLoader.registerFonts()
        let weather = WidgetWeather(
            place: "Tampa, FL", temperature: "79\u{00B0}", condition: "Mostly Cloudy",
            icon: "https://api.weather.gov/icons/land/day/bkn", observedAt: Date(timeIntervalSince1970: 1_793_030_100),
            readings: [
                .init("Wind:", "E 9"), .init("Humidity:", "68%"), .init("Dewpoint:", "68\u{00B0}"),
                .init("Visibility:", "10 mi."), .init("Pressure:", "30.01 in.hg"), .init("Heat Index:", "82\u{00B0}"),
            ]
        )
        let cases: [(String, WidgetWeather?, WeatherWidgetView.Size, CGSize)] = [
            ("widget-small", weather, .small, CGSize(width: 170, height: 170)),
            ("widget-medium", weather, .medium, CGSize(width: 364, height: 170)),
            ("widget-large", weather, .large, CGSize(width: 364, height: 382)),
            ("widget-large-se", weather, .large, CGSize(width: 321, height: 324)),
            ("widget-placeholder", nil, .small, CGSize(width: 170, height: 170)),
        ]
        let directory = URL(fileURLWithPath: "/tmp/ws4k-snapshots")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, weather, size, frame) in cases {
            let view = WeatherWidgetView(weather: weather, size: size)
                .frame(width: frame.width, height: frame.height)
                .background(WeatherWidgetBackground())
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            let image = try #require(renderer.cgImage, "\(name) did not render")
            if let destination = CGImageDestinationCreateWithURL(
                directory.appendingPathComponent("\(name).png") as CFURL, "public.png" as CFString, 1, nil
            ) {
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
            }
        }
    }
    #endif
}
