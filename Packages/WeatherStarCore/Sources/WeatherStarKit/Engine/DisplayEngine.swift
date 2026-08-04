import Foundation
import Observation
import OSLog

/// Per-display rotation state.
public struct DisplayState: Sendable {
    public var status: DisplayStatus = .loading
    public var timing: DisplayTiming = .standard
    public var scroll: ScrollTiming = .none
    /// Ticks accumulated while this display has been on screen.
    public var baseCount: Int = 0
    /// -1 means "not shown yet", matching upstream's sentinel.
    public var screenIndex: Int = -1

    /// A display only enters the rotation once it has data and screens to show.
    public var isReady: Bool {
        status == .loaded && timing.totalScreens > 0
    }
}

/// Drives the display rotation.
///
/// A single async loop ticks the *active* display at its own `baseDelay`, mirroring
/// upstream's per-display interval without running a dozen concurrent timers. When a
/// display runs out of screens the engine advances to the next ready one.
@MainActor
@Observable
public final class DisplayEngine {
    private let logger = Logger(subsystem: "net.weatherstar.kit", category: "DisplayEngine")

    public private(set) var states: [DisplayIdentifier: DisplayState] = [:]
    public private(set) var activeDisplay: DisplayIdentifier?

    public var isPlaying = true {
        didSet {
            guard isPlaying != oldValue else { return }
            if isPlaying { startLoop() } else { stopLoop() }
        }
    }

    /// Multiplier applied to every dwell time.
    public var speedMultiplier: Double = 1.0

    /// Displays the user has enabled, in rotation order.
    public var enabledDisplays: [DisplayIdentifier] = DisplayIdentifier.defaultEnabled {
        didSet {
            // Drop out of a display the user just turned off.
            if let active = activeDisplay, !enabledDisplays.contains(active) {
                advanceToNextReady(from: active)
            }
        }
    }

    /// Fires when the active display or its screen changes, so views can react.
    public var onScreenChange: (@MainActor (DisplayIdentifier, Int) -> Void)?

    // Reachable from `deinit`, which cannot touch main actor state. `Task.cancel()`
    // is safe from any isolation and this is only written on the main actor.
    @ObservationIgnored nonisolated(unsafe) private var loopTask: Task<Void, Never>?

    public init() {
        for display in DisplayIdentifier.allCases {
            states[display] = DisplayState()
        }
    }

    deinit {
        loopTask?.cancel()
    }

    // MARK: - State updates

    public func state(for display: DisplayIdentifier) -> DisplayState {
        states[display] ?? DisplayState()
    }

    public func setStatus(_ status: DisplayStatus, for display: DisplayIdentifier) {
        states[display, default: DisplayState()].status = status
        // Nothing is on screen yet, or the current display just became unusable.
        if activeDisplay == nil, status == .loaded {
            activateFirstReady()
        } else if activeDisplay == display, !state(for: display).isReady {
            advanceToNextReady(from: display)
        }
    }

    /// Update a display's timing. Views call this once they have measured content,
    /// which is how the scrolling displays get their real duration.
    public func setTiming(
        _ timing: DisplayTiming,
        scroll: ScrollTiming = .none,
        for display: DisplayIdentifier
    ) {
        var state = states[display] ?? DisplayState()
        state.timing = timing
        state.scroll = scroll
        // A timing change mid-display would otherwise leave the counter past the end.
        if activeDisplay == display, timing.screenIndex(forBaseCount: state.baseCount) == nil {
            state.baseCount = 0
            state.screenIndex = 0
        }
        states[display] = state

        if activeDisplay == nil, state.isReady {
            activateFirstReady()
        }
    }

    /// Reset every display to loading, e.g. after the location changes.
    public func resetAll() {
        for display in DisplayIdentifier.allCases {
            states[display] = DisplayState()
        }
        activeDisplay = nil
        stopLoop()
    }

    // MARK: - Rotation

    /// Displays that are enabled and have data, in rotation order.
    public var readyDisplays: [DisplayIdentifier] {
        DisplayIdentifier.rotationOrder.filter {
            enabledDisplays.contains($0) && state(for: $0).isReady
        }
    }

    private func activateFirstReady() {
        guard let first = readyDisplays.first else { return }
        activate(first)
        if isPlaying { startLoop() }
    }

    private func activate(_ display: DisplayIdentifier) {
        activeDisplay = display
        var state = states[display] ?? DisplayState()
        state.baseCount = 0
        state.screenIndex = state.timing.screenIndex(forBaseCount: 0) ?? 0
        states[display] = state
        onScreenChange?(display, state.screenIndex)
    }

