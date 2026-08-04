import Foundation

/// Sun and moon position/timing math, ported from the SunCalc library that
/// upstream bundles (github.com/mourner/suncalc, BSD-2-Clause).
///
/// Kept as a direct port rather than reaching for a system framework so the
/// Almanac display's sunrise/sunset/moon-phase values match ws4kp exactly.
public enum SunCalc {
    private static let rad = Double.pi / 180
    private static let dayMs: Double = 86_400_000
    private static let j1970: Double = 2_440_588
    private static let j2000: Double = 2_451_545
    /// Obliquity of the ecliptic.
    private static let e = rad * 23.4397

    // MARK: - Date/Julian conversion

    private static func toJulian(_ date: Date) -> Double {
        date.timeIntervalSince1970 * 1000 / dayMs - 0.5 + j1970
    }

    private static func fromJulian(_ j: Double) -> Date? {
        guard j.isFinite else { return nil }
        return Date(timeIntervalSince1970: (j + 0.5 - j1970) * dayMs / 1000)
    }

    private static func toDays(_ date: Date) -> Double {
        toJulian(date) - j2000
    }

    // MARK: - Celestial coordinates

    private static func rightAscension(_ l: Double, _ b: Double) -> Double {
        atan2(sin(l) * cos(e) - tan(b) * sin(e), cos(l))
    }

    private static func declination(_ l: Double, _ b: Double) -> Double {
        asin(sin(b) * cos(e) + cos(b) * sin(e) * sin(l))
    }

    private static func azimuth(_ H: Double, _ phi: Double, _ dec: Double) -> Double {
        atan2(sin(H), cos(H) * sin(phi) - tan(dec) * cos(phi))
    }

    private static func altitude(_ H: Double, _ phi: Double, _ dec: Double) -> Double {
        asin(sin(phi) * sin(dec) + cos(phi) * cos(dec) * cos(H))
    }

    private static func siderealTime(_ d: Double, _ lw: Double) -> Double {
        rad * (280.16 + 360.9856235 * d) - lw
    }

    /// Atmospheric refraction correction, which lifts the apparent moon slightly.
    private static func astroRefraction(_ h: Double) -> Double {
        let h = max(h, 0)
        return 0.000_296_7 / tan(h + 0.003_125_36 / (h + 0.089_011_79))
    }

    // MARK: - Sun

    private static func solarMeanAnomaly(_ d: Double) -> Double {
        rad * (357.5291 + 0.985_600_28 * d)
    }

    private static func eclipticLongitude(_ M: Double) -> Double {
        // Equation of the center plus the perihelion of Earth.
        let C = rad * (1.9148 * sin(M) + 0.02 * sin(2 * M) + 0.0003 * sin(3 * M))
        let P = rad * 102.9372
        return M + C + P + .pi
    }

    private static func sunCoords(_ d: Double) -> (declination: Double, rightAscension: Double) {
        let M = solarMeanAnomaly(d)
        let L = eclipticLongitude(M)
        return (declination(L, 0), rightAscension(L, 0))
    }

    public struct Position: Sendable {
        public let azimuth: Double
        public let altitude: Double
    }

    public static func sunPosition(date: Date, latitude: Double, longitude: Double) -> Position {
        let lw = rad * -longitude
        let phi = rad * latitude
        let d = toDays(date)
        let c = sunCoords(d)
        let H = siderealTime(d, lw) - c.rightAscension
        return Position(
            azimuth: azimuth(H, phi, c.declination),
            altitude: altitude(H, phi, c.declination)
        )
    }

    // MARK: - Sun times

    private static let j0 = 0.0009

    private static func julianCycle(_ d: Double, _ lw: Double) -> Double {
        (d - j0 - lw / (2 * .pi)).rounded()
    }

    private static func approxTransit(_ Ht: Double, _ lw: Double, _ n: Double) -> Double {
        j0 + (Ht + lw) / (2 * .pi) + n
    }

    private static func solarTransitJ(_ ds: Double, _ M: Double, _ L: Double) -> Double {
        j2000 + ds + 0.0053 * sin(M) - 0.0069 * sin(2 * L)
    }

