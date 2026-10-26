import SwiftUI

/// Two views either side of a crease, each confined to its own pane.
///
/// Laid out from the posture's panes rather than with an `ArrangementView`, which is what
/// Apple offers for this. Three things rule that out here. A split arrangement splits whenever
/// it has room, flat or not, and the picture has to fill the whole screen until the fold is
/// actually bent. The panes hold a fixed-aspect broadcast canvas and a control deck rather than
/// two scrolling columns. And `ArrangementView` exists only from iOS 27.1, which would leave
/// the snapshot tests unable to draw any of this on the Macs they run on.
///
/// The split covers the window edge to edge, but leaves the band along the crease empty for
/// whatever is behind it to show through. `first` runs to the edges of its pane — on the
/// weather screen it is the picture, and the picture has always ignored the safe area.
/// `second` is handed the safe-area insets that fall on its pane, because it is the half
/// people press: on a tabletop it runs along the bottom edge, where the home indicator lives.
/// Handed rather than applied, so the pane can still paint its own background under them.
struct FoldSplit<First: View, Second: View>: View {
    let posture: FoldPosture
    private let first: First
    private let second: (EdgeInsets) -> Second

    init(
        posture: FoldPosture,
        @ViewBuilder first: () -> First,
        @ViewBuilder second: @escaping (_ insets: EdgeInsets) -> Second
    ) {
        self.posture = posture
        self.first = first()
        self.second = second
    }

    var body: some View {
        GeometryReader { proxy in
            if let panes = posture.panes(in: proxy.size) {
                first
                    .frame(width: panes.first.width, height: panes.first.height)
                    .clipped()
                    .position(x: panes.first.midX, y: panes.first.midY)

                second(Self.insets(proxy.safeAreaInsets, touching: panes.second, in: proxy.size))
                    .frame(width: panes.second.width, height: panes.second.height)
                    .position(x: panes.second.midX, y: panes.second.midY)
            }
        }
        .ignoresSafeArea()
    }

    /// The part of the window's safe-area insets that falls on a pane: an edge's inset only
    /// applies to a pane that reaches that edge.
    static func insets(_ safeArea: EdgeInsets, touching pane: CGRect, in size: CGSize) -> EdgeInsets {
        EdgeInsets(
            top: pane.minY <= 0 ? safeArea.top : 0,
            leading: pane.minX <= 0 ? safeArea.leading : 0,
            bottom: pane.maxY >= size.height ? safeArea.bottom : 0,
            trailing: pane.maxX >= size.width ? safeArea.trailing : 0
        )
    }
}

/// Room light caught on the glass, sliding down it as the screen is tipped back.
///
/// The one use the app makes of the hinge *angle*. Apple's guidance is to keep the angle for
/// live effects and lay out from the fold's regions, and a reflection is about as live and as
/// purely cosmetic as an effect gets: nothing moves, nothing can be pressed, and a device that
/// reports no angle simply gets the reflection for a lid stood upright.
///
/// The physics is a ceiling light. With the upper half stood up at 90° the light sits in the
/// top of the glass; as the half is tipped back it faces the ceiling more squarely, so the
/// reflection slides down and brightens.
struct GlassGlare: View {
    /// Degrees, 0 closed to 180 flat, or `nil` when unknown.
    let hingeAngle: Double?

    /// 0 with the screen half upright, 1 with it laid back to 150°.
    static func tilt(for hingeAngle: Double?) -> Double {
        min(max(((hingeAngle ?? 100) - 90) / 60, 0), 1)
    }

    var body: some View {
        let tilt = Self.tilt(for: hingeAngle)
        let centre = 0.16 + 0.44 * tilt
        let strength = 0.025 + 0.045 * tilt

        LinearGradient(
            stops: [
                .init(color: .white.opacity(0), location: centre - 0.16),
                .init(color: .white.opacity(strength), location: centre),
                .init(color: .white.opacity(0), location: centre + 0.24),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .blendMode(.screen)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(.easeOut(duration: 0.25), value: tilt)
    }
}
