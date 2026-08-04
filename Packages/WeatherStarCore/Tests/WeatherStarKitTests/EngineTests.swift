import Foundation
import Testing
@testable import WeatherStarKit

@Suite("Display timing")
struct DisplayTimingTests {
    @Test("A uniform delay gives each screen an equal share")
    func uniformDelay() {
        let timing = DisplayTiming(totalScreens: 3, baseDelay: 9000, delay: .uniform(1))
        #expect(timing.cumulativeDelays == [1, 2, 3])
        #expect(timing.screenIndexes == [0, 1, 2])
        #expect(timing.screenIndex(forBaseCount: 0) == 0)
        #expect(timing.screenIndex(forBaseCount: 1) == 1)
        #expect(timing.screenIndex(forBaseCount: 2) == 2)
    }

    @Test("Running past the last screen returns nil so the engine advances")
    func exhaustion() {
        let timing = DisplayTiming(totalScreens: 2, baseDelay: 9000, delay: .uniform(1))
        #expect(timing.screenIndex(forBaseCount: 1) == 1)
        #expect(timing.screenIndex(forBaseCount: 2) == nil)
    }

    @Test("An empty display is skipped immediately")
    func emptyDisplay() {
        #expect(DisplayTiming.empty.screenIndex(forBaseCount: 0) == nil)
    }

    @Test("A per-screen delay array defines the screen count")
    func perScreenDelay() {
        let timing = DisplayTiming(totalScreens: 99, baseDelay: 40, delay: .perScreen([5, 10, 2]))
        #expect(timing.totalScreens == 3)
        #expect(timing.cumulativeDelays == [5, 15, 17])
        #expect(timing.screenIndex(forBaseCount: 4) == 0)
        #expect(timing.screenIndex(forBaseCount: 5) == 1)
        #expect(timing.screenIndex(forBaseCount: 15) == 2)
        #expect(timing.screenIndex(forBaseCount: 17) == nil)
    }

    @Test("An explicit sequence can repeat a screen, as radar does")
    func sequenceRepeatsScreens() {
        // Radar's pattern: hold the newest frame, then run the older ones fast.
        let steps = [
            DisplayDelay.Step(time: 4, screenIndex: 5),
            DisplayDelay.Step(time: 1, screenIndex: 0),
            DisplayDelay.Step(time: 1, screenIndex: 1),
        ]
        let timing = DisplayTiming(totalScreens: 6, baseDelay: 350, delay: .sequence(steps))
        #expect(timing.cumulativeDelays == [4, 5, 6])
        #expect(timing.screenIndexes == [5, 0, 1])
        #expect(timing.screenIndex(forBaseCount: 0) == 5)
        #expect(timing.screenIndex(forBaseCount: 3) == 5)
        #expect(timing.screenIndex(forBaseCount: 4) == 0)
        #expect(timing.screenIndex(forBaseCount: 5) == 1)
    }

    @Test("Next/previous screen boundaries land on screen starts")
    func screenNavigation() {
        let timing = DisplayTiming(totalScreens: 3, baseDelay: 9000, delay: .perScreen([3, 3, 3]))
        #expect(timing.baseCountForNextScreen(after: 0) == 3)
        #expect(timing.baseCountForNextScreen(after: 3) == 6)
        #expect(timing.baseCountForPreviousScreen(before: 7) == 6)
        #expect(timing.baseCountForPreviousScreen(before: 2) == 0)
        #expect(timing.baseCountForLastScreen == 8)
    }

    @Test("Past the final screen the next boundary no longer maps to a screen")
    func nextBoundaryPastEnd() {
        let timing = DisplayTiming(totalScreens: 3, baseDelay: 9000, delay: .perScreen([3, 3, 3]))
        // The boundary itself is still reported — it is the end of the schedule …
        #expect(timing.baseCountForNextScreen(after: 8) == 9)
        // … but it maps to no screen, which is the engine's signal to move on.
        #expect(timing.screenIndex(forBaseCount: 9) == nil)
    }

