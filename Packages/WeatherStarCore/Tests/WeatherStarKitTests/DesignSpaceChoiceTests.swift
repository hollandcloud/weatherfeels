import SwiftUI
import Testing
@testable import WeatherStarUI

@Suite("Canvas choice")
struct DesignSpaceChoiceTests {
    /// Fraction of a container the canvas leaves as bars.
    private func waste(_ space: DesignSpace, in size: CGSize) -> CGFloat {
        let metrics = StarMetrics(space: space, container: size)
        return 1 - (metrics.scaledSize.width * metrics.scaledSize.height) / (size.width * size.height)
    }

    @Test("Automatic picks whichever canvas wastes less of the screen")
    func picksLeastWaste() {
        let landscapeShapes: [(String, CGSize)] = [
            ("Duo outer, landscape", CGSize(width: 678, height: 466)),
            ("Duo inner, upright", CGSize(width: 951, height: 669)),
            ("Duo tabletop, upper half", CGSize(width: 669, height: 455.5)),
            ("iPad mini, landscape", CGSize(width: 1133, height: 744)),
            ("iPad Pro 13-inch, landscape", CGSize(width: 1376, height: 1032)),
            ("Apple TV", CGSize(width: 1920, height: 1080)),
            ("iPhone 16 Pro, landscape", CGSize(width: 874, height: 402)),
        ]
        for (name, size) in landscapeShapes {
            let chosen = DesignSpace.resolve(for: .auto, container: size)
            let other: DesignSpace = chosen == .wide ? .standard : .wide
            #expect(
                waste(chosen, in: size) <= waste(other, in: size) + 0.0001,
                "\(name): \(chosen.mode) wastes \(waste(chosen, in: size)), \(other.mode) \(waste(other, in: size))"
            )
        }
    }

    /// The case that motivated the change: the old 1.45 cut-off gave the Duo's outer display
    /// the wide canvas and drew the forecast a fifth smaller than it needed to be.
    @Test("The Duo's outer display gets the standard canvas in landscape")
    func duoOuterIsStandard() {
        #expect(DesignSpace.resolve(for: .auto, container: CGSize(width: 678, height: 466)) == .standard)
        #expect(abs(DesignSpace.wideCrossover - 1.54) < 0.01)
    }
}