    private static func hourAngle(_ h: Double, _ phi: Double, _ d: Double) -> Double {
        acos((sin(h) - sin(phi) * sin(d)) / (cos(phi) * cos(d)))
    }

    private static func observerAngle(_ height: Double) -> Double {
        -2.076 * height.squareRoot() / 60
    }

    private static func setJ(
        _ h: Double, _ lw: Double, _ phi: Double, _ dec: Double,
        _ n: Double, _ M: Double, _ L: Double
    ) -> Double {
        let w = hourAngle(h, phi, dec)
        let a = approxTransit(w, lw, n)
        return solarTransitJ(a, M, L)
    }

    /// Sun event times for a day. Any field is nil inside the polar day/night,
    /// where the sun never crosses that altitude — the display renders "-".
    public struct SunTimes: Sendable {
        public var solarNoon: Date?
        public var nadir: Date?
        public var sunrise: Date?
        public var sunset: Date?
        public var sunriseEnd: Date?
        public var sunsetStart: Date?
        public var dawn: Date?
        public var dusk: Date?
        public var nauticalDawn: Date?
        public var nauticalDusk: Date?
        public var nightEnd: Date?
        public var night: Date?
        public var goldenHourEnd: Date?
        public var goldenHour: Date?
    }

    /// Altitude in degrees paired with the rise/set event it defines.
    private struct SunEvent {
        let angle: Double
        let rise: WritableKeyPath<SunTimes, Date?>
        let set: WritableKeyPath<SunTimes, Date?>
    }

    public static func sunTimes(
        date: Date,
        latitude: Double,
        longitude: Double,
        height: Double = 0
    ) -> SunTimes {
        // Built locally rather than as a static: key paths are not Sendable, so a
        // shared mutable global would not be concurrency-safe.
        let sunEvents = [
            SunEvent(angle: -0.833, rise: \.sunrise, set: \.sunset),
            SunEvent(angle: -0.3, rise: \.sunriseEnd, set: \.sunsetStart),
            SunEvent(angle: -6, rise: \.dawn, set: \.dusk),
            SunEvent(angle: -12, rise: \.nauticalDawn, set: \.nauticalDusk),
            SunEvent(angle: -18, rise: \.nightEnd, set: \.night),
            SunEvent(angle: 6, rise: \.goldenHourEnd, set: \.goldenHour),
        ]

        let lw = rad * -longitude
        let phi = rad * latitude
        let dh = observerAngle(height)
        let d = toDays(date)
        let n = julianCycle(d, lw)
        let ds = approxTransit(0, lw, n)
        let M = solarMeanAnomaly(ds)
        let L = eclipticLongitude(M)
        let dec = declination(L, 0)
        let jNoon = solarTransitJ(ds, M, L)

        var result = SunTimes(solarNoon: fromJulian(jNoon), nadir: fromJulian(jNoon - 0.5))

        for event in sunEvents {
            let h0 = (event.angle + dh) * rad
            let jSet = setJ(h0, lw, phi, dec, n, M, L)
            let jRise = jNoon - (jSet - jNoon)
            result[keyPath: event.rise] = fromJulian(jRise)
            result[keyPath: event.set] = fromJulian(jSet)
        }

        return result
    }

    // MARK: - Moon

    private static func moonCoords(_ d: Double) -> (
        rightAscension: Double, declination: Double, distance: Double
    ) {
        let L = rad * (218.316 + 13.176396 * d)   // ecliptic longitude
        let M = rad * (134.963 + 13.064993 * d)   // mean anomaly
        let F = rad * (93.272 + 13.229350 * d)    // mean distance
        let l = L + rad * 6.289 * sin(M)          // longitude
        let b = rad * 5.128 * sin(F)              // latitude
        let dt = 385_001 - 20_905 * cos(M)        // distance in km
        return (rightAscension(l, b), declination(l, b), dt)
    }

    public struct MoonPosition: Sendable {
        public let azimuth: Double
        public let altitude: Double
        public let distance: Double
        public let parallacticAngle: Double
    }

