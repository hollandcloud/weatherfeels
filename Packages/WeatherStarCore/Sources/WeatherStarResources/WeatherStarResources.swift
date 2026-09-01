import Foundation

/// Access to the bundled WeatherStar assets: Star4000 fonts, weather icons,
/// logos, radar base maps, the station/city tables and the default music.
///
/// `Bundle.module` is internal to its own target, so this namespace re-exports it
/// for `WeatherStarKit` and `WeatherStarUI`.
public enum WeatherStarResources {
    public static let bundle: Bundle = .module

    public enum Directory: String, Sendable, CaseIterable {
        case fonts = "Fonts"
        case currentConditionIcons = "Icons/CurrentConditions"
        case moonPhaseIcons = "Icons/MoonPhases"
        case regionalMapIcons = "Icons/RegionalMaps"
        case logos = "Logos"
        case maps = "Maps"
        case data = "Data"
        case music = "Music"
        case sounds = "Sounds"
    }

    /// Resource lookup goes through `Bundle` rather than string-concatenating onto
    /// `resourceURL`.
    ///
    /// The on-disk folder is `Assets`, not `Resources`: a root-level `Resources`
    /// directory inside a bundle makes `codesign` reject it on iOS and tvOS.
    ///
    /// The layout differs by platform — a macOS bundle nests under
    /// `Contents/Resources` while iOS and tvOS bundles are flat, and SwiftPM's
    /// `.copy("Resources")` adds a further level. Asking `Bundle` avoids having to
    /// know which shape is in play, and both candidate subdirectories are tried so
    /// the same code works in an app bundle and in a `swift test` run.
    private static func candidateSubdirectories(_ directory: Directory) -> [String] {
        ["Assets/\(directory.rawValue)", directory.rawValue]
    }

    /// URL for a named file inside one of the resource directories.
    /// Returns nil when the file is absent rather than trapping, so a missing
    /// optional asset degrades instead of crashing the display loop.
    public static func url(_ name: String, in directory: Directory) -> URL? {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension

        for subdirectory in candidateSubdirectories(directory) {
            if let url = bundle.url(
                forResource: base,
                withExtension: ext.isEmpty ? nil : ext,
                subdirectory: subdirectory
            ) {
                return url
            }
        }
        return nil
    }

    /// URL of a resource directory, or nil when it is not present.
    public static func directoryURL(_ directory: Directory) -> URL? {
        guard let root = bundle.resourceURL else { return nil }
        for subdirectory in candidateSubdirectories(directory) {
            let candidate = root.appendingPathComponent(subdirectory, isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    public static func data(_ name: String, in directory: Directory) throws -> Data {
        guard let url = url(name, in: directory) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    /// Files in a resource directory, sorted by name. Empty when the directory is
    /// missing, which lets a caller degrade instead of failing.
    public static func contents(
        of directory: Directory,
        withExtension ext: String? = nil
    ) -> [URL] {
        guard let dir = directoryURL(directory),
              let items = try? FileManager.default.contentsOfDirectory(
                  at: dir,
                  includingPropertiesForKeys: nil
              )
        else { return [] }

        return items
            .filter { ext == nil || $0.pathExtension.lowercased() == ext!.lowercased() }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Whether every expected resource directory resolved. Used by tests to catch a
    /// packaging regression before it reaches a device.
    public static func verifyPackaging() -> [Directory: Bool] {
        Dictionary(uniqueKeysWithValues: Directory.allCases.map { ($0, directoryURL($0) != nil) })
    }
}
