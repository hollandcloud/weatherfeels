import Foundation
import ImageIO
import SwiftUI
import Testing
@testable import WeatherStarKit
@testable import WeatherStarUI

@Suite("Ads")
@MainActor
struct AdsTests {
    private func settings() -> AppSettings {
        AppSettings(defaults: TemporaryDefaults.make("ws4k.ads"))
    }

    /// Counts requests, and answers with a fixed body.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        var requested: [URL] { lock.withLock { urls } }
        func record(_ url: URL) { lock.withLock { urls.append(url) } }
    }

    private func library(_ recorder: Recorder, body: String = #"{"version":1}"#) -> AdsLibrary {
        AdsLibrary(fetch: { url in
            recorder.record(url)
            return Data(body.utf8)
        })
    }

    @Test("Every ad feature is off by default")
    func offByDefault() {
        let settings = settings()
        #expect(!settings.tickerAdsEnabled)
        #expect(!settings.adCardsEnabled)
        #expect(!settings.clipReelEnabled)
        #expect(settings.tickerAdLines.isEmpty)
        #expect(settings.adBreakEvery == AdBreaks.defaultInterval)
    }

    /// The owner's rule, held as a test: nothing hosted outside the app is used until asked
    /// for. Not just "not shown" — not even fetched.
    @Test("Nothing is fetched from the server until an ad feature is switched on")
    func noFetchUntilAskedFor() async {
        let settings = settings()
        let recorder = Recorder()
        let ads = library(recorder)

        await ads.refresh(settings: settings)
        #expect(recorder.requested.isEmpty, "defaults: no request")

        settings.remoteMusicURLString = "http://nas.local:8080"
        await ads.refresh(settings: settings)
        #expect(recorder.requested.isEmpty, "a server set for music is not consent to fetch ads")

        settings.remoteMusicURLString = ""
        settings.tickerAdsEnabled = true
        await ads.refresh(settings: settings)
        #expect(recorder.requested.isEmpty, "no server, nothing to fetch")

        settings.remoteMusicURLString = "http://nas.local:8080"
        await ads.refresh(settings: settings)
        #expect(recorder.requested.map(\.absoluteString) == ["http://nas.local:8080/ads.json"])

        settings.tickerAdsEnabled = false
        await ads.refresh(settings: settings)
        #expect(recorder.requested.count == 1, "switched off again: no further request")
        #expect(ads.manifest == .empty, "and the old manifest is forgotten")
    }

    @Test("A manifest is read leniently: one bad item costs that item, not the file")
    func lenientManifest() throws {
        let json = """
        {"version": 2, "somethingNew": true,
         "ticker": [{"id": "t1", "text": "  GULF COAST MARINE  "}, {"id": "t2", "text": "off", "enabled": false}, {"text": "no id"}],
         "cards": [
           "a stray string",
           {"id": "c1", "business": "Gulf Coast Marine", "theme": "plaid", "imageMode": "sideways",
            "lines": ["a", "b", "c", "d", "e"], "seconds": 300, "extra": {"nested": 1}},
           {"id": "c2", "business": ""},
           {"id": "c3", "business": "Ok", "seconds": 1}
         ],
         "clips": [{"id": "v1", "file": "ads/clips/spot.mp4", "title": "Spot"}, {"id": "v2"}]}
        """
        let manifest = try AdsManifest.decode(Data(json.utf8), base: URL(string: "http://nas:8080")!)
        #expect(manifest.ticker == [TickerAd(id: "t1", text: "GULF COAST MARINE")])
        #expect(manifest.cards.map(\.id) == ["c1", "c3"])
        #expect(manifest.cards[0].theme == .blue, "an unknown theme falls back to blue")
        #expect(manifest.cards[0].imageMode == .beside)
        #expect(manifest.cards[0].lines.count == 4)
        #expect(manifest.cards[0].seconds == 30)
        #expect(manifest.cards[1].seconds == 4)
        #expect(manifest.clips.map(\.id) == ["v1"])
    }

    @Test("Files resolve against the server however its address was typed")
    func urlResolution() throws {
        func image(base: String, path: String) throws -> String? {
            let json = #"{"cards":[{"id":"c","business":"B","image":"\#(path)"}]}"#
            return try AdsManifest.decode(Data(json.utf8), base: URL(string: base)!).cards.first?.image?.absoluteString
        }
        #expect(try image(base: "http://nas:8080", path: "ads/images/x.png") == "http://nas:8080/ads/images/x.png")
        #expect(try image(base: "http://nas:8080/ws4k", path: "ads/images/x.png") == "http://nas:8080/ws4k/ads/images/x.png",
                "a path prefix is kept, not dropped")
        #expect(try image(base: "http://nas:8080/ws4k/", path: "ads/images/x.png") == "http://nas:8080/ws4k/ads/images/x.png")
        #expect(try image(base: "http://nas:8080", path: "/ads/images/x.png") == "http://nas:8080/ads/images/x.png")
        #expect(try image(base: "http://nas:8080", path: "http://NAS:8080/ads/images/x.png") == "http://NAS:8080/ads/images/x.png")
        #expect(try image(base: "http://nas:8080", path: "https://elsewhere.example/x.png") == nil,
                "the manifest cannot send the app to another host")
        #expect(AdsManifest.manifestURL(base: URL(string: "http://nas:8080/ws4k")!)?.absoluteString == "http://nas:8080/ws4k/ads.json")
    }

    @Test("Long ticker lines break into pages at word boundaries")
    func tickerPages() {
        #expect(TickerAds.pages(for: "SHORT LINE") == ["SHORT LINE"])
        let pages = TickerAds.pages(for: "VISIT GULF COAST MARINE FOR OUTBOARD SERVICE AND FREE ESTIMATES  555-0142")
        #expect(pages.count == 3)
        #expect(pages.allSatisfy { $0.count <= TickerAds.pageLength })
        #expect(pages.joined(separator: " ") == "VISIT GULF COAST MARINE FOR OUTBOARD SERVICE AND FREE ESTIMATES 555-0142")
        #expect(TickerAds.pages(for: String(repeating: "X", count: 50)).count == 1, "an unbreakable word gets a page of its own")
    }

    @Test("Ads take turns among the readings rather than crowding them out")
    func interleave() {
        let readings = ["R1", "R2", "R3", "R4", "R5", "R6", "R7"]
        let result = TickerAds.interleave(readings: readings, ads: ["A", "B", "C"], rotation: 0)
        #expect(result == ["R1", "R2", "R3", "A", "R4", "R5", "R6", "B", "R7"])
        let next = TickerAds.interleave(readings: readings, ads: ["A", "B", "C"], rotation: 2)
        #expect(next == ["R1", "R2", "R3", "C", "R4", "R5", "R6", "A", "R7"], "the next rebuild rotates")
        #expect(TickerAds.interleave(readings: readings, ads: [], rotation: 0) == readings)
        #expect(TickerAds.interleave(readings: ["R1"], ads: ["A"], rotation: 0) == ["R1", "A"])
    }

    @Test("A break is taken only when due and when nothing outranks it")
    func breakConditions() {
        #expect(AdBreaks.isDue(displaysSinceBreak: 8, every: 8, conditions: .init()))
        #expect(!AdBreaks.isDue(displaysSinceBreak: 7, every: 8, conditions: .init()))
        #expect(!AdBreaks.isDue(displaysSinceBreak: 9, every: 8, conditions: .init(bulletinShowing: true)))
        #expect(!AdBreaks.isDue(displaysSinceBreak: 9, every: 8, conditions: .init(localSegmentPlaying: true)))
        #expect(!AdBreaks.isDue(displaysSinceBreak: 9, every: 8, conditions: .init(rotationHeld: true)))
        #expect(!AdBreaks.isDue(displaysSinceBreak: 9, every: 8, conditions: .init(pictureIsOn: false)))
        #expect(!AdBreaks.isDue(displaysSinceBreak: 9, every: 8, conditions: .init(sceneIsActive: false)))
    }

    /// The hold button shows `isPlaying`; an ad break must not touch it.
    @Test("Suspending the rotation leaves the user's play state alone")
    func suspendIsSeparate() {
        let engine = DisplayEngine()
        engine.isPlaying = true
        engine.isSuspended = true
        #expect(engine.isPlaying)
        engine.isPlaying = false
        engine.isSuspended = false
        #expect(!engine.isPlaying, "ending a break does not restart a held rotation")
    }

    #if os(macOS)
    @Test("A card renders in every theme")
    func cardsRender() throws {
        StarFontLoader.registerFonts()
        let metrics = StarMetrics(space: .standard, container: CGSize(width: 1280, height: 960))
        for theme in AdCard.Theme.allCases {
            let card = AdCard(
                id: "c", business: "Gulf Coast Marine", headline: "Boat Repair & Detailing",
                lines: ["Outboards serviced", "Free estimates", "Pickup and delivery"],
                phone: "555-0142", footer: "Open 7 days on Bayshore Blvd", theme: theme
            )
            let view = AdCardScreen(card: card, image: nil)
                .environment(\.starMetrics, metrics)
                .environment(\.starContentWidth, 640)
                .frame(width: metrics.scaledSize.width, height: metrics.scaledSize.height)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = try #require(renderer.cgImage, "\(theme) did not render")
            let directory = URL(fileURLWithPath: "/tmp/ws4k-snapshots")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let destination = CGImageDestinationCreateWithURL(
                directory.appendingPathComponent("ad-card-\(theme.rawValue).png") as CFURL, "public.png" as CFString, 1, nil
            ) {
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
            }
        }
    }
    #endif
}

