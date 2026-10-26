import Foundation

/// What the home screen and StandBy widget shows.
public struct WidgetWeather: Sendable, Equatable, Codable {
    /// "Tampa, FL".
    public var place: String
    /// "79°", already in the user's units.
    public var temperature: String
    /// "Mostly Cloudy".
    public var condition: String
    /// The NWS icon address, which `IconMapper` turns into a WeatherStar icon.
    public var icon: String?
    public var observedAt: Date?
    /// The rest of the Current Conditions panel, for the large size: only what the station
    /// reported, worded as the display words it.
    public var readings: [Reading]

    /// "Humidity:" and "68%".
    public struct Reading: Sendable, Equatable, Codable {
        public var label: String
        public var value: String

        public init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    public init(
        place: String, temperature: String, condition: String, icon: String?, observedAt: Date?,
        readings: [Reading] = []
    ) {
        self.place = place
        self.temperature = temperature
        self.condition = condition
        self.icon = icon
        self.observedAt = observedAt
        self.readings = readings
    }
}

/// The place and units the app is showing, shared with the widget through an App Group.
///
/// Only those: the widget fetches its own weather, so it stays current when the app has not run
/// for hours, and the app does not have to keep a second copy of everything it shows. The group
/// identifier comes from the `WS4KAppGroup` Info.plist key, so a fork can use its own; with no
/// group, or one the build is not entitled to, the widget asks for a place to be set in the app
/// rather than failing.
public enum SharedContainer {
    private static let locationKey = "ws4k.widget.location"
    private static let unitsKey = "ws4k.widget.units"

    public static var groupID: String? {
        Bundle.main.object(forInfoDictionaryKey: "WS4KAppGroup") as? String
    }

    public static func defaults(suite: String? = groupID) -> UserDefaults? {
        suite.flatMap(UserDefaults.init(suiteName:))
    }

    /// Called by the app whenever the place or the units change.
    public static func publish(location: SavedLocation?, units: UnitSystem, into defaults: UserDefaults? = defaults()) {
        guard let defaults else { return }
        if let location, let data = try? JSONEncoder().encode(location) {
            defaults.set(data, forKey: locationKey)
        } else {
            defaults.removeObject(forKey: locationKey)
        }
        defaults.set(units.rawValue, forKey: unitsKey)
    }

    /// Read by the widget.
    public static func shared(from defaults: UserDefaults? = defaults()) -> (location: SavedLocation, units: UnitSystem)? {
        guard let defaults,
              let data = defaults.data(forKey: locationKey),
              let location = try? JSONDecoder().decode(SavedLocation.self, from: data)
        else { return nil }
        let units = defaults.string(forKey: unitsKey).flatMap(UnitSystem.init(rawValue:)) ?? .us
        return (location, units)
    }
}

/// The widget's own fetch: the latest observation from the nearest station that has one.
public enum WidgetWeatherService {
    public static func fetch(
        location: SavedLocation, units: UnitSystem, client: NWSClient = .shared
    ) async -> WidgetWeather? {
        guard let point = try? await client.point(latitude: location.latitude, longitude: location.longitude),
              let stations = try? await client.stations(for: point)
        else { return nil }

        let converters = UnitConverters(system: units)
        // The nearest station often omits a reading; walk outward a little, as the store does.
        for station in stations.prefix(4) {
            guard let collection = try? await client.observations(stationURL: station.id, limit: 1),
                  let observation = collection.features.first?.properties,
                  let celsius = observation.temperature?.value,
                  let condition = observation.textDescription, !condition.isEmpty
            else { continue }
            return WidgetWeather(
                place: location.name,
                temperature: "\(converters.temperature(celsius))\u{00B0}",
                condition: condition,
                icon: observation.icon,
                observedAt: observation.timestamp,
                readings: readings(observation, units: converters)
            )
        }
        return nil
    }

    /// Wind, humidity, dewpoint, visibility and pressure, then heat index or wind chill when
    /// one applies. A reading the station left out is left out here, not shown as a dash.
    static func readings(_ observation: WeatherObservation, units: UnitConverters) -> [WidgetWeather.Reading] {
        var readings: [WidgetWeather.Reading] = []
        if observation.windSpeed?.value != nil {
            readings.append(.init("Wind:", ObservationText.wind(observation, units: units)))
        }
        if let humidity = observation.relativeHumidity?.value {
            readings.append(.init("Humidity:", "\(Int(humidity.rounded()))%"))
        }
        if let dewpoint = observation.dewpoint?.value {
            readings.append(.init("Dewpoint:", "\(units.temperature(dewpoint))\(degreeSign)"))
        }
        if let visibility = observation.visibility?.value {
            readings.append(.init("Visibility:", units.visibility.withUnits(visibility)))
        }
        if let pressure = observation.barometricPressure?.value {
            readings.append(.init("Pressure:", units.pressure.withUnits(pressure)))
        }
        if let apparent = ObservationText.apparent(observation, units: units) {
            readings.append(.init(apparent.label, apparent.value))
        }
        return readings
    }
}
