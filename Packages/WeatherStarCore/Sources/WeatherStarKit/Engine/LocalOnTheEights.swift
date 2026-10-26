import Foundation

/// The Weather Channel's "Local on the 8s": at every minute ending in 8 — :08, :18, :28 and so
/// on — national programming cut away to the local forecast.
///
/// Here the rotation keeps running, and at each cue a bumper goes up and a fixed local segment
/// plays — current conditions, the local forecast, the extended forecast — before the rotation
/// carries on where it was.
public enum LocalOnTheEights {
    /// What the segment shows, in order.
    public static let segment: [DisplayIdentifier] = [.currentWeather, .localForecast, .extendedForecast]

    /// How long the bumper holds before the segment starts.
    public static let bumperDuration: TimeInterval = 4

    /// The next minute ending in 8, strictly after `date`.
    ///
    /// On the device's own clock. Every time zone in the NWS's area is a whole number of hours
    /// from UTC, so the minute is the same wherever the forecast is for.
    public static func nextCue(after date: Date, calendar: Calendar = .current) -> Date {
        let minuteStart = calendar.dateInterval(of: .minute, for: date)?.start ?? date
        let minute = calendar.component(.minute, from: date)
        let minutesAway = (8 - minute % 10 + 10) % 10
        var cue = minuteStart.addingTimeInterval(TimeInterval(minutesAway * 60))
        if cue <= date {
            cue.addTimeInterval(600)
        }
        return cue
    }
}
