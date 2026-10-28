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

    /// How many ads one break plays back to back, like a station's commercial break.
    public static let adsPerBreak = 2...3

    /// The longest a clip runs when the manifest does not say: a commercial, not a programme.
    public static let defaultClipSeconds = 60

    /// Whether to take a break now, `displaysSinceBreak` displays after the last one.
    public static func isDue(displaysSinceBreak: Int, every interval: Int, conditions: Conditions) -> Bool {
        interval > 0 && displaysSinceBreak >= interval && conditions.allowsBreak
    }
}

/// One ad in a break: a card or a clip from the reel.
public enum AdSpot: Equatable, Sendable, Identifiable {
    case card(AdCard)
    case clip(AdClip)

    /// Unique across both kinds, even if a hand-written manifest reuses an id between them.
    public var id: String {
        switch self {
        case .card(let card): "card:" + card.id
        case .clip(let clip): "clip:" + clip.id
        }
    }
}

/// Deals ad breaks from every ad on offer, cards and clips together, in random order.
///
/// A shuffle bag: every ad plays once before any plays twice, so a long reel is seen through
/// rather than sampled with repeats. A fresh shuffle never opens with the ad that closed the
/// last one, and no break shows one ad twice. The bag holds ids rather than positions,
/// because the manifest is fetched again at every weather refresh: an ad that went away is
/// dropped, a new one joins the ads still to come, and the round keeps its place.
public struct AdShuffle: Sendable {
    /// Ids still to come this round, next first.
    public private(set) var upcoming: [String] = []
    /// Ids already played this round.
    private var played: Set<String> = []
    /// The ad shown last, so a new round does not open with it.
    private var last: String?

    public init() {}

    /// The next break's ads, `AdBreaks.adsPerBreak` of them, or all there are if fewer.
    public mutating func nextBreak(from spots: [AdSpot]) -> [AdSpot] {
        var generator = SystemRandomNumberGenerator()
        return nextBreak(from: spots, using: &generator)
    }

    public mutating func nextBreak(from spots: [AdSpot], using generator: inout some RandomNumberGenerator) -> [AdSpot] {
        var byID: [String: AdSpot] = [:]
        var ids: [String] = []
        for spot in spots where byID[spot.id] == nil {
            byID[spot.id] = spot
            ids.append(spot.id)
        }
        guard !ids.isEmpty else { return [] }

        // Catch up with the manifest. Placing each new ad at a random point among those to
        // come is itself a shuffle, which is how the very first round is dealt.
        upcoming.removeAll { byID[$0] == nil }
        played.formIntersection(ids)
        let waiting = Set(upcoming)
        for id in ids where !played.contains(id) && !waiting.contains(id) {
            upcoming.insert(id, at: Int.random(in: 0...upcoming.count, using: &generator))
        }

        let count = min(Int.random(in: AdBreaks.adsPerBreak, using: &generator), ids.count)
        var chosen: [String] = []
        while chosen.count < count {
            if upcoming.isEmpty { startRound(with: ids, after: chosen, using: &generator) }
            let id = upcoming.removeFirst()
            played.insert(id)
            chosen.append(id)
            last = id
        }
        return chosen.compactMap { byID[$0] }
    }

    /// Shuffle every ad into a new round. What was just shown goes to the back, so nothing
    /// repeats across the seam or within the break that crosses it.
    private mutating func startRound(
        with ids: [String], after chosen: [String], using generator: inout some RandomNumberGenerator
    ) {
        let recent = Set(chosen + [last].compactMap(\.self))
        let deck = ids.shuffled(using: &generator)
        upcoming = deck.filter { !recent.contains($0) } + deck.filter { recent.contains($0) }
        played = []
    }
}
