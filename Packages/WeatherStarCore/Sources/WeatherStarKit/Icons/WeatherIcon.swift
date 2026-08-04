import Foundation
import WeatherStarResources

/// A Star4000 icon asset, resolved to a file in the bundled resources.
public struct WeatherIcon: Sendable, Hashable, Identifiable {
    public enum Set: Sendable, Hashable {
        /// Large 112×108 icons used by Current Conditions.
        case currentConditions
        /// Small icons used by the regional map, travel and hourly displays.
        case regionalMap
        case moonPhase

        var directory: WeatherStarResources.Directory {
            switch self {
            case .currentConditions: .currentConditionIcons
            case .regionalMap: .regionalMapIcons
            case .moonPhase: .moonPhaseIcons
            }
        }
    }

    public let fileName: String
    public let set: Set

    public var id: String { "\(set)/\(fileName)" }

    public init(fileName: String, set: Set) {
        self.fileName = fileName
        self.set = set
    }

    /// On-disk URL, or nil when the asset is missing from the bundle.
    public var url: URL? {
        WeatherStarResources.url(fileName, in: set.directory)
    }

    public static let noData = WeatherIcon(fileName: "No-Data.gif", set: .currentConditions)
}

/// Condition parsed out of an NWS icon URL.
///
/// The `icon` property is deprecated upstream in the API but is still the only way
/// to get a condition code, so we parse it the same way ws4kp does.
public struct ParsedIcon: Sendable, Hashable {
    /// Condition token, e.g. `"tsra_hi"`, `"skc"`, `"bkn"`.
    public let condition: String
    /// Percent chance, defaulting to 100 when the URL omits it.
    public let probability: Int
    public let isNight: Bool

    /// Parse `/icons/{set}/{day|night}/{condition}?{params}`.
    ///
    /// The condition segment may hold two comma/slash-separated conditions when the
    /// period has changing weather; upstream takes the *second* one, so we do too.
    public init?(iconURL: String, isNightOverride: Bool? = nil) {
        guard let match = iconURL.firstMatch(
            of: /\/icons\/[^\/]+\/(?<timeOfDay>day|night)\/(?<condition>[^?]+)/
                .ignoresCase()
        ) else { return nil }

        let timeOfDay = String(match.output.timeOfDay).lowercased()
        isNight = isNightOverride ?? (timeOfDay == "night")

        let conditionSegment = String(match.output.condition)

        func split(_ part: String) -> (String, Int) {
            let pieces = part.split(separator: ",", maxSplits: 1)
            let name = pieces.first.map(String.init) ?? ""
            let probability = pieces.count > 1 ? Int(pieces[1]) ?? 100 : 100
            return (name, probability == 0 ? 100 : probability)
        }

        if conditionSegment.contains("/") {
            let halves = conditionSegment.split(separator: "/", maxSplits: 1).map(String.init)
            let (firstIcon, firstProbability) = split(halves.first ?? "")
            let (secondIcon, secondProbability) = split(halves.count > 1 ? halves[1] : "")

            if secondIcon != firstIcon, !secondIcon.isEmpty {
                condition = secondIcon
                probability = secondProbability
            } else {
                condition = firstIcon
                probability = firstProbability
            }
        } else {
            let (name, chance) = split(conditionSegment)
            condition = name
            probability = chance
        }

        guard !condition.isEmpty else { return nil }
    }

    /// Lookup key combining condition and time of day, as upstream's switch uses.
    var key: String { isNight ? "\(condition)-n" : condition }
}

public enum IconMapper {
    // MARK: - Large icons (Current Conditions)

