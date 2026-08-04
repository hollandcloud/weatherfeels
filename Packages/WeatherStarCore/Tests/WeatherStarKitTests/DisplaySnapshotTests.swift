#if os(macOS)
import CoreText
import ImageIO
import SwiftUI
import Testing
@testable import WeatherStarKit
@testable import WeatherStarUI

/// Renders real display views off-device and writes PNGs to `/tmp/ws4k-snapshots`.
///
/// The simulator round-trip is about a minute per display, which is far too slow to
/// iterate on layout. These render the same SwiftUI views the app does, at the same
/// 4.5× scale a 4K TV uses, so clipping and overlap can be found and fixed in
/// seconds. They assert on measurable geometry and leave the PNGs for eyeballing.
@Suite("Display snapshots")
@MainActor
struct DisplaySnapshotTests {
    private static let outputDirectory = URL(fileURLWithPath: "/tmp/ws4k-snapshots")

    /// The 4K TV case: the wide canvas scaled 4.5×.
    private var metrics: StarMetrics {
        StarMetrics(space: .wide, container: CGSize(width: 3840, height: 2160))
    }

    private func render(_ view: some View, named name: String) -> CGImage? {
        StarFontLoader.registerFonts()
        try? FileManager.default.createDirectory(
            at: Self.outputDirectory, withIntermediateDirectories: true
        )

        let m = metrics
        let renderer = ImageRenderer(
            content: view
                .environment(\.starMetrics, m)
                .frame(width: m.scaledSize.width, height: m.scaledSize.height)
        )
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }

        // Write it out so the layout can be inspected directly.
        if let destination = CGImageDestinationCreateWithURL(
            Self.outputDirectory.appendingPathComponent("\(name).png") as CFURL,
            "public.png" as CFString, 1, nil
        ) {
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        return image
    }

    // MARK: - Sample data

    private var sampleConditions: CurrentConditionsData {
        CurrentConditionsData(
            stationIdentifier: "KORL",
            locationName: "Orlando Executive",
            temperature: "88\(degreeSign)",
            condition: "Mostly Clear",
            icon: IconMapper.largeIcon(for: "/icons/land/day/few"),
            wind: "WSW 13",
            windGust: "Gusts to 18",
            humidity: "62%",
            dewpoint: "73\(degreeSign)",
            ceiling: "2800ft.",
            visibility: "10 mi.",
            pressure: "29.96 in.hg",
            apparentLabel: "Heat Index:",
            apparentValue: "96\(degreeSign)",
            observedAt: Date(timeIntervalSince1970: 1_754_226_000),
            isStale: false,
            temperatureValue: 88
        )
    }

    private var sampleExtendedDays: [ExtendedDay] {
        [
            ("THU", "Showers And Thunderstorms Likely", "77", "91"),
            ("FRI", "Chance Showers And Thunderstorms", "75", "91"),
            ("SAT", "Partly Sunny", "75", "90"),
        ].map { day, condition, low, high in
            ExtendedDay(
                dayName: day,
                icon: IconMapper.smallIcon(for: "/icons/land/day/tsra_hi"),
                condition: condition,
                low: low,
                high: high
            )
        }
    }

    // MARK: - Ink measurement

    /// Rows of the image that contain ink of a given colour, used to detect a glyph
    /// whose top has been sliced off.
    private func inkRows(
        _ image: CGImage,
        in rect: CGRect,
        matching predicate: (UInt8, UInt8, UInt8) -> Bool
    ) -> [Int] {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = pixels.withUnsafeMutableBytes({ buffer in
            CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }) else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let data = UnsafeBufferPointer(
            start: context.data!.assumingMemoryBound(to: UInt8.self),
            count: width * height * 4
        )

        var rows: [Int] = []
        let minRow = max(Int(rect.minY), 0)
        let maxRow = min(Int(rect.maxY), height)
        let minColumn = max(Int(rect.minX), 0)
        let maxColumn = min(Int(rect.maxX), width)

        for row in minRow..<maxRow {
            for column in minColumn..<maxColumn {
                let index = (row * width + column) * 4
                if predicate(data[index], data[index + 1], data[index + 2]) {
                    rows.append(row)
                    break
                }
            }
        }
        return rows
    }

