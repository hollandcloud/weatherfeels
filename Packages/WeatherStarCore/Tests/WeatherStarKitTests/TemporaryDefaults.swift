import Foundation

/// Throwaway defaults domains, so a test never reads or writes the real app's settings
/// and never leaves anything behind in `~/Library/Preferences`.
///
/// On macOS each suite is named with an absolute path in the temporary directory, which
/// CFPreferences stores as a plain plist at that path. A named suite lives in
/// `~/Library/Preferences` instead, and nothing removes it: these tests had left 2,700+
/// `ws4k.*.<UUID>.plist` files there. Even `removePersistentDomain` leaves an empty plist
/// behind, and deleting that file from a test is racy because the preferences daemon can
/// write it back. On iOS and tvOS the tests run inside a simulator container that is
/// thrown away anyway, so a plain suite name is fine there.
enum TemporaryDefaults {
    #if os(macOS)
    private static let directory: URL = {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "WeatherStarKitTests-defaults", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()
    #endif

    /// A fresh, empty defaults domain whose name starts with `prefix`.
    static func make(_ prefix: String) -> UserDefaults {
        let name = "\(prefix).\(UUID().uuidString)"
        #if os(macOS)
        return UserDefaults(suiteName: directory.appending(path: name).path)!
        #else
        return UserDefaults(suiteName: name)!
        #endif
    }
}
