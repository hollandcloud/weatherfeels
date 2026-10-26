import CoreGraphics
import Foundation
import Testing
@testable import WeatherStarKit

@Suite("Icon mapping")
struct IconMapperTests {
    @Test("A day icon URL parses into condition and time of day")
    func parseDayIcon() {
        let parsed = ParsedIcon(iconURL: "https://api.weather.gov/icons/land/day/skc?size=medium")
        #expect(parsed?.condition == "skc")
        #expect(parsed?.isNight == false)
        #expect(parsed?.probability == 100)
    }

    @Test("A night icon URL is recognised as night")
    func parseNightIcon() {
        let parsed = ParsedIcon(iconURL: "/icons/land/night/skc?size=medium")
        #expect(parsed?.isNight == true)
    }

    @Test("A probability suffix is extracted")
    func parseProbability() {
        let parsed = ParsedIcon(iconURL: "/icons/land/day/snow,70?size=medium")
        #expect(parsed?.condition == "snow")
        #expect(parsed?.probability == 70)
    }

    @Test("With two conditions the second is used, as upstream does")
    func parseDualCondition() {
        let parsed = ParsedIcon(iconURL: "/icons/land/day/tsra_hi,30/rain,50?size=medium")
        #expect(parsed?.condition == "rain")
        #expect(parsed?.probability == 50)
    }

    @Test("Two identical conditions collapse to the first")
    func parseDuplicateCondition() {
        let parsed = ParsedIcon(iconURL: "/icons/land/day/rain,30/rain,50")
        #expect(parsed?.condition == "rain")
        #expect(parsed?.probability == 30)
    }

    @Test("An unparseable URL yields nil rather than a wrong icon")
    func parseGarbage() {
        #expect(ParsedIcon(iconURL: "https://example.com/nope.png") == nil)
        #expect(ParsedIcon(iconURL: "") == nil)
    }

    @Test("Clear skies map to Sunny by day and Clear by night")
    func largeIconDayNight() {
        #expect(IconMapper.largeIcon(for: "/icons/land/day/skc").fileName == "Sunny.gif")
        #expect(IconMapper.largeIcon(for: "/icons/land/night/skc").fileName == "Clear.gif")
    }

    @Test("Snow chance selects heavy versus light artwork")
    func largeIconSnowProbability() {
        #expect(IconMapper.largeIcon(for: "/icons/land/day/snow,80").fileName == "Heavy-Snow.gif")
        #expect(IconMapper.largeIcon(for: "/icons/land/day/snow,20").fileName == "Light-Snow.gif")
    }

    @Test("An unknown condition falls back to No-Data instead of crashing")
    func largeIconFallback() {
        #expect(IconMapper.largeIcon(for: "/icons/land/day/qqq").fileName == "No-Data.gif")
        #expect(IconMapper.largeIcon(for: nil).fileName == "No-Data.gif")
    }

    @Test("Small icons use the regional-map set")
    func smallIconSet() {
        let icon = IconMapper.smallIcon(for: "/icons/land/day/skc")
        #expect(icon.fileName == "Sunny.gif")
        #expect(icon.set == .regionalMap)
    }

