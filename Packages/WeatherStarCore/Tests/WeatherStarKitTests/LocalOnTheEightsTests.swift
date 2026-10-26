import Foundation
import ImageIO
import SwiftUI
import Testing
@testable import WeatherStarKit
@testable import WeatherStarUI

@Suite("Local on the 8s")
@MainActor
struct LocalOnTheEightsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func time(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: hour, minute: minute, second: second))!
    }

    @Test("The cue is the next minute ending in 8")
    func nextCue() {
        #expect(LocalOnTheEights.nextCue(after: time(10, 7, 30), calendar: calendar) == time(10, 8))
        #expect(LocalOnTheEights.nextCue(after: time(10, 8), calendar: calendar) == time(10, 18), "not the cue already reached")
        #expect(LocalOnTheEights.nextCue(after: time(10, 8, 1), calendar: calendar) == time(10, 18))
        #expect(LocalOnTheEights.nextCue(after: time(10, 9), calendar: calendar) == time(10, 18))
        #expect(LocalOnTheEights.nextCue(after: time(10, 59, 59), calendar: calendar) == time(11, 8))
        #expect(LocalOnTheEights.nextCue(after: time(23, 58, 30), calendar: calendar) == time(0, 8).addingTimeInterval(86_400))
    }

    /// An engine with every display in the rotation ready.
    private func engine(_ displays: [DisplayIdentifier]) -> DisplayEngine {
        let engine = DisplayEngine()
        engine.isPlaying = false
        engine.enabledDisplays = displays
        for display in displays {
            engine.setTiming(.standard, for: display)
            engine.setStatus(.loaded, for: display)
        }
        return engine
    }

    @Test("The segment plays in order, then the rotation carries on after where it was")
    func segmentThenResume() {
        let engine = engine([.currentWeather, .latestObservations, .localForecast, .extendedForecast, .almanac])
        engine.nextDisplay()
        engine.nextDisplay()
        #expect(engine.activeDisplay == .localForecast)
        engine.nextDisplay()
        #expect(engine.activeDisplay == .extendedForecast)
        engine.nextDisplay()
        #expect(engine.activeDisplay == .almanac)

        engine.playSegment(LocalOnTheEights.segment)
        #expect(engine.isPlayingSegment)
        #expect(engine.activeDisplay == .currentWeather)
        engine.nextDisplay()
        #expect(engine.activeDisplay == .localForecast)
        engine.nextDisplay()
        #expect(engine.activeDisplay == .extendedForecast)
        engine.nextDisplay()
        #expect(!engine.isPlayingSegment)
        #expect(engine.activeDisplay == .currentWeather, "the rotation resumes after Almanac, wrapping to the top")
    }

    @Test("A segment display with nothing to show is skipped")
    func notReadyIsSkipped() {
        let engine = engine([.currentWeather, .extendedForecast, .almanac])
        engine.playSegment(LocalOnTheEights.segment)
        #expect(engine.activeDisplay == .currentWeather)
        engine.nextDisplay()
        #expect(engine.activeDisplay == .extendedForecast, "Local Forecast has no data, so it is passed over")
    }

    @Test("Going back abandons the segment")
    func previousAbandons() {
        let engine = engine([.currentWeather, .localForecast, .extendedForecast, .almanac])
        engine.playSegment(LocalOnTheEights.segment)
        engine.previousDisplay()
        #expect(!engine.isPlayingSegment)
    }

    @Test("With nothing ready, there is no segment")
    func nothingReady() {
        let engine = engine([.almanac])
        engine.playSegment(LocalOnTheEights.segment)
        #expect(!engine.isPlayingSegment)
        #expect(engine.activeDisplay == .almanac)
    }

    @Test("Off by default")
    func offByDefault() {
        let settings = AppSettings(defaults: TemporaryDefaults.make("ws4k.eights"))
        #expect(!settings.localOnTheEights)
    }

    #if os(macOS)
    @Test("The bumper renders")
    func bumperRenders() throws {
        StarFontLoader.registerFonts()
        let metrics = StarMetrics(space: .standard, container: CGSize(width: 1280, height: 960))
        let view = EightsBumper(place: "Tampa, FL", time: "10:08 AM")
            .environment(\.starMetrics, metrics)
            .environment(\.starContentWidth, 640)
            .frame(width: metrics.scaledSize.width, height: metrics.scaledSize.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let directory = URL(fileURLWithPath: "/tmp/ws4k-snapshots")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let destination = CGImageDestinationCreateWithURL(
            directory.appendingPathComponent("eights-bumper.png") as CFURL, "public.png" as CFString, 1, nil
        ) {
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        #expect(image.width == Int(metrics.scaledSize.width))
    }
    #endif
}
