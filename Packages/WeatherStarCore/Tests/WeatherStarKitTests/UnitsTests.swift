import Testing
@testable import WeatherStarKit

@Suite("Unit conversion")
struct UnitsTests {
    @Test("US temperature converts Celsius to Fahrenheit")
    func temperatureUS() {
        let converter = UnitConverter.temperature(for: .us)
        #expect(converter(0) == "32")
        #expect(converter(100) == "212")
        #expect(converter(21.5) == "71")
        #expect(converter.units == "F")
    }

    @Test("Metric temperature passes Celsius through, rounded")
    func temperatureSI() {
        let converter = UnitConverter.temperature(for: .si)
        #expect(converter(21.4) == "21")
        #expect(converter(21.6) == "22")
        #expect(converter.units == "C")
    }

    @Test("A missing value renders as a dash, as the displays expect")
    func missingValues() {
        #expect(UnitConverter.temperature(for: .us)(nil) == "-")
        #expect(UnitConverter.windSpeed(for: .us)(nil) == "-")
        #expect(UnitConverter.pressure(for: .us)(nil) == "-")
        #expect(UnitConverter.temperature(for: .us).value(nil) == nil)
    }

    @Test("Wind speed converts km/h to MPH")
    func windSpeed() {
        let converter = UnitConverter.windSpeed(for: .us)
        #expect(converter(16.0934) == "10")
        #expect(converter.units == "MPH")
    }

    @Test("Pressure converts pascals to inHg with two decimals")
    func pressureUS() {
        let converter = UnitConverter.pressure(for: .us)
        // 101325 Pa is standard sea-level pressure, 29.92 inHg.
        #expect(converter(101_325) == "29.92")
        #expect(converter.units == " in.hg")
    }

    @Test("Pressure in metric reports whole millibars")
    func pressureSI() {
        let converter = UnitConverter.pressure(for: .si)
        #expect(converter(101_325) == "1013")
        #expect(converter.units == " mbar")
    }

    @Test("Ceiling in feet rounds to the nearest hundred")
    func ceilingUS() {
        let converter = UnitConverter.distanceMeters(for: .us)
        // 1000 m is 3281 ft, which the display rounds to 3300.
        #expect(converter(1000) == "3300")
        #expect(converter.units == "ft.")
    }

    @Test("Visibility converts meters to whole miles")
    func visibilityUS() {
        let converter = UnitConverter.distanceKilometers(for: .us)
        #expect(converter(16_093) == "10")
        #expect(converter.units == " mi.")
    }

    @Test("round2 truncates rather than rounding, matching upstream")
    func round2Truncates() {
        #expect(Convert.round2(29.9299, 2) == 29.92)
        #expect(Convert.round2(29.9999, 2) == 29.99)
    }
}

@Suite("Compass directions")
struct CalcTests {
    @Test("Degrees map to compass points")
    func directions() {
        #expect(Calc.directionToNSEW(0) == "N")
        #expect(Calc.directionToNSEW(90) == "E")
        #expect(Calc.directionToNSEW(180) == "S")
        #expect(Calc.directionToNSEW(270) == "W")
        #expect(Calc.directionToNSEW(200) == "SSW")
    }

    @Test("360 degrees wraps back to north rather than overflowing")
    func wrapsAtFullCircle() {
        #expect(Calc.directionToNSEW(360) == "N")
        #expect(Calc.directionToNSEW(354) == "N")
    }

    @Test("A missing direction reports as variable")
    func missingDirection() {
        #expect(Calc.directionToNSEW(nil) == "VAR")
        #expect(Calc.directionToNSEW(.nan) == "VAR")
    }

    @Test("Haversine distance is accurate for a known pair")
    func haversine() {
        // Orlando to Tampa is about 118 km.
        let distance = Calc.haversineKilometers(
            lat1: 28.5383, lon1: -81.3792,
            lat2: 27.9506, lon2: -82.4572
        )
        #expect(distance > 110 && distance < 125)
    }
}

