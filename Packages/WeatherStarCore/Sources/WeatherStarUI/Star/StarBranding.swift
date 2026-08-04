import Foundation
import SwiftUI
import WeatherStarResources

/// The corner logo and the startup title, overridable at build time.
///
/// Deliberately *not* a user setting. Branding is a property of a build — whoever ships a
/// copy decides what mark it carries — so it is read from `Info.plist`, which means a fork
/// changes it in `project.yml` and never touches Swift.
///
/// Everything is optional and falls back to the bundled WeatherStar 4000+ artwork, so a
/// stock build looks exactly as it did before this existed.
///
/// ```yaml
/// # project.yml, per target or in the shared base
/// INFOPLIST_KEY_WS4KLogoImageName: MyCornerLogo   # an image in the app's asset catalog
/// INFOPLIST_KEY_WS4KStartupTitle: My Weather      # startup screen, first line
/// INFOPLIST_KEY_WS4KStartupSubtitle: Channel      # startup screen, second line
/// ```
public enum StarBranding {
    /// Name of an image in the *app's* asset catalog to use as the corner logo.
    ///
    /// Looked up in the main bundle rather than the package's, because that is where a
    /// fork's own artwork will live. Nil falls back to `logo-corner.png` from the package.
    public static let logoImageName: String? = string(for: "WS4KLogoImageName")

    /// Startup screen title, which upstream shows as "WeatherStar" / "4000+".
    public static let startupTitle: String = string(for: "WS4KStartupTitle") ?? "WeatherStar"
    public static let startupSubtitle: String? = {
        // An explicitly empty string means "one line only", which is different from the
        // key being absent.
        guard let value = Bundle.main.object(forInfoDictionaryKey: "WS4KStartupSubtitle") as? String
        else { return "4000+" }
        return value.isEmpty ? nil : value
    }()

    /// Whether this build carries its own logo art.
    public static var hasCustomLogo: Bool { logoImageName != nil }

    private static func string(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return value
    }
}

/// The corner logo: a build's own asset if it declared one, otherwise the bundled art.
struct StarLogo: View {
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        if let name = StarBranding.logoImageName {
            // `.interpolation(.none)` to match the bundled pixel art. A fork supplying a
            // smooth vector or photographic mark can ignore that and it will still scale
            // correctly; nearest-neighbour only matters when the source really is pixels.
            Image(name)
                .interpolation(.none)
                .antialiased(false)
                .resizable()
                .scaledToFit()
                .designFrame(width: width, height: height)
        } else {
            PixelImage(
                url: WeatherStarResources.url("logo-corner.png", in: .logos),
                width: width,
                height: height
            )
        }
    }
}