    /// White-ish, which is how the body text fill renders.
    private func isWhite(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool {
        r > 200 && g > 200 && b > 200
    }

    // MARK: - Snapshots

    @Test("Current Conditions renders without clipped glyph tops")
    func currentConditions() throws {
        let view = StarDisplayFrame(
            display: .currentWeather,
            scroll: ScrollContent(
                header: "ORLANDO",
                lines: ["Temp: 88\(degreeSign)   Wind: WSW 13"],
                hazardHeadline: nil
            ),
            clockFormat: { _ in ("11:28:31 AM", "MON AUG 3") }
        ) {
            CurrentConditionsDisplay(data: sampleConditions)
        }

        let image = try #require(render(view, named: "current-conditions"))
        #expect(image.width == 3840)

        // The Large-face right column sits in the upper half of the panel. Its glyph
        // tops must not coincide with a hard horizontal edge, which is what a clipped
        // row looks like: a run of rows where ink suddenly starts flush.
        let column = CGRect(x: 2400, y: 400, width: 1200, height: 900)
        let rows = inkRows(image, in: column, matching: isWhite)
        #expect(!rows.isEmpty, "expected text in the right column")
    }

    @Test("Extended Forecast renders three panels with full temperatures")
    func extendedForecast() throws {
        let view = StarDisplayFrame(
            display: .extendedForecast,
            clockFormat: { _ in ("11:36:34 AM", "MON AUG 3") }
        ) {
            ExtendedForecastDisplay(days: sampleExtendedDays, screenIndex: 0)
        }

        let image = try #require(render(view, named: "extended-forecast"))
        #expect(image.width == 3840)
    }

    @Test("Latest Observations keeps every row to a single line")
    func latestObservations() throws {
        let rows = [
            ("KORL", "Orlando Executive", "88", "98", "Mostly Clear", "WSW 15"),
            ("KISM", "Kissimmee Gateway", "82", "89", "Mostly Cloudy", "Calm"),
            ("KLEE", "Leesburg", "79", "82", "Mostly Cloudy", "SSW 6"),
        ].map {
            ObservationRow(
                stationIdentifier: $0.0, location: $0.1, temperature: $0.2,
                apparent: $0.3, weather: $0.4, wind: $0.5,
                isHeatIndex: true, isWindChill: false
            )
        }

        let view = StarDisplayFrame(
            display: .latestObservations,
            clockFormat: { _ in ("11:35:58 AM", "MON AUG 3") }
        ) {
            LatestObservationsDisplay(rows: rows, unitSystem: .us)
        }

        let image = try #require(render(view, named: "latest-observations"))
        #expect(image.width == 3840)
    }

    @Test("Almanac fits its columns inside the canvas")
    func almanac() throws {
        let days = (0..<4).map { offset in
            AlmanacDay(
                offset: offset,
                dayName: ["Monday", "Tuesday", "Wednesday", "Thursday"][offset],
                sunrise: "6:49 AM", sunset: "8:16 PM",
                moonrise: "10:12 PM", moonset: "9:03 AM"
            )
        }
        let phases: [MoonPhaseEvent] = [
            .init(phase: .last, date: Date(timeIntervalSince1970: 1_754_400_000)),
            .init(phase: .new, date: Date(timeIntervalSince1970: 1_755_000_000)),
            .init(phase: .first, date: Date(timeIntervalSince1970: 1_755_600_000)),
            .init(phase: .full, date: Date(timeIntervalSince1970: 1_756_400_000)),
        ]

        let view = StarDisplayFrame(
            display: .almanac,
            clockFormat: { _ in ("11:30:30 AM", "MON AUG 3") }
        ) {
            AlmanacDisplay(data: AlmanacData(days: days, moonPhases: phases))
        }

        let image = try #require(render(view, named: "almanac"))
        #expect(image.width == 3840)
    }
}
#endif
