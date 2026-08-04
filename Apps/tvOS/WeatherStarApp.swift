import SwiftUI
import WeatherStarUI

/// tvOS entry point.
///
/// The Apple TV case is why the port is native rather than a wrapped web view:
/// tvOS has no WebKit at all, so the displays had to be rebuilt in SwiftUI.
@main
struct WeatherStarApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