    /// Ported from `icons/icons-large.mjs`.
    public static func largeIcon(for iconURL: String?, isNight: Bool? = nil) -> WeatherIcon {
        guard let iconURL,
              let parsed = ParsedIcon(iconURL: iconURL, isNightOverride: isNight)
        else { return .noData }

        let file: String? = switch parsed.key {
        case "skc", "hot", "haze", "cold": "Sunny.gif"
        case "skc-n", "haze-n", "cold-n": "Clear.gif"
        case "dust", "dust-n", "smoke", "smoke-n": "Smoke.gif"
        case "few", "sct", "bkn": "Partly-Cloudy.gif"
        case "few-n", "sct-n", "bkn-n": "Mostly-Clear.gif"
        case "ovc", "ovc-n": "Cloudy.gif"
        case "fog", "fog-n": "Fog.gif"
        case "rain_sleet", "rain_sleet-n": "Rain-Sleet.gif"
        case "sleet", "sleet-n": "Sleet.gif"
        case "rain_showers", "rain_showers_hi", "rain_showers_high",
             "rain_showers-n", "rain_showers_hi-n", "rain_showers_high-n": "Shower.gif"
        case "rain", "rain-n": "Rain.gif"
        case "snow", "snow-n": parsed.probability > 50 ? "Heavy-Snow.gif" : "Light-Snow.gif"
        case "rain_snow", "rain_snow-n": "Rain-Snow.gif"
        case "snow_fzra", "snow_fzra-n", "winter_mix", "winter_mix-n": "Freezing-Rain-Snow.gif"
        case "fzra", "fzra-n", "rain_fzra", "rain_fzra-n": "Freezing-Rain.gif"
        case "snow_sleet", "snow_sleet-n": "Snow-Sleet.gif"
        case "tsra_sct", "tsra": "Scattered-Thunderstorms-Day.gif"
        case "tsra_sct-n", "tsra-n": "Scattered-Thunderstorms-Night.gif"
        case "tsra_hi", "tsra_hi-n", "tornado", "tornado-n",
             "hurricane", "hurricane-n", "tropical_storm", "tropical_storm-n": "Thunderstorm.gif"
        case "wind_skc", "wind_skc-n", "wind_", "wind_-n", "wind_few", "wind_few-n",
             "wind_sct", "wind_sct-n", "wind_bkn", "wind_bkn-n",
             "wind_ovc", "wind_ovc-n": "Windy.gif"
        case "blizzard", "blizzard-n": "Blowing-Snow.gif"
        default: nil
        }

        guard let file else { return .noData }
        return WeatherIcon(fileName: file, set: .currentConditions)
    }

    // MARK: - Small icons (regional map, travel, extended forecast)

    /// Ported from `icons/icons-small.mjs`.
    public static func smallIcon(for iconURL: String?, isNight: Bool? = nil) -> WeatherIcon {
        guard let iconURL,
              let parsed = ParsedIcon(iconURL: iconURL, isNightOverride: isNight)
        else { return .noData }

        let file: String? = switch parsed.key {
        case "skc": "Sunny.gif"
        case "skc-n": "Clear-1992.gif"
        case "few", "sct": "Partly-Cloudy.gif"
        case "few-n", "bkn-n": "Partly-Clear-1994.gif"
        case "sct-n": "Partly-Cloudy-Night.gif"
        case "bkn": "Mostly-Cloudy-1994.gif"
        case "ovc", "ovc-n": "Cloudy.gif"
        case "fog", "fog-n": "Fog.gif"
        case "rain", "rain-n": "Rain-1992.gif"
        case "rain_showers", "rain_showers_hi": "Scattered-Showers-1994.gif"
        case "rain_showers-n", "rain_showers_hi-n": "Scattered-Showers-Night-1994.gif"
        case "snow", "snow-n": parsed.probability > 50 ? "Heavy-Snow-1994.gif" : "Light-Snow.gif"
        case "rain_snow", "rain_snow-n": "Rain-Snow-1992.gif"
        case "rain_sleet": "Rain-Sleet.gif"
        case "snow_sleet", "snow_sleet-n": "Snow-Sleet.gif"
        case "sleet", "sleet-n": "Sleet.gif"
        case "fzra", "fzra-n", "rain_fzra", "rain_fzra-n": "Freezing-Rain-1992.gif"
        case "snow_fzra", "snow_fzra-n": "Freezing-Rain-Snow-1994.gif"
        case "tsra", "tsra_sct": "Scattered-Tstorms-1994.gif"
        case "tsra-n", "tsra_sct-n": "Scattered-Tstorms-Night-1994.gif"
        case "tsra_hi", "tsra_hi-n", "tornado", "tornado-n",
             "hurricane", "hurricane-n", "tropical_storm", "tropical_storm-n": "Thunderstorm.gif"
        case "wind_skc": "Sunny-Wind-1994.gif"
        case "wind_skc-n", "wind_sct-n": "Clear-Wind-1994.gif"
        case "wind_few", "wind_few-n", "wind_", "wind_sct": "Wind.gif"
        case "wind_bkn", "wind_bkn-n", "wind_ovc", "wind_ovc-n": "Cloudy-Wind.gif"
        case "dust", "dust-n", "smoke", "smoke-n": "Smoke.gif"
        case "haze", "haze-n": "Haze.gif"
        case "hot": "Hot.gif"
        case "cold", "cold-n": "Cold.gif"
        case "blizzard", "blizzard-n": "Blowing-Snow.gif"
        default: nil
        }

        guard let file else { return .noData }
        return WeatherIcon(fileName: file, set: .regionalMap)
    }