    @Test("Hourly icons rank hazards above cloud cover")
    func hourlyIconPrecedence() {
        // Ice wins over everything else.
        #expect(
            IconMapper.hourlyIcon(
                skyCover: 10, weatherPhenomena: [], iceAccumulation: 1,
                probabilityOfPrecipitation: 0, snowfallAmount: 0, windSpeed: 0
            ).fileName == "Freezing-Rain-1992.gif"
        )
        // Heavy snow plus wind becomes blowing snow.
        #expect(
            IconMapper.hourlyIcon(
                skyCover: 100, weatherPhenomena: [], iceAccumulation: 0,
                probabilityOfPrecipitation: 100, snowfallAmount: 20, windSpeed: 40
            ).fileName == "Blowing-Snow.gif"
        )
        // Thunder over snow is a distinct icon.
        #expect(
            IconMapper.hourlyIcon(
                skyCover: 100, weatherPhenomena: ["Thunderstorms", "Snow"],
                iceAccumulation: 0, probabilityOfPrecipitation: 90,
                snowfallAmount: 2, windSpeed: 5
            ).fileName == "ThunderSnow.gif"
        )
        // Clear night versus clear day.
        #expect(
            IconMapper.hourlyIcon(
                skyCover: 5, weatherPhenomena: [], iceAccumulation: 0,
                probabilityOfPrecipitation: 0, snowfallAmount: 0, windSpeed: 0,
                isNight: true
            ).fileName == "Clear-1992.gif"
        )
    }

    @Test("Every mapped icon exists in the bundle")
    func mappedIconsResolve() {
        // Guards against a typo in the mapping tables shipping a missing asset.
        let conditions = [
            "skc", "few", "sct", "bkn", "ovc", "fog", "rain", "snow", "sleet",
            "fzra", "rain_snow", "snow_sleet", "tsra", "tsra_hi", "wind_skc",
            "blizzard", "haze", "hot", "cold", "smoke", "dust", "rain_showers",
        ]
        for condition in conditions {
            for timeOfDay in ["day", "night"] {
                let url = "/icons/land/\(timeOfDay)/\(condition)"
                let large = IconMapper.largeIcon(for: url)
                let small = IconMapper.smallIcon(for: url)
                #expect(large.url != nil, "missing large icon \(large.fileName) for \(url)")
                #expect(small.url != nil, "missing small icon \(small.fileName) for \(url)")
            }
        }
    }

    @Test("All four moon phase icons exist")
    func moonIconsResolve() {
        for phase in MoonPhase.allCases {
            #expect(IconMapper.moonIcon(for: phase).url != nil, "missing \(phase.rawValue)")
        }
    }
}

@Suite("METAR parsing")
struct METARTests
{
    /// A representative report: wind, visibility, ceiling, temps and altimeter.
    private let sample = "KMCO 031253Z 09008KT 10SM BKN035 28/23 A3005 RMK AO2 SLP172"

    @Test("Wind direction and speed are converted to km/h")
    func wind() {
        let report = METARParser.parse(sample)
        #expect(report.windDirection == 90)
        // 8 knots is about 14.8 km/h.
        #expect(report.windSpeed.map { abs($0 - 14.8) < 0.2 } == true)
    }

    @Test("Gusts are parsed when present")
    func gusts() {
        let report = METARParser.parse("KMCO 031253Z 27015G25KT 10SM CLR 28/23 A3005")
        #expect(report.windGust.map { abs($0 - 46.3) < 0.5 } == true)
    }

    @Test("Variable wind has no direction but still has a speed")
    func variableWind() {
        let report = METARParser.parse("KMCO 031253Z VRB03KT 10SM CLR 28/23 A3005")
        #expect(report.windDirection == nil)
        #expect(report.windSpeed != nil)
    }

    @Test("Visibility in statute miles converts to metres")
    func visibility() {
        let report = METARParser.parse(sample)
        #expect(report.visibility.map { abs($0 - 16093.4) < 1 } == true)
    }

    @Test("Fractional visibility is handled")
    func fractionalVisibility() {
        let report = METARParser.parse("KMCO 031253Z 09008KT 1/2SM FG 20/20 A3005")
        #expect(report.visibility.map { abs($0 - 804.67) < 1 } == true)
    }

    @Test("Temperature and dewpoint are read, including negatives")
    func temperatures() {
        #expect(METARParser.parse(sample).temperature == 28)
        #expect(METARParser.parse(sample).dewpoint == 23)

        let cold = METARParser.parse("KORD 031253Z 27015KT 10SM CLR M05/M09 A3005")
        #expect(cold.temperature == -5)
        #expect(cold.dewpoint == -9)
    }

    @Test("The altimeter setting converts to pascals")
    func altimeter() {
        // 30.05 inHg is about 101,760 Pa.
        let report = METARParser.parse(sample)
        #expect(report.barometricPressure.map { abs($0 - 101_761) < 50 } == true)

        // The metric Q form is hectopascals.
        let metric = METARParser.parse("EGLL 031250Z 27015KT 9999 BKN020 15/10 Q1013")
        #expect(metric.barometricPressure == 101_300)
    }

    @Test("A broken layer defines the ceiling")
    func ceiling() {
        // BKN035 is 3,500 ft, about 1,067 m.
        let report = METARParser.parse(sample)
        #expect(report.ceiling.map { abs($0 - 1066.8) < 1 } == true)
    }

    @Test("The lowest broken or overcast layer wins")
    func lowestCeiling() {
        let report = METARParser.parse("KMCO 031253Z 09008KT 10SM BKN035 OVC012 28/23 A3005")
        #expect(report.ceiling.map { abs($0 - 365.76) < 1 } == true)
    }

