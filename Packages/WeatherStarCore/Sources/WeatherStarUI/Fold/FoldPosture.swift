import SwiftUI

/// How a folding screen is bent, and so where content can go without lying across the crease.
///
/// A value rather than something each view asks the system for, for two reasons. It keeps one
/// reading of the fold — `RootView` takes it and hands it down — so the picture and the
/// controls cannot disagree about where the crease is; the same lesson `TelevisionPresentation`
/// records about the cabinet. And it keeps every decision after the read testable on a Mac:
/// the reserved-region API is iOS 27.1 only, but what is done with its answer is plain geometry.
///
/// Derived from the fold's *division* reserved region, never from the hinge angle. Apple is
/// explicit that the angle is for live effects and the regions are for layout: the system
/// decides when the fold is bent far enough to divide the screen, and marks the region active
/// when it is. An app that drew its own line at, say, 150° would split the screen at a
/// different moment from every system view around it.
public enum FoldPosture: Equatable, Sendable {
    /// One undivided surface: open flat, closed, or not a foldable at all.
    case flat
    /// The crease runs top to bottom. Held like a book: two pages side by side.
    case book(crease: CGRect)
    /// The crease runs side to side. Stood on a table like a laptop: a screen to look at above,
    /// and below it a half lying flat, which is the steadiest surface a phone ever offers a
    /// finger.
    case tabletop(crease: CGRect)

    /// The smallest side worth giving content to, in points.
    ///
    /// A split-view pane that only grazes the fold should not be cut into a sliver and the
    /// rest; it is better left whole, with the crease simply running through it.
    static let minimumPane: CGFloat = 200

    /// Read the posture from a container's active division regions.
    ///
    /// `divisions` are frames in the container's own coordinate space, margins included, as
    /// `GeometryProxy.reservedRegions(kind: .division)` reports them. On iPhone Duo that is a
    /// 40pt band: the crease itself has no width, and the system pads it by 20pt either side
    /// for interactive content. Which way the band runs says which way the device is bent —
    /// a crease dividing left from right is taller than it is wide.
    public static func resolve(container: CGSize, divisions: [CGRect]) -> FoldPosture {
        guard container.width > 0, container.height > 0 else { return .flat }
        let bounds = CGRect(origin: .zero, size: container)

        for division in divisions {
            // Clipped to the container, so a fold reported for the whole window still
            // describes the part of it this view occupies.
            let crease = division.intersection(bounds)
            guard !crease.isNull else { continue }

            if crease.height >= crease.width {
                guard crease.minX >= minimumPane, bounds.maxX - crease.maxX >= minimumPane else {
                    continue
                }
                return .book(crease: crease)
            } else {
                guard crease.minY >= minimumPane, bounds.maxY - crease.maxY >= minimumPane else {
                    continue
                }
                return .tabletop(crease: crease)
            }
        }
        return .flat
    }

    /// The two parts the crease leaves, or `nil` when there is no crease.
    ///
    /// `first` is the leading page of a book and the upper half of a tabletop; `second` is the
    /// trailing page and the lower half. That pairing is deliberate: in both postures the second
    /// pane is where Apple puts what the hand reaches for — the lower half lies on the table, and
    /// the trailing page is the one nearest where the app reappears when the device is closed.
    public func panes(in container: CGSize) -> (first: CGRect, second: CGRect)? {
        switch self {
        case .flat:
            nil
        case .book(let crease):
            (
                CGRect(x: 0, y: 0, width: crease.minX, height: container.height),
                CGRect(
                    x: crease.maxX, y: 0,
                    width: max(0, container.width - crease.maxX), height: container.height
                )
            )
        case .tabletop(let crease):
            (
                CGRect(x: 0, y: 0, width: container.width, height: crease.minY),
                CGRect(
                    x: 0, y: crease.maxY,
                    width: container.width, height: max(0, container.height - crease.maxY)
                )
            )
        }
    }

    public var isFolded: Bool { self != .flat }
}

// MARK: - Environment

private struct FoldPostureKey: EnvironmentKey {
    static let defaultValue = FoldPosture.flat
}

extension EnvironmentValues {
    /// The fold's posture over the whole window, as `RootView` read it.
    ///
    /// For views that lay themselves out around the crease, such as onboarding. Frames in it
    /// are in window coordinates, so read it from a view that ignores the safe area as well.
    public var foldPosture: FoldPosture {
        get { self[FoldPostureKey.self] }
        set { self[FoldPostureKey.self] = newValue }
    }
}

// MARK: - Reading the hardware

extension View {
    /// Report the fold over this view's frame, and the hinge angle while it is bent.
    ///
    /// The only place the app asks the system about the fold. Both callbacks stay silent
    /// anywhere the APIs do not exist — before iOS 27.1, on every other platform, and in a
    /// build made with an SDK older than 27.1 — which leaves the posture `.flat` and the angle
    /// `nil`, the same values a device that does not fold reports.
    ///
    /// The angle is in degrees: 0 closed, 180 flat. It is `nil` unless the hinge is partially
    /// open, because that is the only state where it means anything to draw.
    func onFoldChange(
        posture: @escaping (FoldPosture) -> Void,
        hingeAngle: @escaping (Double?) -> Void = { _ in }
    ) -> some View {
        modifier(FoldReader(onPosture: posture, onHingeAngle: hingeAngle))
    }
}

private struct FoldReader: ViewModifier {
    let onPosture: (FoldPosture) -> Void
    let onHingeAngle: (Double?) -> Void

    func body(content: Content) -> some View {
        // The version check is on SwiftUI itself rather than on the compiler. Swift 6.4 ships
        // with both Xcode 27.0 and 27.1, but only the 27.1 SDK has these symbols, and its
        // SwiftUI is the first to report 8.0.85. Xcode 26 and 27.0 builds compile this out
        // and get an app that simply treats the Duo as a phone.
        #if os(iOS) && canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            content
                .onGeometryChange(for: FoldPosture.self) { proxy in
                    FoldPosture.resolve(
                        container: proxy.size,
                        // Active only: an inactive fold is the device open flat, where
                        // nothing needs to move.
                        divisions: proxy.reservedRegions(kind: .division)
                            .filter(\.isActive)
                            .map(\.frame)
                    )
                } action: { posture in
                    onPosture(posture)
                }
                .onHingeChange { _, context in
                    guard let hinge = context.hinge, hinge.status == .partiallyOpen else {
                        onHingeAngle(nil)
                        return
                    }
                    onHingeAngle(hinge.angle.degrees)
                }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
