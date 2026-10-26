import Foundation

/// How ad lines join the bottom ticker.
///
/// The WeatherStar's lower display line carried local advertising between the readings. Here
/// the user's own lines — typed in the app, or from their companion server — take a turn
/// among the conditions, never all at once: a busy manifest would otherwise turn the ticker
/// into an ad crawl and push the weather off it.
public enum TickerAds {
    /// What fits one ticker page at its 32pt size, about 530 points of the Star4000 face.
    public static let pageLength = 34
    /// One ad page after this many readings.
    public static let readingsBetweenAds = 3

    /// A line broken into ticker pages at word boundaries. A word longer than a page gets a
    /// page of its own, and the ticker condenses it to fit.
    public static func pages(for line: String) -> [String] {
        var pages: [String] = []
        var current = ""
        for word in line.split(whereSeparator: \.isWhitespace).map(String.init) {
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= pageLength {
                current += " " + word
            } else {
                pages.append(current)
                current = word
            }
        }
        if !current.isEmpty { pages.append(current) }
        return pages
    }

    /// The readings with ad lines worked in among them.
    ///
    /// One ad line — all of its pages, so it reads as a whole — after every few readings.
    /// `rotation` picks which ads take this ticker's slots; the caller advances it on each
    /// rebuild, so over an evening every line gets its turn.
    public static func interleave(readings: [String], ads: [String], rotation: Int) -> [String] {
        let ads = ads.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !ads.isEmpty else { return readings }
        guard !readings.isEmpty else { return pages(for: ads[rotation % ads.count]) }

        var result: [String] = []
        var adIndex = rotation
        for (index, reading) in readings.enumerated() {
            result.append(reading)
            if (index + 1) % readingsBetweenAds == 0 {
                result += pages(for: ads[adIndex % ads.count])
                adIndex += 1
            }
        }
        // Too few readings to reach a slot: one ad at the end, so it is not lost entirely.
        if adIndex == rotation {
            result += pages(for: ads[adIndex % ads.count])
        }
        return result
    }
}

/// When the rotation takes an ad break.
public enum AdBreaks {
    /// The choices offered in Settings: an ad break after this many displays.
    public static let intervals = [4, 6, 8, 12]
    public static let defaultInterval = 8

    /// Why a break that is due might not happen.
    public struct Conditions: Equatable, Sendable {
        public var sceneIsActive = true
        public var pictureIsOn = true
        /// The user has held the rotation on one display.
        public var rotationHeld = false
        /// A weather bulletin is up: nothing interrupts a warning.
        public var bulletinShowing = false
        /// Local on the 8s is playing its bumper or segment.
        public var localSegmentPlaying = false

        public init(
            sceneIsActive: Bool = true, pictureIsOn: Bool = true, rotationHeld: Bool = false,
            bulletinShowing: Bool = false, localSegmentPlaying: Bool = false
        ) {
            self.sceneIsActive = sceneIsActive
            self.pictureIsOn = pictureIsOn
            self.rotationHeld = rotationHeld
            self.bulletinShowing = bulletinShowing
            self.localSegmentPlaying = localSegmentPlaying
        }

        var allowsBreak: Bool {
            sceneIsActive && pictureIsOn && !rotationHeld && !bulletinShowing && !localSegmentPlaying
        }
    }

    /// Whether to take a break now, `displaysSinceBreak` displays after the last one.
    public static func isDue(displaysSinceBreak: Int, every interval: Int, conditions: Conditions) -> Bool {
        interval > 0 && displaysSinceBreak >= interval && conditions.allowsBreak
    }
}
