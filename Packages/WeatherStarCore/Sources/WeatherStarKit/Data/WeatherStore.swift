import Foundation
import Observation
import OSLog

/// Loads and holds the data every display draws from.
///
/// Each display is loaded independently and reports its own status to the
/// `DisplayEngine`, so one failing source (a station with no barometer, a radar host
/// that is down) removes just that display from the rotation instead of blanking the
/// screen — the same degradation behaviour ws4kp has.
@MainActor
@Observable
public final class WeatherStore {
    private let logger = Logger(subsystem: "net.weatherstar.kit", category: "WeatherStore")
    private let client: NWSClient
    private let settings: AppSettings
    private let engine: DisplayEngine

    public private(set) var parameters: WeatherParameters?
    public private(set) var isLoading = false
    public private(set) var loadError: Error?
    /// Fraction of displays that have finished loading, for the startup screen.
    public private(set) var loadProgress: Double = 0

    // Per-display data.
    public private(set) var currentConditions: CurrentConditionsData?
    public private(set) var observations: [ObservationRow] = []
    public private(set) var hourly: [HourlyRow] = []
    public private(set) var travel: [TravelRow] = []
    public private(set) var regionalScreens: [RegionalScreen] = []
    public private(set) var localForecast: LocalForecastData?
    public private(set) var extendedDays: [ExtendedDay] = []
    public private(set) var almanac: AlmanacData?
    public private(set) var hazards: [HazardItem] = []
    public private(set) var scroll: ScrollContent?
    public private(set) var spcOutlook: SPCOutlookData?
    public private(set) var radar: RadarData?

    // Reachable from `deinit`, which cannot touch main actor state. `Task.cancel()`
    // is safe from any isolation and these are only written on the main actor.
    @ObservationIgnored nonisolated(unsafe) private var refreshTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var loadTask: Task<Void, Never>?

    public init(
        client: NWSClient = .shared,
        settings: AppSettings,
        engine: DisplayEngine
    ) {
        self.client = client
        self.settings = settings
        self.engine = engine
    }

    deinit {
        refreshTask?.cancel()
        loadTask?.cancel()
    }

    /// Time zone every displayed time is rendered in — the point's zone, not the
    /// device's, so a saved out-of-state location reads correctly.
    public var timeZone: TimeZone {
        parameters?.timeZone ?? .current
    }

    /// Converters for station observations, which the API always reports in metric.
    public var converters: UnitConverters {
        UnitConverters(system: settings.units)
    }

    /// Converters for forecast data, which is requested in the user's own system and
    /// therefore needs no conversion — only formatting.
    public var forecastConverters: UnitConverters {
        UnitConverters(system: settings.units, source: settings.units)
    }

    // MARK: - Loading

    /// Load everything for a location, replacing whatever was shown before.
    public func load(location: SavedLocation) {
        loadTask?.cancel()
        loadTask = Task { await self.performLoad(location: location) }
    }

    private func performLoad(location: SavedLocation) async {
        isLoading = true
        loadError = nil
        loadProgress = 0
        engine.resetAll()
        defer { isLoading = false }

        do {
            let point = try await client.point(
                latitude: location.latitude,
                longitude: location.longitude
            )
            let stations = try await client.stations(for: point)
            let zone = point.properties.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current

            let resolved = WeatherParameters(
                location: location,
                point: point,
                stations: stations,
                timeZone: zone
            )
            parameters = resolved

            await loadDisplays(resolved)
            scheduleRefresh()
        } catch is CancellationError {
            return
        } catch {
            logger.error("Location load failed: \(error.localizedDescription)")
            loadError = error
            for display in DisplayIdentifier.allCases {
                engine.setStatus(.failed, for: display)
            }
        }
    }