    @Test("Relative humidity is derived from temperature and dewpoint")
    func humidity() {
        let report = METARParser.parse(sample)
        // 28/23 is roughly 74%.
        #expect(report.relativeHumidity.map { $0 > 70 && $0 < 80 } == true)

        // Equal temperature and dewpoint means saturation.
        let saturated = METARParser.parse("KMCO 031253Z 09008KT 1/2SM FG 20/20 A3005")
        #expect(saturated.relativeHumidity.map { abs($0 - 100) < 0.5 } == true)
    }

    @Test("Remarks after RMK are ignored")
    func ignoresRemarks() {
        // SLP172 in the remarks must not be mistaken for a pressure group.
        let report = METARParser.parse(sample)
        #expect(report.barometricPressure.map { $0 > 100_000 } == true)
    }

    @Test("Garbage input yields empty fields rather than throwing")
    func garbage() {
        let report = METARParser.parse("not a metar at all")
        #expect(report.temperature == nil)
        #expect(report.windSpeed == nil)
    }

    @Test("Augmenting only fills gaps and never overwrites API data")
    func augmentPreservesExistingValues() {
        var observation = WeatherObservation()
        observation.rawMessage = sample
        // The API supplied a temperature but no dewpoint.
        observation.temperature = QuantitativeValue(value: 30)
        observation.dewpoint = QuantitativeValue(value: nil)

        let augmented = observation.augmentedWithMETAR()
        #expect(augmented.temperature?.value == 30, "API value must win")
        #expect(augmented.dewpoint?.value == 23, "gap must be filled from METAR")
        #expect(augmented.ceiling?.value != nil)
    }

    @Test("An observation with no raw message is returned unchanged")
    func augmentWithoutRawMessage() {
        var observation = WeatherObservation()
        observation.temperature = QuantitativeValue(value: nil)
        #expect(observation.augmentedWithMETAR().temperature?.value == nil)
    }
}

@Suite("Astronomy")
struct AstronomyTests {
    /// Orlando, and a date with a known sunrise/sunset.
    private let latitude = 28.5383
    private let longitude = -81.3792

    @Test("Sunrise precedes sunset and both fall on the right day")
    func sunTimesOrdering() {
        let date = Date(timeIntervalSince1970: 1_722_681_600)  // 2024-08-03 12:00 UTC
        let times = SunCalc.sunTimes(date: date, latitude: latitude, longitude: longitude)

        guard let sunrise = times.sunrise, let sunset = times.sunset,
              let noon = times.solarNoon
        else {
            Issue.record("Expected sun times at this latitude")
            return
        }

        #expect(sunrise < noon)
        #expect(noon < sunset)
        // An early-August day in Florida runs about 13.5 hours.
        let dayLength = sunset.timeIntervalSince(sunrise) / 3600
        #expect(dayLength > 13 && dayLength < 14)
    }

    @Test("Polar night has no sunrise, and the display shows a dash")
    func polarNight() {
        // Northern Greenland in December: the sun never rises.
        let december = Date(timeIntervalSince1970: 1_734_350_400)  // 2024-12-16
        let times = SunCalc.sunTimes(date: december, latitude: 82.5, longitude: -62.3)
        #expect(times.sunrise == nil)
        #expect(times.sunset == nil)
    }

    @Test("Moon illumination stays in range and the phase advances")
    func moonIllumination() {
        let date = Date(timeIntervalSince1970: 1_722_681_600)
        let now = SunCalc.moonIllumination(date: date)
        #expect(now.fraction >= 0 && now.fraction <= 1)
        #expect(now.phase >= 0 && now.phase <= 1)

        // A week later the phase has moved on (the cycle is ~29.5 days).
        let later = SunCalc.moonIllumination(date: date.addingTimeInterval(7 * 86400))
        #expect(abs(later.phase - now.phase) > 0.1)
    }

    @Test("Upcoming phases are ordered, in the future, and distinct")
    func upcomingPhases() {
        let reference = Date(timeIntervalSince1970: 1_722_681_600)
        let events = MoonPhase.upcoming(from: reference, count: 4)

        #expect(events.count == 4)
        #expect(events == events.sorted { $0.date < $1.date }, "must be chronological")

        // All within the scan window, and none before the day before the reference.
        for event in events {
            #expect(event.date > reference.addingTimeInterval(-2 * 86400))
            #expect(event.date < reference.addingTimeInterval(50 * 86400))
        }

        // Consecutive principal phases are about a quarter cycle (~7.4 days) apart.
        for (earlier, later) in zip(events, events.dropFirst()) {
            let days = later.date.timeIntervalSince(earlier.date) / 86400
            #expect(days > 5 && days < 10, "quarter-phase spacing, got \(days) days")
        }
    }