    @Test("Content taller than the viewport scrolls for proportionally longer")
    func scrollingTiming() {
        let (short, shortScroll) = DisplayTiming.scrolling(
            contentHeight: 300, viewportHeight: 310
        )
        // Nothing to scroll: just the static hold.
        #expect(shortScroll.scrollableHeight == 0)
        #expect(shortScroll.offset(forBaseCount: 500) == 0)

        let (long, longScroll) = DisplayTiming.scrolling(
            contentHeight: 810, viewportHeight: 310, scrollSpeed: 50
        )
        // 500pt to scroll at 50pt/s is 10s, plus 3s before and 3s after.
        #expect(longScroll.scrollableHeight == 500)
        #expect(long.totalDuration > short.totalDuration)
        #expect(abs(long.totalDuration - 16) < 0.2)
    }

    @Test("Scroll offset holds, ramps, then clamps at the end")
    func scrollOffsetCurve() {
        let (_, scroll) = DisplayTiming.scrolling(
            contentHeight: 810, viewportHeight: 310, scrollSpeed: 50, baseDelay: 40
        )
        // Held still through the initial delay.
        #expect(scroll.offset(forBaseCount: 0) == 0)
        #expect(scroll.offset(forBaseCount: scroll.initialCounts) == 0)
        // Moving partway through.
        let midway = scroll.offset(forBaseCount: scroll.initialCounts + 125)
        #expect(midway > 0 && midway < 500)
        // Never scrolls past the end.
        #expect(scroll.offset(forBaseCount: 100_000) == 500)
    }
}

@Suite("Display rotation")
@MainActor
struct DisplayEngineTests {
    /// A display only joins the rotation once it is loaded with screens to show.
    @Test("Only loaded displays with screens enter the rotation")
    func readyDisplays() {
        let engine = DisplayEngine()
        engine.enabledDisplays = [.currentWeather, .almanac, .radar]

        engine.setTiming(.standard, for: .currentWeather)
        engine.setStatus(.loaded, for: .currentWeather)

        // Loaded but with zero screens: still skipped.
        engine.setTiming(.empty, for: .radar)
        engine.setStatus(.loaded, for: .radar)

        // Failed: skipped.
        engine.setStatus(.failed, for: .almanac)

        #expect(engine.readyDisplays == [.currentWeather])
        #expect(engine.activeDisplay == .currentWeather)
    }

    @Test("The rotation follows nav order and wraps around")
    func rotationOrder() {
        let engine = DisplayEngine()
        engine.isPlaying = false
        engine.enabledDisplays = [.currentWeather, .almanac, .extendedForecast]

        for display in [DisplayIdentifier.currentWeather, .extendedForecast, .almanac] {
            engine.setTiming(.standard, for: display)
            engine.setStatus(.loaded, for: display)
        }

        // Current Conditions (1) → Extended (8) → Almanac (9) → back to Current.
        #expect(engine.activeDisplay == .currentWeather)
        engine.nextDisplay()
        #expect(engine.activeDisplay == .extendedForecast)
        engine.nextDisplay()
        #expect(engine.activeDisplay == .almanac)
        engine.nextDisplay()
        #expect(engine.activeDisplay == .currentWeather)
    }

    @Test("Going backwards wraps to the last display")
    func previousWraps() {
        let engine = DisplayEngine()
        engine.isPlaying = false
        engine.enabledDisplays = [.currentWeather, .almanac]

        for display in [DisplayIdentifier.currentWeather, .almanac] {
            engine.setTiming(.standard, for: display)
            engine.setStatus(.loaded, for: display)
        }

        #expect(engine.activeDisplay == .currentWeather)
        engine.previousDisplay()
        #expect(engine.activeDisplay == .almanac)
    }

    @Test("Disabling the active display moves off it")
    func disablingActiveDisplay() {
        let engine = DisplayEngine()
        engine.isPlaying = false
        engine.enabledDisplays = [.currentWeather, .almanac]

        for display in [DisplayIdentifier.currentWeather, .almanac] {
            engine.setTiming(.standard, for: display)
            engine.setStatus(.loaded, for: display)
        }
        #expect(engine.activeDisplay == .currentWeather)

        engine.enabledDisplays = [.almanac]
        #expect(engine.activeDisplay == .almanac)
    }

