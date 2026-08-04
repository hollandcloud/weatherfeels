import Foundation

/// Fields recovered from a raw METAR report.
///
/// NWS station observations frequently arrive with null values for elements the
/// station did report in its raw METAR, so upstream parses `rawMessage` and fills the
/// gaps. This covers the elements the displays actually read.
public struct METARReport: Sendable {
    /// Degrees Celsius.
    public var temperature: Double?
    public var dewpoint: Double?
    /// Degrees true.
    public var windDirection: Double?
    /// Kilometres per hour, converted from the reported knots or m/s.
    public var windSpeed: Double?
    public var windGust: Double?
    /// Pascals.
    public var barometricPressure: Double?
    /// Metres.
    public var visibility: Double?
    /// Metres above ground of the lowest broken/overcast layer.
    public var ceiling: Double?
    /// Percent, derived from temperature and dewpoint.
    public var relativeHumidity: Double?
}

public enum METARParser {
    private static let knotsToKph = 1.852
    private static let metersPerSecondToKph = 3.6
    private static let statuteMileToMeters = 1609.34
    private static let hundredFeetToMeters = 30.48

    /// Parse the groups the displays need out of a METAR observation.
    ///
    /// Deliberately tolerant: METAR is loosely standardised in practice, so an
    /// unrecognised group is skipped rather than failing the whole report.
    public static func parse(_ raw: String) -> METARReport {
        var report = METARReport()
        // Everything after RMK is supplementary and uses different encodings.
        let body = raw.components(separatedBy: " RMK").first ?? raw
        let groups = body.split(separator: " ").map(String.init)

        for group in groups {
            if report.windSpeed == nil, let wind = parseWind(group) {
                report.windDirection = wind.direction
                report.windSpeed = wind.speed
                report.windGust = wind.gust
                continue
            }
            if report.visibility == nil, let visibility = parseVisibility(group) {
                report.visibility = visibility
                continue
            }
            if report.temperature == nil, let temps = parseTemperatures(group) {
                report.temperature = temps.temperature
                report.dewpoint = temps.dewpoint
                continue
            }
            if report.barometricPressure == nil, let pressure = parseAltimeter(group) {
                report.barometricPressure = pressure
                continue
            }
            if let cloud = parseCloudLayer(group) {
                // Ceiling is the *lowest* broken or overcast layer.
                report.ceiling = report.ceiling.map { min($0, cloud) } ?? cloud
                continue
            }
        }

        if let temperature = report.temperature, let dewpoint = report.dewpoint {
            report.relativeHumidity = relativeHumidity(
                temperature: temperature,
                dewpoint: dewpoint
            )
        }

        return report
    }

    /// `dddffKT`, `dddffGggKT`, `VRBffKT`, or the same in `MPS`.
    private static func parseWind(
        _ group: String
    ) -> (direction: Double?, speed: Double, gust: Double?)? {
        guard let match = group.wholeMatch(
            of: /(?<direction>\d{3}|VRB)(?<speed>\d{2,3})(G(?<gust>\d{2,3}))?(?<unit>KT|MPS|KMH)/
        ) else { return nil }

        let factor: Double = switch String(match.output.unit) {
        case "KT": knotsToKph
        case "MPS": metersPerSecondToKph
        default: 1
        }

        let directionText = String(match.output.direction)
        let direction = directionText == "VRB" ? nil : Double(directionText)
        guard let speed = Double(match.output.speed) else { return nil }
        let gust = match.output.gust.flatMap { Double($0) }

        return (direction, speed * factor, gust.map { $0 * factor })
    }

    /// `10SM`, `1/2SM`, `2 1/2SM` (leading whole handled separately), or metres.
    private static func parseVisibility(_ group: String) -> Double? {
        if let match = group.wholeMatch(of: /(?<whole>\d{1,3})SM/) {
            return (Double(match.output.whole) ?? 0) * statuteMileToMeters
        }
        if let match = group.wholeMatch(of: /(?<numerator>\d)\/(?<denominator>\d)SM/) {
            guard let numerator = Double(match.output.numerator),
                  let denominator = Double(match.output.denominator),
                  denominator != 0
            else { return nil }
            return numerator / denominator * statuteMileToMeters
        }
        // A bare four-digit group is metres, used outside the US.
        if let match = group.wholeMatch(of: /(?<meters>\d{4})/) {
            return Double(match.output.meters)
        }
        return nil
    }

