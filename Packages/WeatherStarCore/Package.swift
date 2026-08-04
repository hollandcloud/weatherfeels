// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WeatherStarCore",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "WeatherStarKit", targets: ["WeatherStarKit"]),
        .library(name: "WeatherStarUI", targets: ["WeatherStarUI"]),
    ],
    targets: [
        // Fonts, icons, background art and the bundled city/station tables.
        // Kept in its own target so every app platform picks up one resource bundle.
        //
        // The directory is named `Assets` rather than `Resources` deliberately: a
        // folder called `Resources` at a bundle's root makes `codesign` read it as a
        // malformed macOS-style bundle ("bundle format unrecognized"), which fails any
        // signed iOS or tvOS build.
        .target(
            name: "WeatherStarResources",
            resources: [.copy("Assets")]
        ),
        // Data layer: NWS API client, models, unit conversion, rotation engine, music.
        .target(
            name: "WeatherStarKit",
            dependencies: ["WeatherStarResources"]
        ),
        // SwiftUI recreation of the WeatherStar 4000 displays.
        .target(
            name: "WeatherStarUI",
            dependencies: ["WeatherStarKit", "WeatherStarResources"]
        ),
        .testTarget(
            name: "WeatherStarKitTests",
            // WeatherStarUI is included so the text-rendering tests can measure the
            // real font metrics and catch glyph clipping without a device.
            dependencies: ["WeatherStarKit", "WeatherStarUI"]
        ),
    ]
)
