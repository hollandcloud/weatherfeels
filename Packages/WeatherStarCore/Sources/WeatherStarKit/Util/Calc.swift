import Foundation

public enum Calc {
    /// Compass direction from degrees, e.g. 200° → `"SSW"`.
    /// Returns `"VAR"` for a missing reading, matching `utils/calc.mjs`.
    public static func directionToNSEW(_ degrees: Double?) -> String {
        guard let degrees, degrees.isFinite else { return "VAR" }
        let names = [
            "N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
            "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW",
        ]
        let index = Int(((degrees / 22.5) + 0.5).rounded(.down))
        return names[wrap(index, 16)]
    }

    public static func distance(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        ((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1)).squareRoot()
    }

    /// Great-circle distance in kilometers.
    public static func haversineKilometers(
        lat1: Double, lon1: Double, lat2: Double, lon2: Double
    ) -> Double {
        let earthRadius = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return earthRadius * 2 * atan2(a.squareRoot(), (1 - a).squareRoot())
    }

    /// Wrap into `0..<m`, correct for negative input (Swift's `%` is not).
    public static func wrap(_ x: Int, _ m: Int) -> Int {
        ((x % m) + m) % m
    }

    /// Clamp `value` into `low...high`.
    public static func coerce(_ low: Double, _ value: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }
}