    /// Load each display concurrently. A throwing loader marks only its own display
    /// as failed.
    private func loadDisplays(_ parameters: WeatherParameters) async {
        // Almanac needs no network at all, so fill it first — the rotation can start
        // as soon as one display is ready.
        loadAlmanac(parameters)

        let loaders: [(DisplayIdentifier, @Sendable @MainActor () async -> Void)] = [
            (.currentWeather, { await self.loadCurrentConditions(parameters) }),
            (.latestObservations, { await self.loadLatestObservations(parameters) }),
            (.localForecast, { await self.loadForecasts(parameters) }),
            (.hourly, { await self.loadHourly(parameters) }),
            (.regionalForecast, { await self.loadRegional(parameters) }),
            (.travel, { await self.loadTravel(parameters) }),
            (.hazards, { await self.loadHazards(parameters) }),
            (.spcOutlook, { await self.loadSPCOutlook(parameters) }),
            (.radar, { await self.loadRadar(parameters) }),
        ]

        var completed = 0.0
        let total = Double(loaders.count)

        await withTaskGroup(of: Void.self) { group in
            for (_, loader) in loaders {
                group.addTask { await loader() }
            }
            for await _ in group {
                completed += 1
                loadProgress = completed / total
            }
        }

        loadProgress = 1
    }