    @Test("Moonrise and moonset land inside the requested day")
    func moonTimes() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let date = Date(timeIntervalSince1970: 1_722_681_600)
        let times = SunCalc.moonTimes(
            date: date,
            latitude: latitude,
            longitude: longitude,
            timeZone: calendar.timeZone
        )

        // The moon does not always both rise and set within one calendar day, but at
        // this latitude at least one event must occur.
        #expect(times.rise != nil || times.set != nil)
        let start = calendar.startOfDay(for: date)
        for event in [times.rise, times.set].compactMap({ $0 }) {
            #expect(event >= start)
            #expect(event < start.addingTimeInterval(26 * 3600))
        }
    }
}

@Suite("Bundled data")
struct BundledDataTests {
    @Test("The generated station table loads")
    func stationsLoad() {
        #expect(!BundledData.stations.isEmpty)
        // A well-known station, with the curated city name upstream provides.
        #expect(BundledData.cityName(forStation: "KMCO") != nil)
    }

    @Test("Travel cities load with grid points")
    func travelCitiesLoad() {
        let cities = BundledData.travelCities
        #expect(!cities.isEmpty)
        #expect(cities.contains { $0.name == "Atlanta" })
        #expect(cities.allSatisfy { $0.point != nil })
    }

    @Test("Regional cities load, including string-encoded coordinates")
    func regionalCitiesLoad() {
        let cities = BundledData.regionalCities
        #expect(!cities.isEmpty)
        // The generated table stores these as strings; decoding must cope.
        #expect(cities.allSatisfy { $0.latitude != 0 && $0.longitude != 0 })
    }

    @Test("Nearest regional cities are returned closest first")
    func nearestRegionalCities() {
        // Orlando: the nearest listed cities should be central Florida.
        let nearby = BundledData.regionalCities(near: 28.5383, longitude: -81.3792, limit: 5)
        #expect(nearby.count == 5)

        let distances = nearby.map {
            Calc.haversineKilometers(
                lat1: 28.5383, lon1: -81.3792, lat2: $0.latitude, lon2: $0.longitude
            )
        }
        #expect(distances == distances.sorted(), "must be nearest-first")
    }
}

@Suite("Observation backfill")
struct BackfillTests {
    private func observation(
        timestamp: Date,
        temperature: Double?,
        dewpoint: Double? = nil,
        pressure: Double? = nil,
        description: String? = nil
    ) -> ObservationFeature {
        var value = WeatherObservation()
        value.timestamp = timestamp
        value.temperature = QuantitativeValue(value: temperature)
        value.dewpoint = QuantitativeValue(value: dewpoint)
        value.barometricPressure = QuantitativeValue(value: pressure)
        value.textDescription = description
        return ObservationFeature(properties: value)
    }

    @Test("The newest reading wins, with gaps filled from older ones")
    func backfillPrefersNewest() {
        let now = Date()
        let features = [
            observation(timestamp: now, temperature: 25, dewpoint: nil, description: "Clear"),
            observation(timestamp: now.addingTimeInterval(-3600), temperature: 20, dewpoint: 18),
            observation(timestamp: now.addingTimeInterval(-7200), temperature: 15, pressure: 101_300),
        ]

        let merged = WeatherStore.backfill(features)
        #expect(merged.temperature?.value == 25, "newest temperature")
        #expect(merged.dewpoint?.value == 18, "dewpoint from an hour ago")
        #expect(merged.barometricPressure?.value == 101_300, "pressure from two hours ago")
        #expect(merged.textDescription == "Clear")
    }

    @Test("Out-of-order input is sorted before merging")
    func backfillSortsByTimestamp() {
        let now = Date()
        let features = [
            observation(timestamp: now.addingTimeInterval(-7200), temperature: 15),
            observation(timestamp: now, temperature: 25),
            observation(timestamp: now.addingTimeInterval(-3600), temperature: 20),
        ]
        #expect(WeatherStore.backfill(features).temperature?.value == 25)
    }

