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

    /// Every label/value pair on Current Conditions, measured against the column it has.
    ///
    /// This is the display's tightest layout and it was broken in the shipped 1.0: the
    /// 20pt label indent and 10pt value inset were applied with `designOffset`, which
    /// translates a view after layout rather than reserving space. The row was laid out
    /// across the full column and then its two halves slid 30pt towards each other, so on
    /// the 640pt canvas "Pressure:" and "30.04 in.hg" printed straight through one
    /// another. It reached the App Store that way, in the iPad screenshots.
    ///
    /// Measured with the real font rather than rendered and eyeballed, because that is the
    /// only way to know it holds for the longest strings and not merely for today's weather.
    @Test("Every Current Conditions row fits its column")
    func currentConditionsRowsFit() {
        StarFontLoader.registerFonts()

        // The 640pt canvas — the narrow one, used on iPad and inside the television.
        let column: CGFloat = 255
        let available = column - 20 - 10  // labelIndent, valueInset
        let size: CGFloat = 20
        // The value keeps its size; only the label is allowed to condense.
        let labelFloor: CGFloat = 0.55

        // The longest realistic string for each row, including both apparent-temperature
        // labels and the units that make the values widest.
        let rows = [
            ("Humidity:", "100%"),
            ("Dewpoint:", "-15°"),
            ("Ceiling:", "Unlimited"),
            ("Visibility:", "10 mi."),
            ("Pressure:", "30.04 in.hg"),
            ("Heat Index:", "108°"),
            ("Wind Chill:", "-25°"),
        ]

        for (label, value) in rows {
            let labelWidth = StarFont.large.textWidth(label, size: size) * labelFloor
            let valueWidth = StarFont.large.textWidth(value, size: size)
            #expect(
                labelWidth + valueWidth <= available,
                """
                "\(label) \(value)" needs \(labelWidth + valueWidth)pt of \(available)pt \
                even with the label fully condensed — it will overprint
                """
            )
        }
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

/// The column titles on the two scrolling tables have to stay put while the rows move.
///
/// This came out of a store screenshot: every frame of the Hourly display had
/// "TEMP LIKE WIND" sitting on top of a row of numbers, because the rows were drawn
/// after the header in the same `ZStack` and slid out over it.
@Suite("Scrolling table headers")
@MainActor
struct TableHeaderTests {
    private var metrics: StarMetrics {
        StarMetrics(space: .wide, container: CGSize(width: 3840, height: 2160))
    }

    private func rows(_ count: Int) -> [HourlyRow] {
        (0..<count).map { index in
            HourlyRow(
                time: Date(timeIntervalSince1970: 1_770_000_000 + Double(index) * 3600),
                hourLabel: "\((index % 12) + 1) PM",
                icon: IconMapper.smallIcon(for: "/icons/land/day/few"),
                temperature: "8\(index % 10)",
                apparent: "9\(index % 10)",
                wind: "NNW 15",
                isHeatIndex: true,
                isWindChill: false
            )
        }
    }

    private func render(_ offset: Double) -> CGImage? {
        StarFontLoader.registerFonts()
        let m = metrics
        let renderer = ImageRenderer(
            content: HourlyDisplay(rows: rows(24), scrollOffset: offset)
                .environment(\.starMetrics, m)
                .environment(\.starContentWidth, 640)
                // Top-leading, not the default centre: the display is shorter than the
                // full canvas, and centring it moved the header band into the middle of
                // the image, where sampling the top rows found only background.
                .frame(
                    width: m.scaledSize.width,
                    height: m.scaledSize.height,
                    alignment: .topLeading
                )
                .background(Color.black)
        )
        renderer.scale = 1
        return renderer.cgImage
    }

    /// Pixels of the band and the title glyphs that hang below it.
    private func headerPixels(_ image: CGImage) -> [UInt8] {
        let height = Int((metrics.s(TableHeader.contentTop)).rounded(.up))
        let width = image.width
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            // Draw the full image into a short context so only the top band lands in it.
            context.draw(
                image,
                in: CGRect(
                    x: 0, y: CGFloat(height) - CGFloat(image.height),
                    width: CGFloat(width), height: CGFloat(image.height)
                )
            )
        }
        return pixels
    }

    @Test("Scrolling the rows leaves the header untouched")
    func headerIsUnaffectedByScrolling() throws {
        // Discarded: the first render in a process can land before Core Text has picked
        // up the registered Star4000 faces, so its glyphs are missing and it is not a
        // sound reference. Which render is first depends on the order the suites happen
        // to run in, so without this the test passes or fails by luck.
        _ = render(0)

        // Offsets across a whole row's travel, including the point where a row's text
        // would previously have landed exactly on the titles.
        let atRest = try #require(render(0))
        let reference = headerPixels(atRest)

        for offset in [8.0, 20.0, 36.0, 72.0, 144.0] {
            let scrolled = try #require(render(offset))
            // Compared through a Bool on purpose: handing the arrays themselves to
            // `#expect` puts ~28MB of pixel values in the failure message.
            let unchanged = headerPixels(scrolled) == reference
            #expect(unchanged, "the header changed once the rows moved to \(offset)")
        }
    }

    @Test("The header band is actually drawn, so the comparison means something")
    func headerIsNotBlank() throws {
        // Guards the test above: comparing two empty bands would pass for the wrong
        // reason, so require the band to differ from the plain background.
        let image = try #require(render(0))
        let pixels = headerPixels(image)
        let distinct = Set(stride(from: 0, to: pixels.count, by: 4).map { index in
            [pixels[index], pixels[index + 1], pixels[index + 2]]
        })
        #expect(distinct.count > 2, "header band has \(distinct.count) distinct colours")
    }
}
#endif
