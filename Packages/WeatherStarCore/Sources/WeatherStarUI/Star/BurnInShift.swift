import CoreGraphics
import Foundation

/// Slowly walks the whole canvas around a few pixels so nothing static burns in.
///
/// This app is close to the worst case for an OLED or plasma panel: the header plate, the
/// logo and the clock sit in the same place indefinitely, and someone leaving WeatherStar
/// up as ambient decoration is exactly the intended use. TV sets do this themselves —
/// "pixel orbiting" — but only for their own inputs, so an app that expects to run for
/// hours should do its own.
///
/// The offsets are whole points, never fractional. A sub-point translation would resample
/// the pixel-art glyphs and icons, undoing the nearest-neighbour scaling everything else
/// goes to trouble to preserve.
public enum BurnInShift {
    /// Furthest the canvas moves from centre, in points.
    ///
    /// Three points is enough to spread a static edge across several panel pixels at 4K
    /// while staying far below anything the eye tracks. It also means at most three points
    /// of the canvas edge are trimmed, which lands in the letterbox rather than on
    /// content.
    public static let amplitude: Int = 3

    /// Seconds between moves. Long enough that the step is never perceived as motion.
    public static let stepInterval: Double = 90

    /// The cycle of positions, walked in order.
    ///
    /// A ring rather than a random jitter: every position is visited for the same total
    /// time, so no pixel accumulates more exposure than another over a long session.
    /// Diagonals are included so horizontal *and* vertical edges both move.
    static let positions: [CGPoint] = {
        let a = CGFloat(amplitude)
        return [
            CGPoint(x: 0, y: 0),
            CGPoint(x: a, y: 0),
            CGPoint(x: a, y: a),
            CGPoint(x: 0, y: a),
            CGPoint(x: -a, y: a),
            CGPoint(x: -a, y: 0),
            CGPoint(x: -a, y: -a),
            CGPoint(x: 0, y: -a),
            CGPoint(x: a, y: -a),
        ]
    }()

    /// How long one full circuit takes.
    public static var cycleDuration: Double { stepInterval * Double(positions.count) }

    /// Offset to apply at a given moment.
    ///
    /// Driven by wall-clock time rather than an animation, so it survives the view being
    /// rebuilt and does not need any state of its own.
    public static func offset(at time: Double, enabled: Bool = true) -> CGPoint {
        guard enabled else { return .zero }
        let step = Int((time / stepInterval).rounded(.down))
        // `%` on a negative step would give a negative index; time is seconds since the
        // reference date and can be negative for dates before 2001.
        let index = ((step % positions.count) + positions.count) % positions.count
        return positions[index]
    }
}