    @Test("An empty series yields an empty observation rather than crashing")
    func backfillEmpty() {
        #expect(WeatherStore.backfill([]).temperature?.value == nil)
    }
}

@Suite("Forecast text handling")
struct ForecastTextTests {
    @Test("Sky cover is classified from the forecast icon's cover token")
    func skyCoverFromIcon() {
        #expect(WeatherStore.skyCover(fromIcon: "/icons/land/day/skc") == 0)
        #expect(WeatherStore.skyCover(fromIcon: "/icons/land/day/few") == 20)
        #expect(WeatherStore.skyCover(fromIcon: "/icons/land/day/sct") == 40)
        #expect(WeatherStore.skyCover(fromIcon: "/icons/land/day/bkn") == 70)
        #expect(WeatherStore.skyCover(fromIcon: "/icons/land/day/ovc") == 100)
        // A wind_ prefix qualifies the cover rather than replacing it.
        #expect(WeatherStore.skyCover(fromIcon: "/icons/land/day/wind_bkn") == 70)
        #expect(WeatherStore.skyCover(fromIcon: nil) == nil)
    }
}

@Suite("SPC point-in-polygon")
struct SPCGeometryTests {
    /// A unit square around the origin.
    private let square: [(longitude: Double, latitude: Double)] = [
        (-1, -1), (1, -1), (1, 1), (-1, 1), (-1, -1),
    ]

    @Test("A point inside a simple polygon is detected")
    func insideSquare() {
        #expect(SPCOutlookService.contains(latitude: 0, longitude: 0, rings: [square]))
    }

    @Test("A point outside is rejected")
    func outsideSquare() {
        #expect(!SPCOutlookService.contains(latitude: 5, longitude: 5, rings: [square]))
        #expect(!SPCOutlookService.contains(latitude: 0, longitude: 2, rings: [square]))
    }

    @Test("A point inside a hole counts as outside")
    func insideHole() {
        let hole: [(longitude: Double, latitude: Double)] = [
            (-0.5, -0.5), (0.5, -0.5), (0.5, 0.5), (-0.5, 0.5), (-0.5, -0.5),
        ]
        // Inside the outer ring and inside the hole: excluded.
        #expect(!SPCOutlookService.contains(latitude: 0, longitude: 0, rings: [square, hole]))
        // Inside the outer ring but outside the hole: included.
        #expect(SPCOutlookService.contains(latitude: 0.75, longitude: 0, rings: [square, hole]))
    }

    @Test("A degenerate ring is rejected rather than trapping")
    func degenerateRing() {
        #expect(!SPCOutlookService.contains(latitude: 0, longitude: 0, rings: [[(0, 0), (1, 1)]]))
        #expect(!SPCOutlookService.contains(latitude: 0, longitude: 0, rings: []))
    }
}

/// The radar window must be centred on the viewer, at the same scale everywhere.
///
/// The suite this replaced checked the projection against itself, which is how a window
/// actually cut from 290 km away passed it for months. The window is now a box of coordinates
/// that the server draws the radar into, so these check the box — and that the request carries
/// it — rather than any projection of ours.
@Suite("Radar framing")
struct RadarFramingTests {
    private static let places: [(name: String, latitude: Double, longitude: Double)] = [
        ("Tampa FL", 27.9506, -82.4572),
        ("Seattle WA", 47.6062, -122.3321),
        ("Chicago IL", 41.8781, -87.6298),
        ("Denver CO", 39.7392, -104.9903),
        ("Bangor ME", 44.8016, -68.7712),
    ]

