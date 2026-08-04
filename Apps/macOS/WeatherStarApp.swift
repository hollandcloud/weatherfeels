import SwiftUI
import WeatherStarUI

/// macOS entry point.
///
/// The window starts at the 16:9 design canvas so the widescreen layout is chosen on
/// first launch, and resizes freely from there — the canvas rescales to fit.
/// Keyboard control (arrows, space, ⌘,) is installed by `RootView`.
@main
struct WeatherStarApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 640, minHeight: 360)
        }
        .defaultSize(width: 1280, height: 720)
        .windowResizability(.contentMinSize)
    }
}
