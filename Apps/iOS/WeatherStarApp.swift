import SwiftUI
import UIKit
import WeatherStarUI

/// iOS and iPadOS entry point.
///
/// All behavior lives in `RootView`; the app target only chooses the window style and the
/// orientation it opens in.
///
/// There used to be a `UIApplicationDelegate` here forcing `.landscape` outright, because a
/// 4:3 broadcast canvas stretched up a portrait screen left a band of picture across the top
/// and a screenful of empty blue under it — and the plist could not say so on its own, since
/// App Store validation rejects an iPad bundle declaring fewer than all four orientations.
/// `StarTelevision` removed the reason: a portrait screen now shows the picture on a CRT
/// standing in a room, which is a real layout rather than a letterbox. So the app rotates
/// freely, and only *opens* in landscape.
@main
struct WeatherStarApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                // The displays are the content; system chrome would only crop them.
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
                .modifier(OpensInLandscape())
        }
    }
}

/// Turns the app to landscape once, at launch, and then leaves rotation alone.
///
/// Landscape is the shape the picture was drawn for and the one that fills the screen with
/// it, so it is what the app should open showing. Portrait is then something the user
/// chooses by turning the device, and what they get is the television.
///
/// A one-shot geometry request rather than a restriction: `supportedInterfaceOrientations`
/// still allows everything, so this only sets the starting orientation. If it cannot be
/// honoured — rotation locked, an iPad in Split View, a scene that is not foreground yet —
/// it fails quietly and the app simply opens the way the device is held, which is a perfectly
/// good outcome and not worth reporting.
private struct OpensInLandscape: ViewModifier {
    /// `onAppear` can fire more than once for the same scene; the turn should happen only
    /// on the first, or it would yank the device back every time the view reappeared.
    @State private var hasTurned = false

    /// Set `WS4K_KEEP_DEVICE_ORIENTATION` in the environment to skip the turn.
    ///
    /// Exists for `Tools/shoot.sh`, which needs the app to stay in whichever orientation the
    /// simulator is in so it can capture the portrait cabinet. `simctl` cannot rotate a
    /// device, and driving Simulator.app's menus to do it is unreliable when more than one
    /// device is open — this is the deterministic way in.
    private var keepsDeviceOrientation: Bool {
        ProcessInfo.processInfo.environment["WS4K_KEEP_DEVICE_ORIENTATION"] != nil
    }

    func body(content: Content) -> some View {
        content.onAppear {
            guard !hasTurned, !keepsDeviceOrientation else { return }
            hasTurned = true

            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
                ?? scenes.first
            else { return }

            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { _ in }
        }
    }
}
