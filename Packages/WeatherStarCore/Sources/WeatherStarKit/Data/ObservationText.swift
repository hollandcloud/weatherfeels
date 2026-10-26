import Foundation

/// Readings worded the way the Current Conditions panel words them.
///
/// Shared by the display and the large widget, so the two never disagree about what the
/// wind is doing or whether it feels hotter than it is.
enum ObservationText {
    /// "NW 12", "Calm" when the station reports zero, "-" when it reports nothing.
    static func wind(_ observation: WeatherObservation, units: UnitConverters) -> String {
        let speedValue = units.windSpeed.value(observation.windSpeed?.value)
        return if speedValue == 0 {
            "Calm"
        } else if let speedValue {
            "\(Calc.directionToNSEW(observation.windDirection?.value)) \(Int(speedValue))"
        } else {
            "-"
        }
    }

    /// Heat index or wind chill, whichever differs from the actual temperature. They are
    /// mutually exclusive, and neither is shown when it says nothing the temperature does not.
    static func apparent(_ observation: WeatherObservation, units: UnitConverters) -> (label: String, value: String)? {
        let temperatureValue = units.temperature.value(observation.temperature?.value)
        if let heatIndex = units.temperature.value(observation.heatIndex?.value),
           heatIndex != temperatureValue {
            return ("Heat Index:", "\(Int(heatIndex))\(degreeSign)")
        } else if let windChill = units.temperature.value(observation.windChill?.value),
                  let temperatureValue, windChill < temperatureValue {
            return ("Wind Chill:", "\(Int(windChill))\(degreeSign)")
        }
        return nil
    }
}
