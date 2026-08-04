import SwiftUI
import UIKit
import WeatherStarUI

/// iOS and iPadOS entry point.
///
/// All behavior lives in `RootView`; the app target only chooses the window style.
@main
struct WeatherStarApp: App {
    @UIApplicationDelegateAdaptor(OrientationLock.self) private var orientationLock

    var body: some Scene {
        WindowGroup {
            RootView()
                // The displays are the content; system chrome would only crop them.
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
    }
}

/// Keeps the app in landscape on both iPhone and iPad.
///
/// `UISupportedInterfaceOrientations~ipad` cannot express this on its own: App Store
/// validation rejects an iPad bundle that declares fewer than all four orientations, so
/// the plist has to claim portrait support even though the displays are a 4:3 or 16:9
/// canvas that would letterbox to a narrow strip. This delegate is the runtime half — it
/// is consulted on every rotation and takes precedence over the plist, so the plist can
/// stay permissive for the validator while the app only ever rotates between the two
/// landscape orientations.
final class OrientationLock: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        .landscape
    }
}