    public static func moonPosition(
        date: Date, latitude: Double, longitude: Double
    ) -> MoonPosition {
        let lw = rad * -longitude
        let phi = rad * latitude
        let d = toDays(date)
        let c = moonCoords(d)
        let H = siderealTime(d, lw) - c.rightAscension
        var h = altitude(H, phi, c.declination)
        let pa = atan2(sin(H), tan(phi) * cos(c.declination) - sin(c.declination) * cos(H))
        h += astroRefraction(h)
        return MoonPosition(
            azimuth: azimuth(H, phi, c.declination),
            altitude: h,
            distance: c.distance,
            parallacticAngle: pa
        )
    }

    public struct MoonIllumination: Sendable {
        /// Illuminated fraction of the disc, 0...1.
        public let fraction: Double
        /// Phase position in the cycle: 0 new, 0.25 first quarter, 0.5 full, 0.75 last.
        public let phase: Double
        public let angle: Double
    }

    public static func moonIllumination(date: Date) -> MoonIllumination {
        let d = toDays(date)
        let s = sunCoords(d)
        let m = moonCoords(d)
        let sunDistance: Double = 149_598_000  // km, 1 AU

        let phi = acos(
            sin(s.declination) * sin(m.declination)
                + cos(s.declination) * cos(m.declination)
                * cos(s.rightAscension - m.rightAscension)
        )
        let inc = atan2(sunDistance * sin(phi), m.distance - sunDistance * cos(phi))
        let angle = atan2(
            cos(s.declination) * sin(s.rightAscension - m.rightAscension),
            sin(s.declination) * cos(m.declination)
                - cos(s.declination) * sin(m.declination)
                * cos(s.rightAscension - m.rightAscension)
        )

        return MoonIllumination(
            fraction: (1 + cos(inc)) / 2,
            phase: 0.5 + 0.5 * inc * (angle < 0 ? -1 : 1) / .pi,
            angle: angle
        )
    }

    public struct MoonTimes: Sendable {
        public var rise: Date?
        public var set: Date?
        /// True when the moon does not cross the horizon on this day.
        public var alwaysUp = false
        public var alwaysDown = false
    }

    private static func hoursLater(_ date: Date, _ h: Double) -> Date {
        date.addingTimeInterval(h * 3600)
    }

    /// Moonrise/moonset for the local day containing `date`.
    ///
    /// Works by sampling altitude every two hours and solving the quadratic through
    /// each triple of samples for a horizon crossing.
    public static func moonTimes(
        date: Date,
        latitude: Double,
        longitude: Double,
        timeZone: TimeZone = .current
    ) -> MoonTimes {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: date)

        // The moon's mean angular radius plus refraction at the horizon.
        let hc = 0.133 * rad
        var h0 = moonPosition(date: start, latitude: latitude, longitude: longitude).altitude - hc

        var rise: Double?
        var set: Double?
        var ye: Double = 0

        var i = 1.0
        while i <= 24 {
            let h1 = moonPosition(
                date: hoursLater(start, i), latitude: latitude, longitude: longitude
            ).altitude - hc
            let h2 = moonPosition(
                date: hoursLater(start, i + 1), latitude: latitude, longitude: longitude
            ).altitude - hc

            let a = (h0 + h2) / 2 - h1
            let b = (h2 - h0) / 2
            let xe = -b / (2 * a)
            ye = (a * xe + b) * xe + h1
            let d = b * b - 4 * a * h1
            var roots = 0
            var x1 = 0.0
            var x2 = 0.0

            if d >= 0 {
                let dx = d.squareRoot() / (abs(a) * 2)
                x1 = xe - dx
                x2 = xe + dx
                if abs(x1) <= 1 { roots += 1 }
                if abs(x2) <= 1 { roots += 1 }
                if x1 < -1 { x1 = x2 }
            }

            if roots == 1 {
                if h0 < 0 { rise = i + x1 } else { set = i + x1 }
            } else if roots == 2 {
                rise = i + (ye < 0 ? x2 : x1)
                set = i + (ye < 0 ? x1 : x2)
            }

            if rise != nil, set != nil { break }
            h0 = h2
            i += 2
        }

        var result = MoonTimes()
        if let rise { result.rise = hoursLater(start, rise) }
        if let set { result.set = hoursLater(start, set) }
        if rise == nil, set == nil {
            if ye > 0 { result.alwaysUp = true } else { result.alwaysDown = true }
        }
        return result
    }
}