    /// Move to the next ready display after `display`, wrapping around.
    private func advanceToNextReady(from display: DisplayIdentifier) {
        let ready = readyDisplays
        guard !ready.isEmpty else {
            activeDisplay = nil
            stopLoop()
            return
        }

        // Find the next entry strictly after the current one in rotation order,
        // falling back to the first so the rotation loops.
        let next = ready.first { $0.order > display.order } ?? ready[0]
        activate(next)
    }

    // MARK: - Manual navigation

    /// Skip to the next display in the rotation.
    public func nextDisplay() {
        guard let active = activeDisplay else { activateFirstReady(); return }
        advanceToNextReady(from: active)
        restartLoop()
    }

    /// Skip to the previous display in the rotation.
    public func previousDisplay() {
        let ready = readyDisplays
        guard !ready.isEmpty else { return }
        guard let active = activeDisplay else { activateFirstReady(); return }

        let previous = ready.last { $0.order < active.order } ?? ready[ready.count - 1]
        activate(previous)
        restartLoop()
    }

    /// Advance one screen within the active display, rolling into the next display.
    public func nextScreen() {
        guard let active = activeDisplay else { return }
        var state = state(for: active)

        // The candidate base count is the start of the next timing slot. On the last
        // screen that lands past the end of the schedule, which means "leave this
        // display" — checking it here is what makes a manual skip behave like the
        // automatic advance rather than sticking on the final screen.
        guard let next = state.timing.baseCountForNextScreen(after: state.baseCount),
              state.timing.screenIndex(forBaseCount: next) != nil
        else {
            advanceToNextReady(from: active)
            restartLoop()
            return
        }

        state.baseCount = next
        states[active] = state
        applyScreen(for: active)
        restartLoop()
    }

    /// Step back one screen, rolling into the previous display at the start.
    public func previousScreen() {
        guard let active = activeDisplay else { return }
        var state = state(for: active)
        let previous = state.timing.baseCountForPreviousScreen(before: state.baseCount)
        if previous == 0, state.baseCount == 0 {
            previousDisplay()
            return
        }
        state.baseCount = previous
        states[active] = state
        applyScreen(for: active)
        restartLoop()
    }

    /// Jump straight to a display, e.g. when a hazard arrives.
    public func jump(to display: DisplayIdentifier) {
        guard state(for: display).isReady else { return }
        activate(display)
        restartLoop()
    }

    // MARK: - Tick loop

    private func startLoop() {
        guard loopTask == nil, isPlaying, activeDisplay != nil else { return }
        // `self` is only strongified for the duration of each iteration, so the
        // engine can still be deallocated while the loop is sleeping.
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.currentTickInterval() else { return }
                do {
                    try await Task.sleep(for: .milliseconds(interval))
                } catch {
                    return  // cancelled
                }
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    /// Milliseconds until the next tick, or nil when the loop should stop.
    private func currentTickInterval() -> Double? {
        guard isPlaying, let active = activeDisplay else { return nil }
        return state(for: active).timing.baseDelay * max(speedMultiplier, 0.1)
    }

    private func stopLoop() {
        loopTask?.cancel()
        loopTask = nil
    }

    private func restartLoop() {
        stopLoop()
        if isPlaying { startLoop() }
    }

    private func tick() {
        guard let active = activeDisplay else { return }
        var state = state(for: active)
        state.baseCount += 1
        states[active] = state

        guard state.timing.screenIndex(forBaseCount: state.baseCount) != nil else {
            advanceToNextReady(from: active)
            return
        }
        applyScreen(for: active)
    }

    private func applyScreen(for display: DisplayIdentifier) {
        var state = state(for: display)
        guard let next = state.timing.screenIndex(forBaseCount: state.baseCount) else { return }
        guard next != state.screenIndex else { return }
        state.screenIndex = next
        states[display] = state
        onScreenChange?(display, next)
    }

    // MARK: - Derived values for views

    /// Scroll offset for the active display, driven by its base count.
    public func scrollOffset(for display: DisplayIdentifier) -> Double {
        let state = state(for: display)
        return state.scroll.offset(forBaseCount: state.baseCount)
    }

    /// Progress through the active display, 0...1, for the progress bar.
    public var activeProgress: Double {
        guard let active = activeDisplay else { return 0 }
        let state = state(for: active)
        guard let total = state.timing.cumulativeDelays.last, total > 0 else { return 0 }
        return min(1, Double(state.baseCount) / Double(total))
    }
}