    /// Great-circle distance, independent of anything in the app.
    private func kilometres(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let radians = Double.pi / 180
        let dLat = (lat2 - lat1) * radians
        let dLon = (lon2 - lon1) * radians
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * radians) * cos(lat2 * radians) * sin(dLon / 2) * sin(dLon / 2)
        return 6371 * 2 * atan2(a.squareRoot(), (1 - a).squareRoot())
    }

    @Test("The location is the centre of its radar window")
    func locationIsCentred() {
        for place in Self.places {
            let bounds = RadarService.bounds(latitude: place.latitude, longitude: place.longitude)
            #expect(abs((bounds.minLatitude + bounds.maxLatitude) / 2 - place.latitude) < 1e-9, "\(place.name)")
            #expect(abs((bounds.minLongitude + bounds.maxLongitude) / 2 - place.longitude) < 1e-9, "\(place.name)")
        }
    }

    /// A fixed span in degrees would show a wider area of Washington than of Florida. The
    /// window is widened by latitude so it covers the same ground everywhere — checked here
    /// with a great-circle distance, not with the formula that produced it.
    @Test("The window spans the same ground at every latitude")
    func sameGroundEverywhere() {
        for place in Self.places {
            let bounds = RadarService.bounds(latitude: place.latitude, longitude: place.longitude)
            let across = kilometres(place.latitude, bounds.minLongitude, place.latitude, bounds.maxLongitude)
            let down = kilometres(bounds.minLatitude, place.longitude, bounds.maxLatitude, place.longitude)
            #expect(abs(across - RadarService.windowWidthKilometres) < 15, "\(place.name): \(Int(across)) km across")
            let expectedDown = RadarService.windowWidthKilometres
                * RadarService.imageSize.height / RadarService.imageSize.width
            #expect(abs(down - expectedDown) < 10, "\(place.name): \(Int(down)) km down")
        }
    }

    /// The server georeferences the frame by the box in the request, so the request carrying
    /// exactly the window's coordinates is what puts the location in the middle of the image.
    @Test("Each frame is requested for exactly the window")
    func requestCarriesTheWindow() throws {
        let bounds = RadarService.bounds(latitude: 27.9506, longitude: -82.4572)
        let time = Date(timeIntervalSince1970: 1_793_030_100)
        let url = try #require(RadarService.frameURL(bounds: bounds, time: time))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        #expect(url.host == "mesonet.agron.iastate.edu")
        #expect(value("SRS") == "EPSG:4326")
        #expect(value("LAYERS") == "nexrad-n0q-wmst")
        #expect(value("WIDTH") == "854")
        #expect(value("HEIGHT") == "367")
        #expect(value("TIME") == "2026-10-26T15:55:00Z")

        let box = try #require(value("BBOX")).split(separator: ",").compactMap { Double($0) }
        #expect(box.count == 4)
        #expect(abs(box[0] - bounds.minLongitude) < 0.001)
        #expect(abs(box[1] - bounds.minLatitude) < 0.001)
        #expect(abs(box[2] - bounds.maxLongitude) < 0.001)
        #expect(abs(box[3] - bounds.maxLatitude) < 0.001)
    }

    /// The composite is the lower 48 only. Before, a location outside it was clamped to the
    /// nearest corner and shown somebody else's weather.
    @Test("Places the composite does not cover get no radar")
    func outsideCoverageHasNoFrames() async throws {
        #expect(!RadarService.covers(latitude: 21.3069, longitude: -157.8583))
        #expect(!RadarService.covers(latitude: 61.2181, longitude: -149.9003))
        #expect(RadarService.covers(latitude: 44.8016, longitude: -68.7712))
        let frames = try await RadarService().frames(latitude: 21.3069, longitude: -157.8583)
        #expect(frames.isEmpty)
    }

    @Test("Frame times fall on the composite's five-minute marks")
    func framesOnFiveMinuteMarks() {
        let date = Date(timeIntervalSince1970: 1_793_030_399)
        #expect(RadarService.roundedDown(date).timeIntervalSince1970 == 1_793_030_100)
    }
}

@Suite("Radar colours")
struct RadarColourTests {
    @Test("Every reflectivity has its own colour in IEM's table")
    func nexradPaletteIsDistinct() {
        #expect(NEXRADPalette.colours.count == 256)
        #expect(Set(NEXRADPalette.colours).count == 256)
        // Index 0 is no data, so it carries no reflectivity.
        #expect(NEXRADPalette.reflectivity[NEXRADPalette.colours[0]] == nil)
        #expect(NEXRADPalette.reflectivity[NEXRADPalette.colours[104]] == 20)
        #expect(NEXRADPalette.reflectivity[NEXRADPalette.colours[255]] == 95.5)
    }

    @Test("Reflectivity maps onto the WeatherStar bands")
    func weatherStarBands() {
        #expect(RadarService.weatherStarColour(dBZ: 19.5).3 == 0)
        #expect(RadarService.weatherStarColour(dBZ: 20) == (49, 210, 22, 255))
        #expect(RadarService.weatherStarColour(dBZ: 43) == (196, 179, 70, 255))
        #expect(RadarService.weatherStarColour(dBZ: 55) == (171, 14, 14, 255))
        #expect(RadarService.weatherStarColour(dBZ: 70) == (115, 31, 4, 255))
    }

