import Foundation

/// The four principal moon phases the Almanac display lists.
public enum MoonPhase: String, Sendable, CaseIterable, Codable {
    case new = "New"
    case first = "First"
    case full = "Full"
    case last = "Last"

    /// Fraction of the cycle at which this phase occurs.
    var threshold: Double {
        switch self {
        case .new: 0.0
        case .first: 0.25
        case .full: 0.5
        case .last: 0.75
        }
    }

    var iconFileName: String {
        switch self {
        case .new: "New-Moon.gif"
        case .first: "First-Quarter.gif"
        case .full: "Full-Moon.gif"
        case .last: "Last-Quarter.gif"
        }
    }
}

/// A dated principal phase, e.g. "Full — Mar 14".
public struct MoonPhaseEvent: Sendable, Hashable, Identifiable {
    public let phase: MoonPhase
    public let date: Date

    public var id: String { "\(phase.rawValue)-\(date.timeIntervalSince1970)" }

    public init(phase: MoonPhase, date: Date) {
        self.phase = phase
        self.date = date
    }
}

extension MoonPhase {
    /// Upcoming principal phases, starting from yesterday.
    ///
    /// Mirrors `almanac.mjs`: scan forward a day at a time watching for the
    /// illumination fraction to cross each principal threshold, then bisect within
    /// the straddling day to pin down the moment. Upstream refines by stepping
    /// hours/minutes/seconds; bisection reaches the same displayed date far more
    /// directly, and only the month/day is ever shown.
    public static func upcoming(
        from referenceDate: Date = Date(),
        count: Int = 5,
        maximumDays: Int = 45
    ) -> [MoonPhaseEvent] {
        var events: [MoonPhaseEvent] = []
        let oneDay: TimeInterval = 86_400

        var date = referenceDate.addingTimeInterval(-oneDay)
        var phase = SunCalc.moonIllumination(date: date).phase
        var iterations = 0

        while iterations <= maximumDays, events.count < count {
            let previousDate = date
            let previousPhase = phase

            date = date.addingTimeInterval(oneDay)
            phase = SunCalc.moonIllumination(date: date).phase

            // Ascending crossings of the three interior thresholds.
            for candidate in [MoonPhase.first, .full, .last]
            where previousPhase < candidate.threshold && phase >= candidate.threshold {
                let moment = bisect(
                    from: previousDate,
                    to: date,
                    crossing: candidate.threshold,
                    ascending: true
                )
                events.append(MoonPhaseEvent(phase: candidate, date: moment))
            }

            // The phase value wraps from ~1.0 back to ~0.0 at new moon, so a
            // decrease across the day boundary is the new-moon crossing.
            if previousPhase > phase {
                let moment = bisect(from: previousDate, to: date, crossing: 1.0, ascending: true)
                events.append(MoonPhaseEvent(phase: .new, date: moment))
            }

            iterations += 1
        }

        return events.sorted { $0.date < $1.date }
    }

    /// Bisect the interval to find when the phase crosses `threshold`, to ~1s.
    private static func bisect(
        from start: Date,
        to end: Date,
        crossing threshold: Double,
        ascending: Bool
    ) -> Date {
        var low = start
        var high = end

        // The new-moon case is expressed as a crossing of 1.0; unwrap the sample so
        // the comparison stays monotonic across the wrap point.
        func sample(_ date: Date) -> Double {
            let value = SunCalc.moonIllumination(date: date).phase
            if threshold >= 1.0, value < 0.5 { return value + 1.0 }
            return value
        }

        // ~21 halvings takes one day down to about a second.
        for _ in 0..<21 {
            let mid = Date(
                timeIntervalSince1970: (low.timeIntervalSince1970 + high.timeIntervalSince1970) / 2
            )
            let crossed = ascending ? sample(mid) >= threshold : sample(mid) <= threshold
            if crossed { high = mid } else { low = mid }
        }

        return high
    }
}
