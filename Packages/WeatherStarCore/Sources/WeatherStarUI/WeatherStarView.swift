import SwiftUI
import WeatherStarKit

/// The WeatherStar screen: background, the active display, and the ticker, scaled to
/// fill whatever it is given.
public struct WeatherStarView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DisplayEngine.self) private var engine
    @Environment(WeatherStore.self) private var store

    /// Width of the resolved design space, for the credit line on the startup screen.
    @State private var metricsWidth: CGFloat = 640

    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            let space = DesignSpace.resolve(for: settings.layoutMode, container: proxy.size)
            let metrics = StarMetrics(space: space, container: proxy.size)

            // A ZStack already centres its children, so `metrics.origin` — the
            // letterbox offset — must *not* be applied on top of that: doing so shifted
            // the canvas right and down by the full letterbox amount instead of half.
            // It went unnoticed on Apple TV, where the wide canvas exactly fills a 16:9
            // screen and the origin is zero, but pushed the layout off-centre on a
            // taller phone.
            ZStack {
                Color.black

                canvas(metrics: metrics)
                    .environment(\.starMetrics, metrics)

                Scanlines(mode: settings.scanlines)
                    .environment(\.starMetrics, metrics)
                    .frame(width: metrics.scaledSize.width, height: metrics.scaledSize.height)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onAppear { metricsWidth = space.width }
            .onChange(of: space.width) { _, width in metricsWidth = width }
        }
        .ignoresSafeArea()
        .background(Color.black)
    }

    /// The scaled canvas: either the startup screen or the active display.
    ///
    /// No timeline here on purpose. The clock supplies its own inside the header, so a
    /// tick repaints two labels rather than rebuilding every display each second.
    @ViewBuilder
    private func canvas(metrics: StarMetrics) -> some View {
        if let active = engine.activeDisplay {
            activeDisplay(active, metrics: metrics)
        } else {
            startupScreen
        }
    }

    // MARK: - Startup

    private var startupScreen: some View {
        StarDisplayFrame(
            display: .currentWeather,
            titleOverride: ("WeatherStar", "4000+"),
            clockInterval: settings.clockSeconds ? 1 : 15,
            clockFormat: { (store.clockText($0), store.dateText($0)) }
        ) {
            VStack(spacing: 0) {
                ProgressDisplay(
                    displays: DisplayIdentifier.rotationOrder.filter { settings.isEnabled($0) },
                    statusFor: { engine.state(for: $0).status }
                )
                Spacer(minLength: 0)

                // Credit the project this is ported from, on the screen every launch
                // passes through.
                StarText(
                    "Based on WeatherStar 4000+ by Matt Walsh",
                    font: .small,
                    size: 24,
                    alignment: .center,
                    lineLimit: 1,
                    minimumScaleFactor: 0.6
                )
                .designFrame(width: metricsWidth, alignment: .center)

                StarText(
                    "github.com/netbymatt/ws4kp",
                    font: .small,
                    size: 24,
                    color: StarColor.title,
                    alignment: .center,
                    lineLimit: 1,
                    minimumScaleFactor: 0.6
                )
                .designFrame(width: metricsWidth, alignment: .center)
                .designPadding(.bottom, 10)

                ProgressBar(progress: store.loadProgress)
                    .designPadding(.bottom, 20)
            }
        }
    }

    // MARK: - Active display

    // No `@ViewBuilder`: the single explicit `return` below would disable the builder
    // anyway, which the compiler warns about.
    private func activeDisplay(
        _ display: DisplayIdentifier,
        metrics: StarMetrics
    ) -> some View {
        let state = engine.state(for: display)

        return StarDisplayFrame(
            display: display,
            titleOverride: titleOverride(for: display),
            scroll: display.showsScroll ? store.scroll : nil,
            clockInterval: settings.clockSeconds ? 1 : 15,
            clockFormat: { (store.clockText($0), store.dateText($0)) }
        ) {
            displayContent(display, state: state, metrics: metrics)
        }
        // Recomputed whenever the display or its row count changes; the content
        // height is derived from the data, not from a layout round-trip.
        .task(id: TimingKey(display: display, rowCount: scrollRowCount(for: display))) {
            updateScrollTiming(for: display, metrics: metrics)
        }
    }

    /// Current Conditions says "Recent" instead of "Current" for stale observations.
    private func titleOverride(for display: DisplayIdentifier) -> (top: String, bottom: String?)? {
        switch display {
        case .currentWeather:
            guard store.currentConditions?.isStale == true else { return nil }
            return ("Recent", "Conditions")
        case .travel:
            return ("Travel Forecast", "For \(store.travel.isEmpty ? "" : "Tomorrow")")
        case .regionalForecast:
            guard let screen = store.regionalScreens.first(where: {
                $0.index == engine.state(for: .regionalForecast).screenIndex
            }) else { return nil }
            return screen.index == 0 ? nil : ("Regional", "Forecast")
        default:
            return nil
        }
    }

    @ViewBuilder
    private func displayContent(
        _ display: DisplayIdentifier,
        state: DisplayState,
        metrics: StarMetrics
    ) -> some View {
        let offset = engine.scrollOffset(for: display)

        switch display {
        case .currentWeather:
            if let data = store.currentConditions {
                CurrentConditionsDisplay(data: data)
            }

        case .latestObservations:
            LatestObservationsDisplay(rows: store.observations, unitSystem: settings.units)

        case .hourly:
            HourlyDisplay(rows: store.hourly, scrollOffset: offset)

        case .hourlyGraph:
            HourlyGraphDisplay(
                rows: store.hourly,
                temperatureUnit: settings.units == .us ? "F" : "C",
                timeZone: store.timeZone
            )

        case .travel:
            TravelDisplay(rows: store.travel, scrollOffset: offset)

        case .regionalForecast:
            if let screen = store.regionalScreens.first(where: { $0.index == state.screenIndex })
                ?? store.regionalScreens.first,
                let location = store.parameters?.location {
                RegionalDisplay(screen: screen, center: location)
            }

        case .localForecast:
            if let data = store.localForecast {
                LocalForecastDisplay(data: data, scrollOffset: offset)
            }

        case .extendedForecast:
            ExtendedForecastDisplay(days: store.extendedDays, screenIndex: state.screenIndex)

        case .almanac:
            if let data = store.almanac {
                AlmanacDisplay(data: data)
            }

        case .hazards:
            HazardsDisplay(hazards: store.hazards)

        case .spcOutlook:
            SPCOutlookDisplay(data: store.spcOutlook)

        case .radar:
            RadarDisplay(
                data: store.radar,
                screenIndex: state.screenIndex,
                center: store.parameters?.location,
                timeZone: store.timeZone
            )
        }
    }

    /// Content height of a scrolling display, computed from its data.
    ///
    /// This used to come from measuring the rendered view, but each of these views is
    /// clipped to its viewport, so the measurement always came back as the viewport
    /// height — scroll distance worked out to zero and nothing ever moved. Deriving it
    /// from the row count or the wrapped text metrics gives the real value.
    private func contentHeight(
        for display: DisplayIdentifier,
        contentWidth: CGFloat
    ) -> CGFloat {
        switch display {
        case .hourly:
            HourlyDisplay.contentHeight(rowCount: store.hourly.count)
        case .travel:
            TravelDisplay.contentHeight(rowCount: store.travel.count)
        case .localForecast:
            store.localForecast.map {
                LocalForecastDisplay.contentHeight(
                    for: $0,
                    textWidth: LocalForecastDisplay.textWidth(for: contentWidth)
                )
            } ?? 0
        default:
            0
        }
    }

    /// Recompute scroll distance and dwell time for a scrolling display.
    private func updateScrollTiming(for display: DisplayIdentifier, metrics: StarMetrics) {
        guard [.hourly, .travel, .localForecast].contains(display) else { return }

        // Local Forecast is inset inside the blue panel; the tables span the canvas.
        let width = display.expandsToWideCanvas ? metrics.space.width : 640
        let height = contentHeight(for: display, contentWidth: width)
        guard height > 0 else { return }

        let viewport = display == .localForecast
            ? LocalForecastDisplay.viewport
            : metrics.space.scrollHeight

        let (timing, scroll) = DisplayTiming.scrolling(
            contentHeight: height,
            viewportHeight: viewport
        )
        engine.setTiming(timing, scroll: scroll, for: display)
    }

    /// Identity for the timing task, so it re-runs only on a real change.
    private struct TimingKey: Equatable {
        let display: DisplayIdentifier
        let rowCount: Int
    }

    /// How much content a scrolling display currently has, used as the task identity.
    private func scrollRowCount(for display: DisplayIdentifier) -> Int {
        switch display {
        case .hourly: store.hourly.count
        case .travel: store.travel.count
        case .localForecast: store.localForecast?.paragraphs.count ?? 0
        default: 0
        }
    }
}