    /// One pixel of each kind: no data, a 43 dBZ echo, and a colour not in IEM's table.
    private func image(_ pixels: [(UInt8, UInt8, UInt8, UInt8)]) -> CGImage {
        var bytes = pixels.flatMap { [$0.0, $0.1, $0.2, $0.3] }
        return bytes.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: pixels.count, height: 1,
                bitsPerComponent: 8, bytesPerRow: pixels.count * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!.makeImage()!
        }
    }

    private func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    @Test("Frames are recoloured by reflectivity, and unknown colours are dropped")
    func recolourByValue() throws {
        let echo = NEXRADPalette.colours[150]  // 43 dBZ
        let source = image([
            (0, 0, 0, 0),
            (UInt8(echo >> 16), UInt8((echo >> 8) & 0xFF), UInt8(echo & 0xFF), 255),
            (1, 2, 3, 255),
        ])
        let recoloured = try #require(RadarService.recolour(source))
        let bytes = rgba(recoloured)
        #expect(bytes[3] == 0)
        #expect(Array(bytes[4..<8]) == [196, 179, 70, 255])
        #expect(bytes[11] == 0)
    }

    /// The server answers a time it has no composite for with a blank image rather than an
    /// error, so a frame with nothing in it is treated as missing.
    @Test("A frame with no echoes is treated as missing")
    func blankFrameIsMissing() {
        #expect(RadarService.recolour(image([(0, 0, 0, 0), (1, 2, 3, 255)])) == nil)
    }
}

@Suite("Scroll ticker lines")
struct ScrollTickerTests {
    /// Values reach the ticker already formatted, units included. This mirrors what
    /// `buildCurrentConditions` produces for a station reporting everything.
    private func conditions(
        pressure: String = "30.09 in.hg",
        gust: String? = nil,
        apparent: (String, String)? = nil
    ) -> CurrentConditionsData {
        CurrentConditionsData(
            stationIdentifier: "KTPA",
            locationName: "Tampa",
            temperature: "86°",
            condition: "Clear",
            icon: WeatherIcon(fileName: "Sunny.gif", set: .currentConditions),
            wind: "Calm",
            windGust: gust,
            humidity: "80%",
            dewpoint: "79°",
            ceiling: "Unlimited",
            visibility: "9 mi.",
            pressure: pressure,
            apparentLabel: apparent?.0,
            apparentValue: apparent?.1,
            observedAt: nil,
            isStale: false,
            temperatureValue: 86
        )
    }

    @Test("The pressure line carries its unit exactly once")
    func pressureUnitIsNotDoubled() {
        let line = try! #require(
            WeatherStore.scrollLines(from: conditions())
                .first { $0.hasPrefix("Pressure:") }
        )
        #expect(line == "Pressure: 30.09 in.hg")
        // The original defect read "Pressure: 30.09 in.hg  in.hg" — the value already
        // ends in its unit, and the ticker appended the unit again.
        #expect(line.components(separatedBy: "in.hg").count - 1 == 1)
        #expect(!line.contains("  "), "no run of spaces from an empty trend suffix")
    }

    @Test("A station with no barometer contributes no pressure line")
    func pressureOmittedWhenMissing() {
        let lines = WeatherStore.scrollLines(from: conditions(pressure: "-"))
        #expect(!lines.contains { $0.hasPrefix("Pressure:") })
    }

    @Test("Optional readings appear only when present")
    func optionalLines() {
        let bare = WeatherStore.scrollLines(from: conditions())
        #expect(!bare.contains { $0.hasPrefix("Heat Index") })

        let full = WeatherStore.scrollLines(
            from: conditions(gust: "Gusts to 22", apparent: ("Heat Index:", "100°"))
        )
        #expect(full.contains("Gusts to 22"))
        #expect(full.contains("Heat Index: 100°"))
    }

    @Test("No conditions yields no lines rather than a header with nothing under it")
    func emptyWithoutConditions() {
        #expect(WeatherStore.scrollLines(from: nil).isEmpty)
    }

    /// The ticker viewport is about 34 characters at the design size; anything much
    /// longer scrolls, which is fine, but a *pair* on one line should still fit.
    @Test("Paired readings stay inside the ticker width")
    func pairedLinesFit() {
        for line in WeatherStore.scrollLines(from: conditions()) where line.contains("   ") {
            #expect(line.count <= 34, "\(line) is \(line.count) characters")
        }
    }
}