    /// Refresh silently on the user's interval, keeping the old data if a fetch fails.
    private func scheduleRefresh() {
        refreshTask?.cancel()
        let interval = settings.refreshInterval
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self, let parameters = self.parameters else { return }
                await self.loadDisplays(parameters)
            }
        }
    }

    public func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - Current Conditions

    private func loadCurrentConditions(_ parameters: WeatherParameters) async {
        engine.setStatus(.loading, for: .currentWeather)

        // Walk outward through nearby stations until one returns usable data — the
        // nearest station often omits several elements.
        for station in parameters.stations.prefix(8) {
            guard let collection = await client.tryGet(
                ObservationCollection.self,
                from: URL(string: station.id)!.appending(path: "observations"),
                query: ["limit": "5"]
            ) else { continue }

            guard !collection.features.isEmpty else { continue }

            let merged = Self.backfill(collection.features).augmentedWithMETAR()
            // Temperature and a condition string are mandatory; everything else the
            // display can render as a dash.
            guard merged.temperature?.value != nil,
                  let description = merged.textDescription, !description.isEmpty
            else { continue }

            currentConditions = buildCurrentConditions(
                merged,
                station: station,
                allFeatures: collection.features,
                parameters: parameters
            )
            buildScroll(parameters)
            engine.setStatus(.loaded, for: .currentWeather)
            engine.setTiming(.standard, for: .currentWeather)
            return
        }

        logger.warning("All nearby stations exhausted for current conditions")
        engine.setStatus(.failed, for: .currentWeather)
    }

    private func buildCurrentConditions(
        _ observation: WeatherObservation,
        station: StationFeature,
        allFeatures: [ObservationFeature],
        parameters: WeatherParameters
    ) -> CurrentConditionsData {
        let units = converters
        let identifier = station.properties.stationIdentifier

        var condition = observation.textDescription ?? ""
        if condition.count > 15 { condition = ConditionText.shorten(condition) }

        // Wind reads "NW 12", or "Calm" when the station reports zero.
        let speedValue = units.windSpeed.value(observation.windSpeed?.value)
        let wind: String = if speedValue == 0 {
            "Calm"
        } else if let speedValue {
            "\(Calc.directionToNSEW(observation.windDirection?.value)) \(Int(speedValue))"
        } else {
            "-"
        }

        var gust: String?
        if let gustValue = units.windSpeed.value(observation.windGust?.value), gustValue > 0 {
            gust = "Gusts to \(Int(gustValue))"
        }

        let ceilingValue = observation.ceiling?.value
        let ceiling = (ceilingValue ?? 0) == 0
            ? "Unlimited"
            : units.ceiling.withUnits(ceilingValue)

        // Two readings apart by more than 150 Pa indicate a rising/falling trend.
        var trend = ""
        if allFeatures.count > 1,
           let latest = observation.barometricPressure?.value,
           let previous = allFeatures[1].properties.barometricPressure?.value {
            let difference = latest - previous
            if difference > 150 { trend = "R" }
            if difference < -150 { trend = "F" }
        }

        let temperatureValue = units.temperature.value(observation.temperature?.value)

        // Heat index and wind chill are mutually exclusive; show whichever differs
        // from the actual temperature.
        var apparentLabel: String?
        var apparentValue: String?
        if let heatIndex = units.temperature.value(observation.heatIndex?.value),
           heatIndex != temperatureValue {
            apparentLabel = "Heat Index:"
            apparentValue = "\(Int(heatIndex))\(degreeSign)"
        } else if let windChill = units.temperature.value(observation.windChill?.value),
                  let temperatureValue, windChill < temperatureValue {
            apparentLabel = "Wind Chill:"
            apparentValue = "\(Int(windChill))\(degreeSign)"
        }

        // Observations older than an hourly cycle plus propagation delay are labelled
        // "Recent" rather than "Current".
        let isStale = observation.timestamp.map { Date().timeIntervalSince($0) > 80 * 60 } ?? false

        let locationLimit = 20
        let name = BundledData.cityName(forStation: identifier)
            ?? station.properties.name.locationCleanup

        return CurrentConditionsData(
            stationIdentifier: identifier,
            locationName: name.truncated(to: locationLimit),
            temperature: "\(units.temperature(observation.temperature?.value))\(degreeSign)",
            condition: condition,
            icon: IconMapper.largeIcon(for: observation.icon),
            wind: wind,
            windGust: gust,
            humidity: "\(units.temperature.value(nil) == nil ? "" : "")\(Int((observation.relativeHumidity?.value ?? 0).rounded()))%",
            dewpoint: "\(units.temperature(observation.dewpoint?.value))\(degreeSign)",
            ceiling: ceiling,
            visibility: units.visibility.withUnits(observation.visibility?.value),
            pressure: "\(units.pressure(observation.barometricPressure?.value))\(units.pressure.units) \(trend)",
            apparentLabel: apparentLabel,
            apparentValue: apparentValue,
            observedAt: observation.timestamp,
            isStale: isStale,
            temperatureValue: temperatureValue
        )
    }

    /// Merge a series of observations, taking each field from the most recent report
    /// that actually has it. Ported from `currentweather.mjs`'s `backfill`.
    nonisolated static func backfill(_ features: [ObservationFeature]) -> WeatherObservation {
        let sorted = features.sorted {
            ($0.properties.timestamp ?? .distantPast) > ($1.properties.timestamp ?? .distantPast)
        }
        guard var result = sorted.first?.properties else { return WeatherObservation() }

        func fill(_ keyPath: WritableKeyPath<WeatherObservation, QuantitativeValue?>) {
            guard result[keyPath: keyPath]?.value == nil else { return }
            for feature in sorted.dropFirst() {
                if let candidate = feature.properties[keyPath: keyPath], candidate.value != nil {
                    result[keyPath: keyPath] = candidate
                    return
                }
            }
        }

        fill(\.temperature)
        fill(\.dewpoint)
        fill(\.windDirection)
        fill(\.windSpeed)
        fill(\.windGust)
        fill(\.barometricPressure)
        fill(\.visibility)
        fill(\.relativeHumidity)
        fill(\.heatIndex)
        fill(\.windChill)

        if result.textDescription?.isEmpty ?? true {
            result.textDescription = sorted.dropFirst()
                .compactMap(\.properties.textDescription)
                .first { !$0.isEmpty }
        }
        if result.icon == nil {
            result.icon = sorted.dropFirst().compactMap(\.properties.icon).first
        }
        if result.cloudLayers?.first?.base?.value == nil {
            result.cloudLayers = sorted.dropFirst()
                .compactMap(\.properties.cloudLayers)
                .first { $0.first?.base?.value != nil }
        }

        return result
    }

    // MARK: - Latest Observations

    private func loadLatestObservations(_ parameters: WeatherParameters) async {
        engine.setStatus(.loading, for: .latestObservations)
        let units = converters

        // The display fits seven rows; request a few extra so stations that report
        // nothing usable can be dropped.
        let candidates = Array(parameters.stations.prefix(12))

        var rows: [ObservationRow] = []
        for station in candidates {
            guard rows.count < 7 else { break }
            guard let collection = await client.tryGet(
                ObservationCollection.self,
                from: URL(string: station.id)!.appending(path: "observations"),
                query: ["limit": "2"],
                retries: 1
            ), let latest = collection.features.first?.properties.augmentedWithMETAR() else {
                continue
            }
            guard latest.temperature?.value != nil else { continue }

            let identifier = station.properties.stationIdentifier
            let name = BundledData.cityName(forStation: identifier)
                ?? station.properties.name.locationCleanup

            let temperature = units.temperature.value(latest.temperature?.value)
            var apparent = ""
            var isHeatIndex = false
            var isWindChill = false
            if let heatIndex = units.temperature.value(latest.heatIndex?.value),
               heatIndex != temperature {
                apparent = String(Int(heatIndex))
                isHeatIndex = true
            } else if let windChill = units.temperature.value(latest.windChill?.value),
                      let temperature, windChill < temperature {
                apparent = String(Int(windChill))
                isWindChill = true
            }

            let speed = units.windSpeed.value(latest.windSpeed?.value) ?? 0
            let wind = speed == 0
                ? "Calm"
                : "\(Calc.directionToNSEW(latest.windDirection?.value).padded(to: 3)) \(Int(speed))"

            rows.append(
                ObservationRow(
                    stationIdentifier: identifier,
                    location: name.truncated(to: 22),
                    temperature: units.temperature(latest.temperature?.value),
                    apparent: apparent,
                    weather: (latest.textDescription ?? "").truncated(to: 18),
                    wind: wind,
                    isHeatIndex: isHeatIndex,
                    isWindChill: isWindChill
                )
            )
        }

        observations = rows
        if rows.isEmpty {
            engine.setStatus(.noData, for: .latestObservations)
        } else {
            engine.setTiming(.standard, for: .latestObservations)
            engine.setStatus(.loaded, for: .latestObservations)
        }
    }

    // MARK: - Forecasts (local + extended share one fetch)

    private func loadForecasts(_ parameters: WeatherParameters) async {
        engine.setStatus(.loading, for: .localForecast)
        engine.setStatus(.loading, for: .extendedForecast)

        guard let urlString = parameters.point.properties.forecast,
              let response = try? await client.forecast(urlString, units: settings.units)
        else {
            engine.setStatus(.failed, for: .localForecast)
            engine.setStatus(.failed, for: .extendedForecast)
            return
        }

        // Periods that have already ended would otherwise show as today's forecast.
        let periods = response.properties.periods.filter { $0.endTime > Date() }
        guard !periods.isEmpty else {
            engine.setStatus(.noData, for: .localForecast)
            engine.setStatus(.noData, for: .extendedForecast)
            return
        }

        buildLocalForecast(periods)
        buildExtendedForecast(periods)
    }

    private func buildLocalForecast(_ periods: [ForecastPeriod]) {
        // The display shows narrative text, prefixed with the period name in caps.
        let paragraphs = periods.prefix(6).map { period in
            let name = (period.name ?? "").uppercased()
            let text = period.detailedForecast ?? period.shortForecast ?? ""
            return name.isEmpty ? text : "\(name)...\(text)"
        }
        localForecast = LocalForecastData(paragraphs: paragraphs)
        // The scrolling timing is set by the view once it has measured the text.
        engine.setStatus(.loaded, for: .localForecast)
    }

    private func buildExtendedForecast(_ periods: [ForecastPeriod]) {
        let units = forecastConverters

        // Pair each daytime period with the night that follows it, so one panel can
        // show both a high and a low.
        var days: [ExtendedDay] = []
        var index = 0
        while index < periods.count, days.count < 6 {
            let period = periods[index]
            guard period.isDaytime else {
                // A forecast that starts at night has no high for today; skip ahead.
                index += 1
                continue
            }
            let night = periods.indices.contains(index + 1) && !periods[index + 1].isDaytime
                ? periods[index + 1]
                : nil

            let condition = period.shortForecast ?? ""
            days.append(
                ExtendedDay(
                    dayName: Self.shortDayName(for: period.startTime, in: timeZone),
                    icon: IconMapper.smallIcon(for: period.icon, isNight: false),
                    condition: condition,
                    low: night.map { units.temperature($0.temperature) } ?? "-",
                    high: units.temperature(period.temperature)
                )
            )
            index += night == nil ? 1 : 2
        }

        extendedDays = days
        // Upstream shows three days per screen, two screens when six are available.
        let screens = days.count > 3 ? 2 : 1
        engine.setTiming(
            DisplayTiming(totalScreens: screens, baseDelay: 9000, delay: .uniform(1)),
            for: .extendedForecast
        )
        engine.setStatus(days.isEmpty ? .noData : .loaded, for: .extendedForecast)
    }


    // MARK: - Hourly

    private func loadHourly(_ parameters: WeatherParameters) async {
        engine.setStatus(.loading, for: .hourly)
        engine.setStatus(.loading, for: .hourlyGraph)

        guard let urlString = parameters.point.properties.forecastHourly,
              let response = try? await client.forecast(urlString, units: settings.units)
        else {
            engine.setStatus(.failed, for: .hourly)
            engine.setStatus(.failed, for: .hourlyGraph)
            return
        }

        let units = forecastConverters
        let upcoming = response.properties.periods
            .filter { $0.endTime > Date() }
            .prefix(24)

        hourly = upcoming.map { period in
            let temperature = units.temperature.value(period.temperature)
            let speed = period.windSpeedValue

            // The hourly forecast carries no apparent temperature, so derive the same
            // way the displays do: heat index above 26C, wind chill below 10C.
            var apparent = ""
            var apparentValue: Double?
            var isHeatIndex = false
            var isWindChill = false
            if let celsius = period.temperature {
                if celsius >= 26.7 {
                    apparentValue = temperature
                    apparent = temperature.map { String(Int($0)) } ?? ""
                    isHeatIndex = true
                } else if celsius <= 10, let speed, speed > 4.8 {
                    apparentValue = temperature
                    apparent = temperature.map { String(Int($0)) } ?? ""
                    isWindChill = true
                }
            }

            return HourlyRow(
                time: period.startTime,
                hourLabel: Self.hourLabel(for: period.startTime, in: timeZone),
                icon: IconMapper.smallIcon(for: period.icon, isNight: !period.isDaytime),
                temperature: units.temperature(period.temperature),
                apparent: apparent,
                wind: speed.map { "\(period.windDirection ?? "") \(Int($0))" } ?? "-",
                isHeatIndex: isHeatIndex,
                isWindChill: isWindChill,
                temperatureValue: temperature,
                apparentValue: apparentValue,
                precipitationChance: period.probabilityOfPrecipitation?.value,
                dewpointValue: units.temperatureValue(period.dewpoint),
                skyCoverValue: Self.skyCover(fromIcon: period.icon)
            )
        }

        let status: DisplayStatus = hourly.isEmpty ? .noData : .loaded
        // The hourly list scrolls; the view sets its real timing after measuring.
        engine.setStatus(status, for: .hourly)
        engine.setTiming(
            DisplayTiming(totalScreens: 1, baseDelay: 9000, delay: .uniform(2)),
            for: .hourlyGraph
        )
        engine.setStatus(status, for: .hourlyGraph)
    }

    /// Percent sky cover for the Hourly Graph.
    ///
    /// The hourly forecast endpoint carries no `skyCover` series — that lives in the
    /// much larger raw gridpoint payload. The forecast icon's leading token *is* the
    /// NWS's own sky-cover classification, so it is mapped to the midpoint of each
    /// category's okta range rather than fetching a second, far heavier resource.
    nonisolated static func skyCover(fromIcon icon: String?) -> Double? {
        guard let icon, let parsed = ParsedIcon(iconURL: icon) else { return nil }
        // Strip a "wind_" prefix, which qualifies the cover rather than replacing it.
        let token = parsed.condition.replacingOccurrences(of: "wind_", with: "")

        return switch token {
        case "skc", "hot", "cold": 0
        case "few": 20
        case "sct": 40
        case "bkn": 70
        case "ovc", "fog", "rain", "snow", "tsra", "tsra_sct", "tsra_hi",
             "rain_snow", "sleet", "fzra", "rain_fzra", "snow_fzra", "blizzard": 100
        case "haze", "smoke", "dust": 50
        default: nil
        }
    }

    // MARK: - Travel

    private func loadTravel(_ parameters: WeatherParameters) async {
        engine.setStatus(.loading, for: .travel)
        let units = forecastConverters
        let cities = BundledData.travelCities

        guard !cities.isEmpty else {
            engine.setStatus(.noData, for: .travel)
            return
        }

        // Fetch the national cities concurrently but keep the table's fixed order.
        var results: [String: TravelRow] = [:]
        await withTaskGroup(of: (String, TravelRow?).self) { group in
            for city in cities {
                group.addTask { [client] in
                    guard let point = city.point else { return (city.name, nil) }
                    guard let response = try? await client.forecastForGrid(
                        office: point.wfo,
                        x: point.x,
                        y: point.y,
                        units: units.system
                    ) else { return (city.name, nil) }

                    let periods = response.properties.periods.filter { $0.endTime > Date() }
                    let day = periods.first { $0.isDaytime }
                    let night = periods.first { !$0.isDaytime }

                    return (
                        city.name,
                        TravelRow(
                            city: city.name,
                            icon: day.map { IconMapper.smallIcon(for: $0.icon, isNight: false) },
                            low: night.map { units.temperature($0.temperature) } ?? "-",
                            high: day.map { units.temperature($0.temperature) } ?? "-",
                            isUnavailable: day == nil
                        )
                    )
                }
            }
            for await (name, row) in group {
                if let row { results[name] = row }
            }
        }

        travel = cities.compactMap { results[$0.name] }

        if travel.isEmpty {
            engine.setStatus(.noData, for: .travel)
        } else {
            engine.setStatus(.loaded, for: .travel)
        }
    }

    // MARK: - Regional

    private func loadRegional(_ parameters: WeatherParameters) async {
        engine.setStatus(.loading, for: .regionalForecast)
        let units = forecastConverters

        let nearby = BundledData.regionalCities(
            near: parameters.latitude,
            longitude: parameters.longitude,
            limit: 15
        )
        guard !nearby.isEmpty else {
            engine.setStatus(.noData, for: .regionalForecast)
            return
        }

        // Three screens: current conditions, then the next two forecast periods.
        var byCity: [String: [ForecastPeriod]] = [:]
        await withTaskGroup(of: (String, [ForecastPeriod]).self) { group in
            for city in nearby {
                group.addTask { [client] in
                    guard let point = city.point,
                          let response = try? await client.forecastForGrid(
                              office: point.wfo, x: point.x, y: point.y, units: units.system
                          )
                    else { return (city.city, []) }
                    return (city.city, response.properties.periods.filter { $0.endTime > Date() })
                }
            }
            for await (city, periods) in group {
                byCity[city] = periods
            }
        }

        var screens: [RegionalScreen] = []
        for screenIndex in 0..<3 {
            var entries: [RegionalObservation] = []
            var title = "Regional Observations"

            for city in nearby {
                guard let periods = byCity[city.city], periods.indices.contains(screenIndex) else {
                    continue
                }
                let period = periods[screenIndex]
                if screenIndex > 0, let name = period.name { title = name }

                entries.append(
                    RegionalObservation(
                        city: city.city,
                        icon: IconMapper.smallIcon(for: period.icon, isNight: !period.isDaytime),
                        temperature: units.temperature(period.temperature),
                        latitude: city.latitude,
                        longitude: city.longitude
                    )
                )
            }

            guard !entries.isEmpty else { continue }
            screens.append(
                RegionalScreen(index: screenIndex, title: title, observations: entries)
            )
        }

        regionalScreens = screens
        engine.setTiming(
            DisplayTiming(totalScreens: max(screens.count, 1), baseDelay: 9000, delay: .uniform(1)),
            for: .regionalForecast
        )
        engine.setStatus(screens.isEmpty ? .noData : .loaded, for: .regionalForecast)
    }

    // MARK: - Hazards

    private func loadHazards(_ parameters: WeatherParameters) async {
        engine.setStatus(.loading, for: .hazards)

        guard let collection = try? await client.activeAlerts(
            latitude: parameters.latitude,
            longitude: parameters.longitude
        ) else {
            // No hazards is the normal case, so a failure here should not surface as
            // an error; just leave the display out of the rotation.
            hazards = []
            engine.setTiming(.empty, for: .hazards)
            engine.setStatus(.noData, for: .hazards)
            return
        }

        hazards = collection.features
            .sorted { $0.severityRank < $1.severityRank }
            .map { alert in
                HazardItem(
                    id: alert.id,
                    event: alert.properties.event,
                    detail: alert.properties.headline
                        ?? alert.properties.areaDesc
                        ?? ""
                )
            }

        buildScroll(parameters)

        if hazards.isEmpty {
            engine.setTiming(.empty, for: .hazards)
            engine.setStatus(.noData, for: .hazards)
        } else {
            engine.setStatus(.loaded, for: .hazards)
        }
    }

    // MARK: - SPC Outlook

    private func loadSPCOutlook(_ parameters: WeatherParameters) async {
        engine.setStatus(.loading, for: .spcOutlook)

        spcOutlook = await SPCOutlookService.shared.outlook(
            latitude: parameters.latitude,
            longitude: parameters.longitude
        )

        // The display is still worth showing when there is no risk — it reports the
        // all-clear, which is what upstream does.
        engine.setTiming(.standard, for: .spcOutlook)
        engine.setStatus(.loaded, for: .spcOutlook)
    }

    // MARK: - Radar

    private func loadRadar(_ parameters: WeatherParameters) async {
        engine.setStatus(.loading, for: .radar)

        guard let frames = try? await RadarService.shared.frames(
            latitude: parameters.latitude,
            longitude: parameters.longitude
        ), !frames.isEmpty else {
            radar = nil
            engine.setTiming(.empty, for: .radar)
            engine.setStatus(.noData, for: .radar)
            return
        }

        radar = RadarData(frames: frames, baseMap: nil)

        // Radar's timing loops the frames three times: a long hold on the newest
        // frame, then a fast run through the older ones. Ported from `radar.mjs`.
        let lastIndex = frames.count - 1
        var steps: [DisplayDelay.Step] = []
        for _ in 0..<3 {
            steps.append(DisplayDelay.Step(time: 4, screenIndex: lastIndex))
            for index in 0..<lastIndex {
                steps.append(DisplayDelay.Step(time: 1, screenIndex: index))
            }
        }
        steps.append(DisplayDelay.Step(time: 4, screenIndex: lastIndex))

        engine.setTiming(
            DisplayTiming(totalScreens: frames.count, baseDelay: 350, delay: .sequence(steps)),
            for: .radar
        )
        engine.setStatus(.loaded, for: .radar)
    }

    // MARK: - Almanac

    private func loadAlmanac(_ parameters: WeatherParameters) {
        engine.setStatus(.loading, for: .almanac)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = parameters.timeZone
        let today = Date()

        let days = (0..<7).map { offset -> AlmanacDay in
            let date = calendar.date(byAdding: .day, value: offset, to: today) ?? today
            let sun = SunCalc.sunTimes(
                date: date,
                latitude: parameters.latitude,
                longitude: parameters.longitude
            )
            let moon = SunCalc.moonTimes(
                date: date,
                latitude: parameters.latitude,
                longitude: parameters.longitude,
                timeZone: parameters.timeZone
            )

            return AlmanacDay(
                offset: offset,
                dayName: Self.longDayName(for: date, in: parameters.timeZone),
                sunrise: Self.columnTime(sun.sunrise, in: parameters.timeZone),
                sunset: Self.columnTime(sun.sunset, in: parameters.timeZone),
                moonrise: Self.columnTime(moon.rise, in: parameters.timeZone),
                moonset: Self.columnTime(moon.set, in: parameters.timeZone)
            )
        }

        almanac = AlmanacData(days: days, moonPhases: MoonPhase.upcoming())
        engine.setTiming(.standard, for: .almanac)
        engine.setStatus(.loaded, for: .almanac)
    }

    // MARK: - Scroll ticker

    private func buildScroll(_ parameters: WeatherParameters) {
        var lines: [String] = []

        // Each line has to fit the ticker's ~530pt text area at 32pt, which is about
        // 34 characters. Pairing two measurements per line overflowed it, so keep the
        // pairs short and give the wordier readings a line of their own.
        if let current = currentConditions {
            lines.append("Conditions at \(current.locationName)")
            lines.append("Temp: \(current.temperature)   Wind: \(current.wind)")
            if let gust = current.windGust {
                lines.append(gust)
            }
            lines.append("Humidity: \(current.humidity)   Dewpoint: \(current.dewpoint)")
            if !current.pressure.hasPrefix("-") {
                lines.append("Pressure: \(current.pressure)\(converters.pressure.units)")
            }
            lines.append("Visibility: \(current.visibility)")
            lines.append("Ceiling: \(current.ceiling)")
            if let apparentLabel = current.apparentLabel, let apparentValue = current.apparentValue {
                lines.append("\(apparentLabel) \(apparentValue)")
            }
        }

        scroll = ScrollContent(
            header: parameters.cityName,
            lines: lines,
            hazardHeadline: hazards.first.map { "\($0.event.uppercased()) - \($0.detail)" }
        )
    }

    // MARK: - Date formatting
    //
    // Formatters are built per call rather than cached: they are cheap next to the
    // network work, and a cached one would need invalidating whenever the point's
    // time zone changes.

    nonisolated private static func formatter(
        _ format: String,
        in timeZone: TimeZone
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    /// "WED", for the extended forecast panels.
    nonisolated static func shortDayName(for date: Date, in timeZone: TimeZone) -> String {
        formatter("EEE", in: timeZone).string(from: date).uppercased()
    }

    /// "Wednesday", for the almanac rows.
    nonisolated static func longDayName(for date: Date, in timeZone: TimeZone) -> String {
        formatter("EEEE", in: timeZone).string(from: date)
    }

    /// "3 PM", for the hourly rows.
    nonisolated static func hourLabel(for date: Date, in timeZone: TimeZone) -> String {
        formatter("h a", in: timeZone).string(from: date).uppercased()
    }

    /// "7:12 AM", padded so mixed-width times align in a column. A missing time
    /// renders as a dash — the moon does not rise every day.
    nonisolated static func columnTime(_ date: Date?, in timeZone: TimeZone) -> String {
        guard let date else { return "-" }
        let text = formatter("h:mm a", in: timeZone).string(from: date).uppercased()
        // Pad single-digit hours so the colons line up.
        return text.count == 7 ? "\u{00A0}\(text)" : text
    }

    /// Clock line for the header: "11:35:08 PM".
    public func clockText(_ date: Date = Date()) -> String {
        let format = settings.clockSeconds ? "h:mm:ss a" : "h:mm a"
        return Self.formatter(format, in: timeZone)
            .string(from: date)
            .uppercased()
    }

    /// Date line for the header: "WED AUG 03".
    public func dateText(_ date: Date = Date()) -> String {
        Self.formatter("EEE MMM d", in: timeZone)
            .string(from: date)
            .uppercased()
    }
}