@Suite("String helpers")
struct StringUtilsTests {
    @Test("Station names are cleaned the way upstream cleans them")
    func locationCleanup() {
        #expect("Chicago / West Chicago".locationCleanup == "West Chicago")
        #expect("Chicago/Waukegan".locationCleanup == "Waukegan")
        #expect("Chicago, Chicago O'hare".locationCleanup == "Chicago O'hare")
        #expect("Orlando".locationCleanup == "Orlando")
    }

    @Test("Long conditions are abbreviated to fit the field")
    func shortConditions() {
        #expect(ConditionText.shorten("Light Rain") == "L Rain")
        #expect(ConditionText.shorten("Thunderstorm") == "T'storm")
        #expect(ConditionText.shorten("Partly Cloudy") == "P Cloudy")
        #expect(ConditionText.shorten("Freezing Rain") == "Frz Rn")
    }
}

@Suite("Unit converter sources")
struct UnitConverterSourceTests {
    @Test("Observation converters translate metric into the user's system")
    func observationsConvertFromMetric() {
        // Station observations always arrive metric, whatever the user picked.
        let converters = UnitConverters(system: .us)
        #expect(converters.source == .si)
        #expect(converters.temperature(0) == "32", "0C should read as 32F")
    }

    @Test("Forecast converters pass through when data is already in the user's system")
    func forecastsPassThrough() {
        // Forecast endpoints honour a units parameter, including in their narrative
        // text, so the data is requested in the user's system and must not be
        // converted again — that is what made "High near 88" read as "High near 31".
        let converters = UnitConverters(system: .us, source: .us)
        #expect(converters.source == .us)
        #expect(converters.temperature(88) == "88", "already Fahrenheit; must not convert")
        #expect(converters.temperature.units == "F")

        let metric = UnitConverters(system: .si, source: .si)
        #expect(metric.temperature(31) == "31")
        #expect(metric.temperature.units == "C")
    }

    @Test("Wind and pressure also respect the source system")
    func otherUnitsRespectSource() {
        let passthrough = UnitConverters(system: .us, source: .us)
        #expect(passthrough.windSpeed(15) == "15", "already MPH")
        let converting = UnitConverters(system: .us, source: .si)
        #expect(converting.windSpeed(16.0934) == "10", "16 kph is 10 mph")
    }
}

@Suite("Quantitative value units")
struct QuantitativeUnitTests {
    @Test("A Celsius value is converted even when the request asked for US units")
    func celsiusValueConvertsDespiteRequestUnits() {
        // The forecast endpoints honour `units` for plain numbers and narrative text,
        // but a QuantitativeValue keeps its own unitCode and stays Celsius. Trusting
        // the request's units plotted a 23C dewpoint against an 88F temperature.
        let forecast = UnitConverters(system: .us, source: .us)
        let dewpoint = QuantitativeValue(value: 23, unitCode: "wmoUnit:degC")
        #expect(forecast.temperatureValue(dewpoint) == 73, "23C should read 73F")
        #expect(forecast.temperatureText(dewpoint) == "73")
    }

    @Test("A value already in the target unit passes through")
    func matchingUnitPassesThrough() {
        let forecast = UnitConverters(system: .us, source: .us)
        let value = QuantitativeValue(value: 88, unitCode: "wmoUnit:degF")
        #expect(forecast.temperatureValue(value) == 88)

        let metric = UnitConverters(system: .si, source: .si)
        #expect(metric.temperatureValue(QuantitativeValue(value: 23, unitCode: "wmoUnit:degC")) == 23)
    }

    @Test("An unknown or absent unit code falls back to the source system")
    func unknownUnitCodeFallsBack() {
        let observations = UnitConverters(system: .us, source: .si)
        // No unitCode: assume the source system, which for observations is metric.
        #expect(observations.temperatureValue(QuantitativeValue(value: 0)) == 32)
        #expect(observations.temperatureValue(QuantitativeValue(value: 0, unitCode: "bogus")) == 32)
    }

    @Test("A missing value reports as nil and a dash")
    func missingValue() {
        let converters = UnitConverters(system: .us)
        #expect(converters.temperatureValue(nil) == nil)
        #expect(converters.temperatureValue(QuantitativeValue(value: nil)) == nil)
        #expect(converters.temperatureText(nil) == "-")
    }
}
