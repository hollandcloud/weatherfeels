import Foundation

/// Measurement system, matching upstream's `units` setting.
public enum UnitSystem: String, Codable, Sendable, CaseIterable {
    case us
    case si

    public var displayName: String {
        switch self {
        case .us: "US / Imperial"
        case .si: "Metric"
        }
    }
}

/// A unit converter that mirrors `utils/units.mjs`.
///
/// The NWS API reports in metric, so each converter is built with the unit its
/// *source* data uses and converts only when that differs from the user's choice.
/// A nil input formats as `"-"`, which is what the original displays render for
/// missing observations.
public struct UnitConverter: Sendable {
    /// Suffix shown next to the value, e.g. `"MPH"` or `" in.hg"`.
    public let units: String

    private let transform: @Sendable (Double) -> Double
    /// Fixed decimal places when formatting; nil rounds to a whole number.
    private let decimals: Int?

    init(units: String, decimals: Int? = nil, transform: @escaping @Sendable (Double) -> Double) {
        self.units = units
        self.decimals = decimals
        self.transform = transform
    }

    /// Converted numeric value, or nil when the source value was missing.
    public func value(_ input: Double?) -> Double? {
        guard let input else { return nil }
        return transform(input)
    }

    /// Converted value formatted the way the displays expect, `"-"` when missing.
    public func callAsFunction(_ input: Double?) -> String {
        guard let converted = value(input) else { return "-" }
        if let decimals {
            return String(format: "%.\(decimals)f", converted)
        }
        return String(Int(converted.rounded()))
    }

    /// Formatted value with the unit suffix appended.
    public func withUnits(_ input: Double?) -> String {
        "\(self(input))\(units)"
    }
}

// MARK: - Primitive conversions

public enum Convert {
    /// Truncating round used upstream for pressure, kept identical so values match.
    public static func round2(_ value: Double, _ decimals: Int) -> Double {
        let factor = pow(10.0, Double(decimals))
        return (value * factor).rounded(.towardZero) / factor
    }

    public static func kphToMph(_ kph: Double) -> Double { (kph / 1.609_34).rounded() }
    public static func mphToKph(_ mph: Double) -> Double { (mph * 1.609_34).rounded() }
    public static func celsiusToFahrenheit(_ c: Double) -> Double { ((c * 9) / 5 + 32).rounded() }
    public static func fahrenheitToCelsius(_ f: Double) -> Double { ((f - 32) * 5 / 9).rounded() }
    public static func kilometersToMiles(_ km: Double) -> Double { (km / 1.609_34).rounded() }
    public static func metersToFeet(_ m: Double) -> Double { (m / 0.3048).rounded() }
    public static func pascalToInHg(_ pa: Double) -> Double { round2(pa * 0.000_295_3, 2) }
}

// MARK: - Converter factories

extension UnitConverter {
    /// Wind speed. NWS reports km/h.
    public static func windSpeed(for system: UnitSystem, source: UnitSystem = .si) -> Self {
        let units = system == .si ? "kph" : "MPH"
        guard system != source else { return Self(units: units) { $0.rounded() } }
        return Self(units: units) { Convert.kphToMph($0) }
    }

    /// Temperature. NWS reports Celsius.
    public static func temperature(for system: UnitSystem, source: UnitSystem = .si) -> Self {
        let units = system == .si ? "C" : "F"
        guard system != source else { return Self(units: units) { $0.rounded() } }
        return source == .us
            ? Self(units: units) { Convert.fahrenheitToCelsius($0) }
            : Self(units: units) { Convert.celsiusToFahrenheit($0) }
    }

    /// Cloud ceiling. NWS reports meters; feet are rounded to the nearest 100.
    public static func distanceMeters(for system: UnitSystem, source: UnitSystem = .si) -> Self {
        let units = system == .si ? "m." : "ft."
        guard system != source else { return Self(units: units) { $0.rounded() } }
        return Self(units: units) { (Convert.metersToFeet($0) / 100).rounded() * 100 }
    }

    /// Visibility. NWS reports meters, displayed in km or miles.
    public static func distanceKilometers(for system: UnitSystem, source: UnitSystem = .si) -> Self {
        let units = system == .si ? " km." : " mi."
        guard system != source else { return Self(units: units) { ($0 / 1000).rounded() } }
        return Self(units: units) { (Convert.kilometersToMiles($0) / 1000).rounded() }
    }

    /// Barometric pressure. NWS reports pascals, displayed in millibars or inHg.
    public static func pressure(for system: UnitSystem, source: UnitSystem = .si) -> Self {
        let units = system == .si ? " mbar" : " in.hg"
        guard system != source else { return Self(units: units) { ($0 / 100).rounded() } }
        return Self(units: units, decimals: 2) { Convert.pascalToInHg($0) }
    }
}

/// The full set of converters for one unit system, so a display builds them once.
///
/// `source` is the system the *data* arrives in. Station observations are always
/// metric, but the forecast endpoints honour a `units` query parameter — including in
/// their narrative text — so forecast data is requested in the user's own system and
/// needs no conversion. Getting this wrong is how the Local Forecast ended up reading
/// "High near 32" with the app set to Fahrenheit.
public struct UnitConverters: Sendable {
    public let system: UnitSystem
    public let source: UnitSystem
    public let temperature: UnitConverter
    public let windSpeed: UnitConverter
    public let pressure: UnitConverter
    public let ceiling: UnitConverter
    public let visibility: UnitConverter

    public init(system: UnitSystem, source: UnitSystem = .si) {
        self.system = system
        self.source = source
        temperature = .temperature(for: system, source: source)
        windSpeed = .windSpeed(for: system, source: source)
        pressure = .pressure(for: system, source: source)
        ceiling = .distanceMeters(for: system, source: source)
        visibility = .distanceKilometers(for: system, source: source)
    }

    /// Convert a temperature using the unit the API declared for it.
    ///
    /// The forecast endpoints honour their `units` parameter for plain numeric fields
    /// and narrative text, but a `QuantitativeValue` carries its own `unitCode` and is
    /// generally still Celsius. Trusting the request's units for those made the Hourly
    /// Graph plot a 23 °C dewpoint against an 88 °F temperature.
    public func temperatureValue(_ value: QuantitativeValue?) -> Double? {
        guard let raw = value?.value else { return nil }

        let declared: UnitSystem? = switch value?.unitCode {
        case "wmoUnit:degC", "unit:degC": .si
        case "wmoUnit:degF", "unit:degF": .us
        default: nil
        }

        // Fall back to the source system when the API omits or uses an unknown code.
        let from = declared ?? source
        guard from != system else { return raw.rounded() }
        return from == .si
            ? Convert.celsiusToFahrenheit(raw)
            : Convert.fahrenheitToCelsius(raw)
    }

    /// Formatted form of `temperatureValue`, `"-"` when missing.
    public func temperatureText(_ value: QuantitativeValue?) -> String {
        guard let converted = temperatureValue(value) else { return "-" }
        return String(Int(converted))
    }
}