    // MARK: - Hourly icons (derived from raw grid elements)

    /// Choose an icon from raw gridpoint elements rather than an icon URL.
    /// Ported from `icons/icons-hourly.mjs`; the ordering encodes precedence,
    /// so the most hazardous phenomenon wins.
    public static func hourlyIcon(
        skyCover: Double?,
        weatherPhenomena: [String],
        iceAccumulation: Double?,
        probabilityOfPrecipitation: Double?,
        snowfallAmount: Double?,
        windSpeed: Double?,
        isNight: Bool = false
    ) -> WeatherIcon {
        let phenomena = weatherPhenomena.map { $0.lowercased() }
        let thunder = phenomena.contains { $0.contains("thunder") }
        let snow = phenomena.contains { $0.contains("snow") }
        let ice = phenomena.contains { $0.contains("ice") }
        let fog = phenomena.contains { $0.contains("fog") }
        let wind = phenomena.contains { $0.contains("wind") }

        let iceAmount = iceAccumulation ?? 0
        let snowAmount = snowfallAmount ?? 0
        let precipChance = probabilityOfPrecipitation ?? 0
        let sky = skyCover ?? 0
        let speed = windSpeed ?? 0

        let file: String
        if iceAmount > 0 || ice {
            file = "Freezing-Rain-1992.gif"
        } else if snowAmount > 10 {
            file = (speed > 30 || wind) ? "Blowing-Snow.gif" : "Heavy-Snow-1994.gif"
        } else if (snowAmount > 0 || snow) && thunder {
            file = "ThunderSnow.gif"
        } else if snowAmount > 0 || snow {
            file = "Light-Snow.gif"
        } else if thunder {
            file = "Thunderstorm.gif"
        } else if precipChance > 70 {
            file = "Rain-1992.gif"
        } else if precipChance > 30 {
            file = isNight ? "Scattered-Showers-Night-1994.gif" : "Scattered-Showers-1994.gif"
        } else if fog {
            file = "Fog.gif"
        } else if sky > 70 {
            file = "Cloudy.gif"
        } else if sky > 50 {
            file = isNight ? "Partly-Clear-1994.gif" : "Mostly-Cloudy-1994.gif"
        } else if sky > 30 {
            file = isNight ? "Partly-Cloudy-Night.gif" : "Partly-Cloudy.gif"
        } else {
            file = isNight ? "Clear-1992.gif" : "Sunny.gif"
        }

        return WeatherIcon(fileName: file, set: .regionalMap)
    }

    /// Moon phase art for the Almanac display.
    public static func moonIcon(for phase: MoonPhase) -> WeatherIcon {
        WeatherIcon(fileName: phase.iconFileName, set: .moonPhase)
    }
}
