import Foundation

/// How long each screen of a display is held, expressed in "base counts".
///
/// Upstream's engine ticks a counter every `baseDelay` milliseconds and derives the
/// visible screen from the accumulated count. That indirection is what lets a
/// display advertise uneven screen durations (radar's slow-then-fast animation loop)
/// without its own timer, so the port keeps the same model.
public enum DisplayDelay: Sendable, Hashable {
    /// Every screen is held for the same number of base counts.
    case uniform(Int)
    /// One entry per screen, in screen order.
    case perScreen([Int])
    /// Explicit (duration, screen) pairs — lets a screen repeat, as radar does.
    case sequence([Step])

    public struct Step: Sendable, Hashable {
        public let time: Int
        public let screenIndex: Int

        public init(time: Int, screenIndex: Int) {
            self.time = time
            self.screenIndex = screenIndex
        }
    }
}

/// Timing for one display: how many screens, how fast the counter ticks, and how
/// long each screen is held.
public struct DisplayTiming: Sendable, Hashable {
    /// Zero means the display has nothing to show and is skipped.
    public var totalScreens: Int
    /// Milliseconds per base count.
    public var baseDelay: Double
    public var delay: DisplayDelay

    /// Cumulative end point of each entry, in base counts.
    public private(set) var cumulativeDelays: [Int] = []
    /// Screen to show during the matching `cumulativeDelays` interval.
    public private(set) var screenIndexes: [Int] = []

    /// Upstream's default: one screen held for a single 9-second beat.
    public static let standard = DisplayTiming(totalScreens: 1, baseDelay: 9000, delay: .uniform(1))

    /// A display with nothing to show; the engine advances straight past it.
    public static let empty = DisplayTiming(totalScreens: 0, baseDelay: 9000, delay: .uniform(1))

    public init(totalScreens: Int, baseDelay: Double, delay: DisplayDelay) {
        self.totalScreens = totalScreens
        self.baseDelay = baseDelay
        self.delay = delay
        recalculate()
    }

    /// Expand `delay` into the cumulative/screen-index arrays the engine reads.
    /// The array forms define the screen count, so they override `totalScreens`.
    private mutating func recalculate() {
        var durations: [Int]

        switch delay {
        case let .uniform(count):
            durations = Array(repeating: count, count: max(totalScreens, 0))
        case let .perScreen(values):
            durations = values
            totalScreens = values.count
        case let .sequence(steps):
            durations = steps.map(\.time)
            totalScreens = steps.count
        }

        var running = 0
        cumulativeDelays = durations.map { duration in
            running += duration
            return running
        }

        switch delay {
        case let .sequence(steps):
            screenIndexes = steps.map(\.screenIndex)
        default:
            screenIndexes = Array(0..<durations.count)
        }
    }

    /// Total time this display occupies, before the speed multiplier.
    public var totalDuration: TimeInterval {
        guard let last = cumulativeDelays.last else { return 0 }
        return Double(last) * baseDelay / 1000
    }

    /// Screen to show for a base count, or nil once the display is finished
    /// — which tells the engine to advance to the next display.
    public func screenIndex(forBaseCount count: Int) -> Int? {
        guard totalScreens > 0 else { return nil }
        guard let slot = cumulativeDelays.firstIndex(where: { $0 > count }) else { return nil }
        return screenIndexes[slot]
    }

    /// Base count at which the next screen begins, for a manual "next" command.
    public func baseCountForNextScreen(after count: Int) -> Int? {
        cumulativeDelays.first { $0 > count }
    }

    /// Base count at which the previous screen began, for a manual "previous".
    public func baseCountForPreviousScreen(before count: Int) -> Int {
        cumulativeDelays.reduce(0) { result, delay in
            delay < count ? delay : result
        }
    }

    /// Base count that lands on the display's final screen.
    public var baseCountForLastScreen: Int {
        guard let last = cumulativeDelays.last else { return 0 }
        return max(0, last - 1)
    }
}

extension DisplayTiming {
    /// Timing for a vertically scrolling list, ported from `utils/scroll-timing.mjs`.
    ///
    /// Holds still, scrolls at a constant pixels-per-second, then holds again — so a
    /// long list takes proportionally longer rather than scrolling faster.
    public static func scrolling(
        contentHeight: Double,
        viewportHeight: Double,
        scrollSpeed: Double = 50,
        initialDelay: Double = 3.0,
        finalPause: Double = 3.0,
        baseDelay: Double = 40
    ) -> (timing: DisplayTiming, scroll: ScrollTiming) {
        func counts(_ seconds: Double) -> Int {
            Int((seconds * 1000 / baseDelay).rounded(.up))
        }

        let scrollableHeight = max(0, contentHeight - viewportHeight)
        let scrollSeconds = scrollableHeight > 0 ? scrollableHeight / scrollSpeed : 0

        let initialCounts = counts(initialDelay)
        let scrollCounts = counts(scrollSeconds)
        let finalCounts = counts(finalPause)

        let total = scrollableHeight == 0
            ? counts(initialDelay + finalPause)
            : initialCounts + scrollCounts + finalCounts

        let pixelsPerCount = scrollCounts > 0 ? scrollableHeight / Double(scrollCounts) : 0

        return (
            DisplayTiming(totalScreens: 1, baseDelay: baseDelay, delay: .perScreen([total])),
            ScrollTiming(
                initialCounts: initialCounts,
                pixelsPerCount: pixelsPerCount,
                scrollableHeight: scrollableHeight
            )
        )
    }
}

/// Offsets for a scrolling display, derived alongside its timing.
public struct ScrollTiming: Sendable, Hashable {
    public let initialCounts: Int
    public let pixelsPerCount: Double
    public let scrollableHeight: Double

    public static let none = ScrollTiming(initialCounts: 0, pixelsPerCount: 0, scrollableHeight: 0)

    /// Vertical offset for a base count, clamped to the scrollable range.
    public func offset(forBaseCount count: Int) -> Double {
        guard scrollableHeight > 0 else { return 0 }
        let scrolled = Double(max(0, count - initialCounts)) * pixelsPerCount
        return min(scrolled, scrollableHeight)
    }
}
