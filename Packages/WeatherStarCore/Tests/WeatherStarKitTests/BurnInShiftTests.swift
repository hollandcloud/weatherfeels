import Foundation
import Testing
@testable import WeatherStarUI

/// The burn-in shift has to be balanced and pixel-aligned, or it makes things worse
/// rather than better.
@Suite("Burn-in shift")
struct BurnInShiftTests {
    @Test("Offsets are whole points")
    func wholePixels() {
        // A fractional offset would resample the pixel-art glyphs and icons, undoing the
        // nearest-neighbour scaling the rest of the renderer preserves.
        for position in BurnInShift.positions {
            #expect(position.x == position.x.rounded(), "fractional x: \(position.x)")
            #expect(position.y == position.y.rounded(), "fractional y: \(position.y)")
        }
    }

    @Test("The cycle averages to centre so no pixel is favoured")
    func balanced() {
        let sumX = BurnInShift.positions.reduce(0) { $0 + $1.x }
        let sumY = BurnInShift.positions.reduce(0) { $0 + $1.y }
        #expect(sumX == 0, "cycle drifts horizontally by \(sumX)")
        #expect(sumY == 0, "cycle drifts vertically by \(sumY)")
    }

    @Test("Every offset stays within the stated amplitude")
    func withinAmplitude() {
        let limit = CGFloat(BurnInShift.amplitude)
        for position in BurnInShift.positions {
            #expect(abs(position.x) <= limit && abs(position.y) <= limit, "\(position) exceeds \(limit)")
        }
    }

    @Test("The offset advances once per step and returns to the start")
    func advancesThroughCycle() {
        let step = BurnInShift.stepInterval
        let count = BurnInShift.positions.count

        // Sampling mid-step avoids depending on behaviour exactly on a boundary.
        let first = BurnInShift.offset(at: step * 0.5)
        let second = BurnInShift.offset(at: step * 1.5)
        #expect(first != second, "the offset did not move between consecutive steps")

        let wrapped = BurnInShift.offset(at: step * (Double(count) + 0.5))
        #expect(wrapped == first, "the cycle did not return to its start after \(count) steps")
    }

    @Test("Negative times do not crash or fall outside the cycle")
    func negativeTime() {
        // Seconds are measured from 2001, so a device with a bad clock can report a
        // negative value; a plain `%` would index out of bounds.
        for time in [-1.0, -BurnInShift.stepInterval * 3.5, -100_000.0] {
            let offset = BurnInShift.offset(at: time)
            #expect(BurnInShift.positions.contains(offset), "\(time) produced \(offset)")
        }
    }

    @Test("Disabling it parks the image at centre")
    func disabled() {
        #expect(BurnInShift.offset(at: 12_345, enabled: false) == .zero)
    }
}