    /// `23/18`, `M05/M09` where `M` marks a negative value.
    private static func parseTemperatures(
        _ group: String
    ) -> (temperature: Double, dewpoint: Double?)? {
        guard let match = group.wholeMatch(
            of: /(?<tSign>M?)(?<temperature>\d{1,2})\/((?<dSign>M?)(?<dewpoint>\d{1,2}))?/
        ) else { return nil }

        guard let magnitude = Double(match.output.temperature) else { return nil }
        let temperature = match.output.tSign == "M" ? -magnitude : magnitude

        var dewpoint: Double?
        if let text = match.output.dewpoint, let value = Double(text) {
            dewpoint = match.output.dSign == "M" ? -value : value
        }

        return (temperature, dewpoint)
    }

    /// `A2992` (hundredths of inHg) or `Q1013` (whole hectopascals).
    private static func parseAltimeter(_ group: String) -> Double? {
        if let match = group.wholeMatch(of: /A(?<value>\d{4})/) {
            guard let hundredths = Double(match.output.value) else { return nil }
            // inHg to pascals.
            return hundredths / 100 * 3386.389
        }
        if let match = group.wholeMatch(of: /Q(?<value>\d{4})/) {
            guard let hectopascals = Double(match.output.value) else { return nil }
            return hectopascals * 100
        }
        return nil
    }

    /// `BKN035`, `OVC008`, `FEW250`. Only broken and overcast define a ceiling.
    private static func parseCloudLayer(_ group: String) -> Double? {
        guard let match = group.wholeMatch(
            of: /(?<cover>BKN|OVC|VV)(?<height>\d{3})(CB|TCU)?/
        ) else { return nil }
        guard let hundredsOfFeet = Double(match.output.height) else { return nil }
        return hundredsOfFeet * hundredFeetToMeters
    }

    /// Relative humidity from temperature and dewpoint via the Magnus formula.
    static func relativeHumidity(temperature: Double, dewpoint: Double) -> Double {
        let a = 17.625
        let b = 243.04
        let numerator = exp((a * dewpoint) / (b + dewpoint))
        let denominator = exp((a * temperature) / (b + temperature))
        return min(max(100 * numerator / denominator, 0), 100)
    }
}

extension WeatherObservation {
    /// Fill null elements from this observation's own raw METAR.
    ///
    /// Only ever *adds* data — a value the API supplied is never overwritten, which
    /// matches upstream's `augmentObservationWithMetar`.
    public func augmentedWithMETAR() -> WeatherObservation {
        guard let raw = rawMessage, !raw.isEmpty else { return self }
        let metar = METARParser.parse(raw)
        var result = self

        func fill(_ keyPath: WritableKeyPath<WeatherObservation, QuantitativeValue?>, _ value: Double?) {
            guard result[keyPath: keyPath]?.value == nil, let value else { return }
            result[keyPath: keyPath] = QuantitativeValue(value: value)
        }

        fill(\.temperature, metar.temperature)
        fill(\.dewpoint, metar.dewpoint)
        fill(\.windDirection, metar.windDirection)
        fill(\.windSpeed, metar.windSpeed)
        fill(\.windGust, metar.windGust)
        fill(\.barometricPressure, metar.barometricPressure)
        fill(\.visibility, metar.visibility)
        fill(\.relativeHumidity, metar.relativeHumidity)

        if result.cloudLayers?.first?.base?.value == nil, let ceiling = metar.ceiling {
            result.cloudLayers = [CloudLayer(base: QuantitativeValue(value: ceiling), amount: nil)]
        }

        return result
    }
}
