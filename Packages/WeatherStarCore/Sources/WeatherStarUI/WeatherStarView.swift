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

    /// Current burn-in offset.
    ///
    /// Held in state and updated by a slow loop rather than read from a `TimelineView`:
    /// the offset only changes every 90 seconds, and a timeline would rebuild the whole
    /// canvas on every frame to deliver a value that is almost always identical.
    @State private var burnInOffset: CGPoint = .zero

    /// Whether the Metal tube is both asked for and actually present.
    ///
    /// Falls back to the drawn overlay rather than to nothing, so a build without the
    /// metallib still looks intentional instead of losing the effect.
    private var usesTube: Bool {
        settings.screenEffect == .tube && CRTEffect.isAvailable
    }

    /// Drifting lines on the GPU: asked for, and the shader is there.
    private var usesShaderLines: Bool {
        settings.screenEffect == .animated && CRTEffect.isAvailable
    }

    /// Whether the drawn `Canvas` overlay is doing the work.
    ///
    /// Still the right choice for `.plain`: a static overlay rasterises once and costs
    /// nothing per frame, where a shader would add a pass to every frame to draw something
    /// that never changes.
    private var usesDrawnOverlay: Bool {
        !usesTube && !usesShaderLines
    }

    private var shaderLineSettings: ScanlineShaderSettings? {
        guard usesShaderLines else { return nil }
        let thickness = Scanlines.designThickness(for: settings.scanlines)
        guard thickness > 0 else { return nil }
        return ScanlineShaderSettings(
            depth: scanlineDepth,
            // The same 480-line pitch the tube uses.
            period: max(1.5, metricsHeightForLines / 480)
        )
    }

    /// Line darkness for the current scanline setting, shared by both shader paths.
    private var scanlineDepth: Double {
        switch settings.scanlines {
        case .off: 0
        case .hairline: 0.12
        case .thin: 0.18
        case .medium: 0.24
        case .thick: 0.32
        }
    }

    /// Canvas height in points, captured for the line pitch.
    @State private var metricsHeightForLines: CGFloat = 480

    private func tubeSettings(metrics: StarMetrics) -> CRTSettings? {
        guard usesTube else { return nil }
        var tube = CRTSettings()

        // The scanline choice still governs how heavy the lines are; `.off` means a clean
        // tube with curvature and bloom but no mask.
        tube.scanlineDepth = scanlineDepth

        // One line per row of the original 480-line raster, which is what a tube actually
        // did and keeps the pitch proportional to the picture at any resolution.
        //
        // Two earlier attempts were both wrong in opposite directions. A fixed 2-point
        // period is too fine once the canvas is scaled up; borrowing the `Canvas` overlay's
        // design-space thickness is far too coarse — that path deliberately draws chunky
        // lines, and at 4K one dark band came out wider than the ticker's small label is
        // tall, so it looked like the text had its top sliced off.
        if Scanlines.designThickness(for: settings.scanlines) > 0 {
            tube.linePeriod = max(1.5, metrics.scaledSize.height / 480)
        }
        return tube
    }

    /// One sentence describing what is on screen, since the canvas is one element.
    private var accessibilitySummary: String {
        let place = settings.savedLocation?.name
        let display = engine.activeDisplay?.name ?? "Loading"
        return place.map { "\(display) for \($0)" } ?? display
    }

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

                // The canvas and its scanlines shift together. Offsetting only the canvas
                // would slide the content out from under a fixed line pattern, which reads
                // as the picture tearing rather than as a still image.
                ZStack {
                    IconAnimationClock {
                        canvas(metrics: metrics)
                            .environment(\.starMetrics, metrics)
                    }

                    // Both shader paths draw their own lines, so the overlay would double
                    // them up — and for the tube it would curve one set and not the other,
                    // since the shader keys its mask off the face of the glass.
                    if usesDrawnOverlay {
                        Scanlines(
                            mode: settings.scanlines,
                            animated: settings.screenEffect == .animated
                        )
                        .environment(\.starMetrics, metrics)
                        .frame(width: metrics.scaledSize.width, height: metrics.scaledSize.height)
                    }
                }
                // Collapsed into a single accessibility element.
                //
                // A device profile put ~44% of all main-thread time in
                // `AccessibilityViewGraph.needsUpdate`, and 37% in
                // `AccessibilityNode.visibility.getter` alone — SwiftUI rebuilding an
                // accessibility attachment for every node on every display-link tick. The
                // displays are decorative pixel art built from thousands of views, because
                // `StarText` alone is six per label, so that tree is enormous and none of it
                // is useful to a screen reader glyph by glyph. Ignoring the children stops
                // the walk; the label below keeps the screen described.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilitySummary)
                .offset(x: burnInOffset.x, y: burnInOffset.y)
                // Opaque before the shader samples it. A layer with transparent regions
                // makes every per-channel read a premultiplied one, and the tube has to
                // guess at alpha it cannot reconstruct; giving it a solid picture removes
                // the question. The outer black is still there for the letterbox.
                .background(Color.black)
                .crtEffect(tubeSettings(metrics: metrics), size: proxy.size)
                .scanlineEffect(shaderLineSettings, size: proxy.size)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onAppear {
                metricsWidth = space.width
                metricsHeightForLines = metrics.scaledSize.height
            }
            .onChange(of: space.width) { _, width in metricsWidth = width }
            .onChange(of: metrics.scaledSize.height) { _, height in
                metricsHeightForLines = height
            }
        }
        .ignoresSafeArea()
        .background(Color.black)
        .task(id: settings.burnInProtection) { await driveBurnInShift() }
    }

    /// Step the burn-in offset on a wall-clock schedule.
    ///
    /// Aligned to the clock rather than to launch, so the position does not depend on when
    /// the app happened to start and the first move is not an immediate jump.
    private func driveBurnInShift() async {
        guard settings.burnInProtection else {
            burnInOffset = .zero
            return
        }
        while !Task.isCancelled {
            let now = Date().timeIntervalSinceReferenceDate
            burnInOffset = BurnInShift.offset(at: now)

            let untilNextStep = BurnInShift.stepInterval
                - now.truncatingRemainder(dividingBy: BurnInShift.stepInterval)
            try? await Task.sleep(for: .seconds(max(1, untilNextStep)))
        }
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
            titleOverride: (StarBranding.startupTitle, StarBranding.startupSubtitle),
            clockInterval: settings.clockSeconds ? 1 : 15,
            clockFormat: { (store.clockText($0), store.dateText($0)) }
        ) {
            VStack(spacing: 0) {
                // The progress list absorbs the slack and is clipped if it runs long,
                // instead of a `Spacer` letting it push the block below off the panel.
                // With enough displays enabled it did exactly that, and the credit, the
                // link and the progress bar all fell off the bottom of the screen.
                ProgressDisplay(
                    displays: DisplayIdentifier.rotationOrder.filter { settings.isEnabled($0) },
                    statusFor: { engine.state(for: $0).status }
                )
                .frame(maxHeight: .infinity, alignment: .top)
                .clipped()

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