    @Test("A display that fails while showing is left behind")
    func failureAdvances() {
        let engine = DisplayEngine()
        engine.isPlaying = false
        engine.enabledDisplays = [.currentWeather, .almanac]

        for display in [DisplayIdentifier.currentWeather, .almanac] {
            engine.setTiming(.standard, for: display)
            engine.setStatus(.loaded, for: display)
        }
        #expect(engine.activeDisplay == .currentWeather)

        engine.setStatus(.failed, for: .currentWeather)
        #expect(engine.activeDisplay == .almanac)
    }

    @Test("Advancing screens rolls into the next display at the end")
    func screenAdvanceRollsOver() {
        let engine = DisplayEngine()
        engine.isPlaying = false
        engine.enabledDisplays = [.extendedForecast, .almanac]

        engine.setTiming(
            DisplayTiming(totalScreens: 2, baseDelay: 9000, delay: .uniform(1)),
            for: .extendedForecast
        )
        engine.setStatus(.loaded, for: .extendedForecast)
        engine.setTiming(.standard, for: .almanac)
        engine.setStatus(.loaded, for: .almanac)

        #expect(engine.activeDisplay == .extendedForecast)
        #expect(engine.state(for: .extendedForecast).screenIndex == 0)

        engine.nextScreen()
        #expect(engine.activeDisplay == .extendedForecast)
        #expect(engine.state(for: .extendedForecast).screenIndex == 1)

        engine.nextScreen()
        #expect(engine.activeDisplay == .almanac)
    }

    @Test("Resetting clears every display and stops the rotation")
    func reset() {
        let engine = DisplayEngine()
        engine.setTiming(.standard, for: .currentWeather)
        engine.setStatus(.loaded, for: .currentWeather)
        #expect(engine.activeDisplay != nil)

        engine.resetAll()
        #expect(engine.activeDisplay == nil)
        #expect(engine.readyDisplays.isEmpty)
        #expect(engine.state(for: .currentWeather).status == .loading)
    }
}

@Suite("Display identifiers")
struct DisplayIdentifierTests {
    @Test("Rotation order matches upstream's nav ids")
    func rotationOrderMatchesUpstream() {
        #expect(DisplayIdentifier.rotationOrder.first == .hazards)
        #expect(DisplayIdentifier.hazards.order == 0)
        #expect(DisplayIdentifier.currentWeather.order == 1)
        #expect(DisplayIdentifier.radar.order == 11)
        // Every display has a distinct position.
        let orders = DisplayIdentifier.allCases.map(\.order)
        #expect(Set(orders).count == orders.count)
    }

    @Test("Raw values match upstream element ids, so configs port across")
    func rawValuesMatchUpstream() {
        #expect(DisplayIdentifier.currentWeather.rawValue == "current-weather")
        #expect(DisplayIdentifier.latestObservations.rawValue == "latest-observations")
        #expect(DisplayIdentifier.extendedForecast.rawValue == "extended-forecast")
    }

    @Test("Hourly and Travel stay off by default, as upstream has them")
    func defaultsMatchUpstream() {
        #expect(!DisplayIdentifier.hourly.isEnabledByDefault)
        #expect(!DisplayIdentifier.travel.isEnabledByDefault)
        #expect(DisplayIdentifier.currentWeather.isEnabledByDefault)
        #expect(DisplayIdentifier.almanac.isEnabledByDefault)
    }

    @Test("Hazards is drawn without header or ticker")
    func hazardsChrome() {
        #expect(!DisplayIdentifier.hazards.drawsHeader)
        #expect(!DisplayIdentifier.hazards.showsScroll)
        #expect(DisplayIdentifier.currentWeather.drawsHeader)
        #expect(DisplayIdentifier.currentWeather.showsScroll)
    }
}