@Suite("Clip reel")
struct ClipReelTests {
    @Test("The music steps back while a clip plays, and only then")
    func musicGate() {
        #expect(MusicGate.shouldPlay(musicEnabled: true, isSetOn: true, clipPlaying: false))
        #expect(!MusicGate.shouldPlay(musicEnabled: true, isSetOn: true, clipPlaying: true))
        #expect(!MusicGate.shouldPlay(musicEnabled: false, isSetOn: true, clipPlaying: false))
    }

    @Test("Cards and clips take turns when both are on")
    func breaksTakeTurns() {
        #expect(AdBreaks.nextKind(cardsAvailable: true, clipsAvailable: true, last: nil) == .card)
        #expect(AdBreaks.nextKind(cardsAvailable: true, clipsAvailable: true, last: .card) == .clip)
        #expect(AdBreaks.nextKind(cardsAvailable: true, clipsAvailable: true, last: .clip) == .card)
        #expect(AdBreaks.nextKind(cardsAvailable: false, clipsAvailable: true, last: .clip) == .clip)
        #expect(AdBreaks.nextKind(cardsAvailable: true, clipsAvailable: false, last: .card) == .card)
        #expect(AdBreaks.nextKind(cardsAvailable: false, clipsAvailable: false, last: nil) == nil)
    }
}
