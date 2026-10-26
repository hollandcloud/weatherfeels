import Foundation
import ImageIO
import SwiftUI
import Testing
@testable import WeatherStarKit
import WeatherStarResources
@testable import WeatherStarUI

@Suite("Weather bulletins")
@MainActor
struct BulletinTests {
    @Test("Warnings and extreme alerts interrupt; watches, advisories and statements do not")
    func whatInterrupts() {
        func interrupts(_ event: String, _ severity: String?, _ type: String? = "Alert") -> Bool {
            WeatherBulletin.isWorthInterrupting(event: event, severity: severity, messageType: type)
        }
        #expect(interrupts("Tornado Warning", "Extreme"))
        #expect(interrupts("Severe Thunderstorm Warning", "Severe"))
        #expect(interrupts("Flash Flood Warning", "Severe", "Update"))
        #expect(interrupts("Extreme Wind Warning", "Extreme"))
        #expect(interrupts("Storm Surge Watch", "Extreme"), "an Extreme alert interrupts whatever it is called")
        #expect(!interrupts("Tornado Watch", "Severe"))
        #expect(!interrupts("Heat Advisory", "Moderate"))
        #expect(!interrupts("Special Weather Statement", "Moderate"))
        #expect(!interrupts("Tornado Warning", "Extreme", "Cancel"), "a cancellation is not a reason to chime")
    }

    private func alert(_ json: String) throws -> AlertFeature {
        try JSONDecoder().decode(AlertFeature.self, from: Data(json.utf8))
    }

    /// The NWS hard-wraps alert text at about seventy columns for teletypes.
    @Test("The warning's teletype wrapping is reflowed, and its paragraphs kept")
    func textIsReflowed() throws {
        let feature = try alert("""
        {"id": "urn:oid:2.49.0.1.840.0.1", "properties": {
          "event": "Severe Thunderstorm Warning", "severity": "Severe", "messageType": "Alert",
          "headline": "Severe Thunderstorm Warning issued October 26 at 1:42PM EDT",
          "description": "At 142 PM EDT, a severe thunderstorm was located near\\nPlant City, moving east at 25 mph.\\n\\nHAZARD...60 mph wind gusts.",
          "instruction": "For your protection move to an interior room on the lowest\\nfloor of a building."
        }}
        """)
        let bulletin = try #require(WeatherBulletin(alert: feature))
        #expect(bulletin.text == """
        At 142 PM EDT, a severe thunderstorm was located near Plant City, moving east at 25 mph.

        HAZARD...60 mph wind gusts.

        For your protection move to an interior room on the lowest floor of a building.
        """)
        #expect(bulletin.headline.hasPrefix("Severe Thunderstorm Warning issued"))
    }

    @Test("An advisory does not become a bulletin")
    func advisoryIsNotABulletin() throws {
        let feature = try alert("""
        {"id": "urn:oid:2", "properties": {"event": "Wind Advisory", "severity": "Moderate"}}
        """)
        #expect(WeatherBulletin(alert: feature) == nil)
    }

    @Test("A bulletin already shown is not shown again, and the memory stays small")
    func shownAreRemembered() {
        let settings = AppSettings(defaults: TemporaryDefaults.make("ws4k.bulletins"))
        let warning = WeatherBulletin(id: "a", event: "Tornado Warning", headline: "", text: "")
        let update = WeatherBulletin(id: "b", event: "Tornado Warning", headline: "", text: "")

        #expect(WeatherBulletin.unseen([warning, update], shown: []).map(\.id) == ["a", "b"])
        settings.rememberBulletin("a")
        settings.rememberBulletin("a")
        #expect(settings.shownBulletinIDs == ["a"])
        #expect(WeatherBulletin.unseen([warning, update], shown: Set(settings.shownBulletinIDs)).map(\.id) == ["b"])

        for index in 0..<80 { settings.rememberBulletin("id-\(index)") }
        #expect(settings.shownBulletinIDs.count == 50)
        #expect(settings.shownBulletinIDs.last == "id-79")
        #expect(settings.bulletinsEnabled, "bulletins are on by default")
        #expect(settings.bulletinTone)
    }

    /// The chime's energy at a frequency, by the Goertzel algorithm, relative to its total.
    private func energy(at hz: Double, in samples: [Double], rate: Double) -> Double {
        let coefficient = 2 * cos(2 * .pi * hz / rate)
        var previous = 0.0, beforePrevious = 0.0
        for sample in samples {
            let current = sample + coefficient * previous - beforePrevious
            beforePrevious = previous
            previous = current
        }
        return previous * previous + beforePrevious * beforePrevious - coefficient * previous * beforePrevious
    }

    /// The claim in `Tools/MakeSounds.py`, measured: the chime sits on A and E, and carries
    /// next to nothing at the Emergency Alert System's attention tones or NOAA Weather Radio's
    /// warning tone.
    @Test("The chime keeps clear of the broadcast alert tones")
    func chimeAvoidsAlertTones() throws {
        let url = try #require(WeatherStarResources.url("bulletin-tone.wav", in: .sounds))
        let data = try Data(contentsOf: url)
        // 16-bit mono PCM after the 44-byte header, as `MakeSounds.py` writes it.
        let samples = stride(from: 44, to: data.count - 1, by: 2).map { offset -> Double in
            Double(Int16(bitPattern: UInt16(data[offset]) | UInt16(data[offset + 1]) << 8)) / 32768
        }
        let chime = min(energy(at: 880, in: samples, rate: 44_100), energy(at: 659.26, in: samples, rate: 44_100))
        for (name, hz) in [("EAS 853 Hz", 853.0), ("EAS 960 Hz", 960.0), ("NOAA Weather Radio 1050 Hz", 1050.0)] {
            let stray = energy(at: hz, in: samples, rate: 44_100)
            #expect(stray < chime / 20, "\(name) carries \(stray / chime) of the chime's own energy")
        }
    }
}

#if os(macOS)
@Suite("Bulletin snapshot")
@MainActor
struct BulletinSnapshotTests {
    @Test("The bulletin renders over the whole canvas")
    func bulletinRenders() throws {
        StarFontLoader.registerFonts()
        let bulletin = WeatherBulletin(
            id: "x",
            event: "Severe Thunderstorm Warning",
            headline: "Severe Thunderstorm Warning issued October 26 at 1:42PM EDT until October 26 at 2:30PM EDT by NWS Tampa Bay Ruskin FL",
            text: "At 142 PM EDT, a severe thunderstorm was located near Plant City, moving east at 25 mph.\n\nHAZARD...60 mph wind gusts and penny size hail.\n\nFor your protection move to an interior room on the lowest floor of a building."
        )
        let metrics = StarMetrics(space: .standard, container: CGSize(width: 1280, height: 960))
        let view = BulletinScreen(bulletin: bulletin, shownAt: Date())
            .environment(\.starMetrics, metrics)
            .environment(\.starContentWidth, 640)
            .frame(width: metrics.scaledSize.width, height: metrics.scaledSize.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)

        let directory = URL(fileURLWithPath: "/tmp/ws4k-snapshots")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let destination = CGImageDestinationCreateWithURL(
            directory.appendingPathComponent("bulletin.png") as CFURL, "public.png" as CFString, 1, nil
        ) {
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        #expect(image.width == Int(metrics.scaledSize.width))
    }
}
#endif
